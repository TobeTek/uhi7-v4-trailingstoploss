// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ERC1155} from "openzeppelin/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

enum TrailLimitChoice {
    ONE_PERCENT,
    FIVE_PERCENT,
    TEN_PERCENT,
    FIFTEEN_PERCENT,
    TWENTY_PERCENT
}

library TrailLimitChoiceLib {
    // We store the tick equivalent of the trailing percentage
    // Each tick represents ~0.01% (1 basis point)
    // since p(i) = 1.0001^i; if p(i) = 1.01 (1% increase), then i = log(1.01) / log(1.0001) ~= 99 ticks
    // Apporximately, each 100 ticks represent 1% price movement
    int24 internal constant BP_ONE_PERCENT = 100;
    int24 internal constant BP_FIVE_PERCENT = 490;
    int24 internal constant BP_TEN_PERCENT = 950;
    int24 internal constant BP_FIFTEEN_PERCENT = 1_400;
    int24 internal constant BP_TWENTY_PERCENT = 1_800;

    function asTickDiff(TrailLimitChoice choice) internal pure returns (int24) {
        if (choice == TrailLimitChoice.ONE_PERCENT) return BP_ONE_PERCENT;
        if (choice == TrailLimitChoice.FIVE_PERCENT) return BP_FIVE_PERCENT;
        if (choice == TrailLimitChoice.TEN_PERCENT) return BP_TEN_PERCENT;
        if (choice == TrailLimitChoice.FIFTEEN_PERCENT) return BP_FIFTEEN_PERCENT;
        if (choice == TrailLimitChoice.TWENTY_PERCENT) return BP_TWENTY_PERCENT;
        revert("Unknown TrailPctChoice");
    }
}

/// @title Trailing Limit Order Hook
/// @notice Allows users to place trailing limit and market orders on Uniswap v4 pools.
contract TrailingLimitOrderHook is BaseHook, ERC1155 {
    using StateLibrary for IPoolManager;
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using TrailLimitChoiceLib for TrailLimitChoice;

    type TrailOrderId is bytes32;

    // ERRORS
    error InvalidOrder();
    error NothingToClaim();
    error NotEnoughToClaim();

    enum OrderType {
        LIMIT,
        MARKET
    }

    struct TrailOrder {
        address sender;
        int24 initialTick;
        uint256 inputAmount; // Ensure it's always a positive amount
        OrderType orderType;
        TrailLimitChoice trailPctIndex;
        bool zeroForOne;
        uint256 expiryTimestamp;
    }

    struct TrailState {
        int24 priceChangeTick;
        bool isInitialized;
        bool isDownward; // Did Token0 price increase
    }

    mapping(PoolId poolId => mapping(bool zeroForOne => mapping(TrailLimitChoice trailLimit => TrailOrder[]))) public
        userTrailFees;

    mapping(PoolId poolId => TrailState) public poolTrailStates;
    mapping(PoolId poolId => mapping(bool zeroForOne => mapping(TrailLimitChoice trailLimit => TrailOrder[]))) public
        pendingTrailOrders;

    mapping(PoolId poolId => mapping(int24 tickToSellAt => mapping(bool zeroForOne => uint256 inputAmount))) public
        pendingLimitOrders;

    //
    mapping(uint256 orderId => uint256 claimsSupply) public claimTokensSupply;
    mapping(uint256 orderId => uint256 outputClaimable) public claimableOutputTokens;

    mapping(PoolId poolId => int24 lastTick) public lastTicks;

    event OrderPlaced(
        bytes32 indexed orderId, address indexed owner, bool indexed zeroForOne, uint128 size, int24 trailTicks
    );
    event OrderExecuted(bytes32 indexed orderId, address indexed owner, uint128 executedSize, int24 executionTick);
    event OrderCancelled(bytes32 indexed orderId);

    constructor(IPoolManager _poolManager, string memory _uri) BaseHook(_poolManager) ERC1155(_uri) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        lastTicks[key.toId()] = tick;
        poolTrailStates[key.toId()] = TrailState({priceChangeTick: tick, isInitialized: true, isDownward: false});
        return this.afterInitialize.selector;
    }

    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        if (sender == address(this)) return (this.afterSwap.selector, 0);

        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        int24 lastTick = lastTicks[key.toId()];
        TrailState memory state = poolTrailStates[key.toId()];

        if (!state.isInitialized) return (this.afterSwap.selector, 0);

        bool wasDownward = state.isDownward;

        // UPDATE TRAIL STATE CORRECTLY
        if (currentTick > state.priceChangeTick) {
            // New high: reset peak, clear downward state
            poolTrailStates[key.toId()] = TrailState({
                priceChangeTick: currentTick,
                isInitialized: true,
                isDownward: false // Token0 price ↑ from trough
            });
        } else if (currentTick < state.priceChangeTick) {
            // New low: set downward flag (Token0 price ↓ from peak)
            poolTrailStates[key.toId()] = TrailState({
                priceChangeTick: state.priceChangeTick, // Keep peak
                isInitialized: true,
                isDownward: true
            });
        }

        // EXECUTE TRAILS FIRST
        tryExecutingTrailOrders(key, params.zeroForOne);

        // THEN LIMITS
        bool tryMore = true;
        int24 swapTick;
        while (tryMore) {
            (tryMore, swapTick) = tryExecutingLimitOrders(key, !params.zeroForOne);
        }

        // ALWAYS UPDATE WITH ACTUAL POOL TICK
        lastTicks[key.toId()] = currentTick; // FIXED: use actual currentTick
        return (this.afterSwap.selector, 0);
    }

    function tryExecutingTrailOrders(PoolKey calldata key, bool executeZeroForOne)
        internal
        returns (bool tryMore, int24 newTick)
    {
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        TrailState memory state = poolTrailStates[key.toId()];
        if (!state.isInitialized) return (false, currentTick);

        int24 priceBaseline = state.priceChangeTick;
        int24 tickDistance = currentTick > priceBaseline ? currentTick - priceBaseline : priceBaseline - currentTick;

        uint256 orderId = getOrderId(key, currentTick, executeZeroForOne);
        uint256 totalMarketInput;

        // Loop over all trail choices efficiently
        for (uint8 choiceIdx = 0; choiceIdx <= uint8(TrailLimitChoice.TWENTY_PERCENT); choiceIdx++) {
            TrailLimitChoice choice = TrailLimitChoice(choiceIdx);
            int24 threshold = choice.asTickDiff();

            if (tickDistance < threshold) continue;

            TrailOrder[] storage orders = pendingTrailOrders[key.toId()][executeZeroForOne][choice];
            for (uint256 i = orders.length; i > 0;) {
                unchecked {
                    --i;
                }
                TrailOrder memory order = orders[i];

                // EXPIRY CHECK
                if (block.timestamp > order.expiryTimestamp) {
                    orders[i] = orders[orders.length - 1];
                    orders.pop();
                    continue;
                }

                bool shouldExecute;
                if (state.isDownward) {
                    // STOP LOSS: price dropped from peak
                    shouldExecute = (executeZeroForOne && currentTick <= order.initialTick)
                        || (!executeZeroForOne && currentTick >= order.initialTick);
                } else {
                    // TAKE PROFIT: price rose from trough
                    shouldExecute = (executeZeroForOne && currentTick >= order.initialTick)
                        || (!executeZeroForOne && currentTick <= order.initialTick);
                }

                if (!shouldExecute) continue;

                if (order.inputAmount == 0) {
                    orders[i] = orders[orders.length - 1];
                    orders.pop();
                    continue;
                }

                // EXECUTE ORDER
                if (order.orderType == OrderType.MARKET) {
                    totalMarketInput += order.inputAmount;
                } else {
                    claimTokensSupply[orderId] += order.inputAmount;
                }
                _mint(order.sender, orderId, order.inputAmount, "");

                // REMOVE EXECUTED ORDER
                orders[i] = orders[orders.length - 1];
                orders.pop();
            }
        }

        if (totalMarketInput > 0) {
            executeMarketOrder(key, currentTick, executeZeroForOne, totalMarketInput);
        }

        return (false, currentTick);
    }

    function tryExecutingLimitOrders(PoolKey calldata key, bool executeZeroForOne)
        internal
        returns (bool tryMore, int24 newTick)
    {
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        int24 lastTick = lastTicks[key.toId()];

        // If tick has increased (currentTick > lastTick)
        // Token0 price increases
        if (currentTick > lastTick) {
            // Loop over all ticks from lastTick to currentTick
            // and execute orders for token0 (zeroForOne = false)
            for (int24 tick = lastTick; tick < currentTick; tick += key.tickSpacing) {
                uint256 inputAmount = pendingLimitOrders[key.toId()][tick][executeZeroForOne];
                if (inputAmount > 0) {
                    executeLimitOrder(key, tick, executeZeroForOne, inputAmount);
                    return (true, currentTick);
                }
            }
        }
        // If tick has decreased (currentTick < lastTick)
        // Token1 price increases
        else {
            for (int24 tick = lastTick; tick > currentTick; tick -= key.tickSpacing) {
                uint256 inputAmount = pendingLimitOrders[key.toId()][tick][executeZeroForOne];
                if (inputAmount > 0) {
                    executeLimitOrder(key, tick, executeZeroForOne, inputAmount);
                    return (true, currentTick);
                }
            }
        }

        // No orders to execute
        return (false, currentTick);
    }

    function getLowerUsableTick(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 intervals = tick / tickSpacing;

        // Solidity truncates towards zero on integer division
        // With negative numbers it means we need to subtract one more interval
        if (tick < 0 && tick % tickSpacing != 0) {
            intervals--;
        }

        return intervals * tickSpacing;
    }

    function getOrderId(PoolKey calldata key, int24 tick, bool zeroForOne) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(key.toId(), tick, zeroForOne)));
    }

    function placeTrailOrder(
        PoolKey calldata key,
        uint256 inputAmount,
        OrderType orderType,
        TrailLimitChoice trailPct,
        uint256 expirySecondsFromNow,
        bool zeroForOne
    ) external returns (bytes32 orderId) {
        if (inputAmount == 0) revert InvalidOrder();

        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());

        TrailOrder memory order = TrailOrder({
            sender: msg.sender,
            initialTick: currentTick,
            inputAmount: inputAmount,
            orderType: orderType,
            trailPctIndex: trailPct,
            zeroForOne: zeroForOne,
            expiryTimestamp: block.timestamp + expirySecondsFromNow
        });

        pendingTrailOrders[key.toId()][zeroForOne][trailPct].push(order);

        address inputToken = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        IERC20(inputToken).safeTransferFrom(msg.sender, address(this), inputAmount);

        orderId = bytes32(getOrderId(key, currentTick, zeroForOne));
        emit OrderPlaced(orderId, msg.sender, zeroForOne, uint128(inputAmount), trailPct.asTickDiff());
    }

    function placeLimitOrder(PoolKey calldata key, int24 tickToSellAt, bool zeroForOne, uint256 inputAmount)
        external
        returns (int24)
    {
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);

        pendingLimitOrders[key.toId()][tick][zeroForOne] += inputAmount;

        uint256 orderId = getOrderId(key, tick, zeroForOne);
        claimTokensSupply[orderId] += inputAmount;
        _mint(msg.sender, orderId, inputAmount, "");

        address sellToken = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        IERC20(sellToken).safeTransferFrom(msg.sender, address(this), inputAmount);

        return tick;
    }

    function cancelLimitOrder(PoolKey calldata key, int24 tickToSellAt, bool zeroForOne, uint256 amountToCancel)
        external
    {
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        uint256 orderId = getOrderId(key, tick, zeroForOne);

        if (balanceOf(msg.sender, orderId) < amountToCancel) {
            revert NotEnoughToClaim();
        }

        pendingLimitOrders[key.toId()][tick][zeroForOne] -= amountToCancel;
        claimTokensSupply[orderId] -= amountToCancel;
        _burn(msg.sender, orderId, amountToCancel);

        address sellToken = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        IERC20(sellToken).safeTransfer(msg.sender, amountToCancel);

        emit OrderCancelled(bytes32(orderId));
    }

    function redeem(PoolKey calldata key, int24 tickToSellAt, bool zeroForOne, uint256 inputAmountToClaimFor)
        external
    {
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        uint256 orderId = getOrderId(key, tick, zeroForOne);

        if (claimableOutputTokens[orderId] == 0) revert NothingToClaim();

        uint256 claimTokens = balanceOf(msg.sender, orderId);
        if (claimTokens < inputAmountToClaimFor) revert NotEnoughToClaim();

        uint256 totalClaimableForPosition = claimableOutputTokens[orderId];
        uint256 totalInputAmountForPosition = claimTokensSupply[orderId];

        uint256 outputAmount = inputAmountToClaimFor.mulDivDown(totalClaimableForPosition, totalInputAmountForPosition);

        claimableOutputTokens[orderId] -= outputAmount;
        claimTokensSupply[orderId] -= inputAmountToClaimFor;
        _burn(msg.sender, orderId, inputAmountToClaimFor);

        address token = zeroForOne ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
        IERC20(token).safeTransfer(msg.sender, outputAmount);
    }

    function executeMarketOrder(PoolKey calldata key, int24 tick, bool zeroForOne, uint256 inputAmount) internal {
        _executeOrder(key, tick, zeroForOne, inputAmount);
    }

    function executeLimitOrder(PoolKey calldata key, int24 tick, bool zeroForOne, uint256 inputAmount) internal {
        _executeOrder(key, tick, zeroForOne, inputAmount);
        pendingLimitOrders[key.toId()][tick][zeroForOne] -= inputAmount;
        if (pendingLimitOrders[key.toId()][tick][zeroForOne] == 0) {
            delete pendingLimitOrders[key.toId()][tick][zeroForOne];
        }
    }

    function _executeOrder(PoolKey calldata key, int24 tick, bool zeroForOne, uint256 inputAmount) internal {
        BalanceDelta delta = swapAndSettleBalances(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(inputAmount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        uint256 orderId = getOrderId(key, tick, zeroForOne);
        uint256 outputAmount = zeroForOne ? uint256(int256(delta.amount1())) : uint256(int256(delta.amount0()));

        claimableOutputTokens[orderId] += outputAmount;
        emit OrderExecuted(bytes32(orderId), uint128(inputAmount), lastTicks[key.toId()]);
    }

    function swapAndSettleBalances(PoolKey calldata key, SwapParams memory params) internal returns (BalanceDelta) {
        BalanceDelta delta = poolManager.swap(key, params, "");

        if (params.zeroForOne) {
            if (delta.amount0() < 0) {
                _settle(key.currency0, uint128(-delta.amount0()));
            }

            if (delta.amount1() > 0) {
                _take(key.currency1, uint128(delta.amount1()));
            }
        } else {
            if (delta.amount1() < 0) {
                _settle(key.currency1, uint128(-delta.amount1()));
            }

            if (delta.amount0() > 0) {
                _take(key.currency0, uint128(delta.amount0()));
            }
        }
        return delta;
    }

    function _settle(Currency currency, uint128 amount) internal {
        poolManager.sync(currency);
        currency.transfer(address(poolManager), amount);
        poolManager.settle();
    }

    function _take(Currency currency, uint128 amount) internal {
        poolManager.take(currency, address(this), amount);
    }
}
