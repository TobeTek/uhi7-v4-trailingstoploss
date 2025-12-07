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

/// @notice Specifies trailing limit percentages represented in ticks.
enum TrailLimitChoice {
    ONE_PERCENT,
    FIVE_PERCENT,
    TEN_PERCENT,
    FIFTEEN_PERCENT,
    TWENTY_PERCENT
}

library TrailLimitChoiceLib {
    // Approximate tick equivalents for trailing percentages
    int24 internal constant BP_ONE_PERCENT = 100;
    int24 internal constant BP_FIVE_PERCENT = 490;
    int24 internal constant BP_TEN_PERCENT = 950;
    int24 internal constant BP_FIFTEEN_PERCENT = 1400;
    int24 internal constant BP_TWENTY_PERCENT = 1800;

    /// @notice Converts TrailLimitChoice enum to equivalent tick difference
    function asTickDiff(TrailLimitChoice choice) public pure returns (int24) {
        if (choice == TrailLimitChoice.ONE_PERCENT) return BP_ONE_PERCENT;
        if (choice == TrailLimitChoice.FIVE_PERCENT) return BP_FIVE_PERCENT;
        if (choice == TrailLimitChoice.TEN_PERCENT) return BP_TEN_PERCENT;
        if (choice == TrailLimitChoice.FIFTEEN_PERCENT) return BP_FIFTEEN_PERCENT;
        if (choice == TrailLimitChoice.TWENTY_PERCENT) return BP_TWENTY_PERCENT;
        revert("Unknown TrailLimitChoice");
    }
}

/// @title Trailing Limit Order Hook for Uniswap V4 Pools
/// @notice Enables trailing limit and market orders with tick-based thresholds.
contract TrailingLimitOrderHook is BaseHook, ERC1155 {
    using StateLibrary for IPoolManager;
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using TrailLimitChoiceLib for TrailLimitChoice;

    // Custom type for tracking orders
    type TrailOrderId is bytes32;

    // Errors
    error InvalidOrder();
    error NothingToClaim();
    error NotEnoughToClaim();
    error NotOrderOwner();

    /// @notice Order types: Limit or Market (not fully implemented, only trailing limit)
    enum OrderType {
        LIMIT,
        MARKET
    }

    struct TrailOrder {
        address sender;
        int24 initialTick;
        uint256 inputAmount;
        TrailLimitChoice trailPctIndex;
        bool zeroForOne;
        uint256 expiryTimestamp;
    }

    struct TrailState {
        int24 priceChangeTick; // Reference tick (peak or trough)
        bool isInitialized;
        bool isDownward; // True if price dropped from peak
    }

    /// @dev Pool trail state keyed by PoolId
    mapping(PoolId => TrailState) public poolTrailStates;

    /// @dev Pending trail orders by PoolId, swap direction, trail choice, and index
    mapping(PoolId => mapping(bool => mapping(TrailLimitChoice => mapping(uint8 => TrailOrder)))) public
        pendingTrailOrders;

    /// @dev Rotating index per PoolId, direction, and trail choice for new orders (0-255)
    mapping(PoolId => mapping(bool => mapping(TrailLimitChoice => uint8))) public poolTrailOrderIndexes;

    /// @dev Pending limit orders (not fully utilized here)
    mapping(PoolId => mapping(int24 => mapping(bool => uint256))) public pendingLimitOrders;

    /// @dev Track claim token supplies per orderId
    mapping(uint256 => uint256) public claimTokensSupply;

    /// @dev Claimable output tokens per orderId
    mapping(uint256 => uint256) public claimableOutputTokens;

    /// @dev Last observed tick per pool
    mapping(PoolId => int24) public lastTicks;

    // Events
    event OrderPlaced(
        bytes32 indexed orderId, address indexed owner, bool indexed zeroForOne, uint128 size, int24 trailTicks
    );
    event OrderExecuted(bytes32 indexed orderId, uint128 executedSize, int24 executionTick);
    event OrderCancelled(bytes32 indexed orderId);

    /// @param _poolManager Address of the pool manager contract
    /// @param _uri Metadata URI for ERC1155 tokens
    constructor(IPoolManager _poolManager, string memory _uri) BaseHook(_poolManager) ERC1155(_uri) {}

    /// @notice Hook permissions specifying enabled callback hooks
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

    /// @inheritdoc BaseHook
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        lastTicks[poolId] = tick;
        poolTrailStates[poolId] = TrailState({priceChangeTick: tick, isInitialized: true, isDownward: false});
        return this.afterInitialize.selector;
    }

    /// @inheritdoc BaseHook
    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        if (sender == address(this)) return (this.afterSwap.selector, 0);

        PoolId poolId = key.toId();
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        TrailState memory state = poolTrailStates[poolId];

        if (!state.isInitialized) return (this.afterSwap.selector, 0);

        // Update trail state depending on price peak or trough changes
        if (currentTick > state.priceChangeTick) {
            // New peak price
            poolTrailStates[poolId] =
                TrailState({priceChangeTick: currentTick, isInitialized: true, isDownward: false});
        } else if (currentTick < state.priceChangeTick) {
            // Price dropped from peak, set downward flag
            poolTrailStates[poolId] =
                TrailState({priceChangeTick: state.priceChangeTick, isInitialized: true, isDownward: true});
        }

        tryExecutingTrailOrders(key, params.zeroForOne);

        lastTicks[poolId] = currentTick;
        return (this.afterSwap.selector, 0);
    }

    /// @notice Main execution logic - reduced stack depth by splitting processing
    function tryExecutingTrailOrders(PoolKey calldata key, bool executeZeroForOne) internal returns (bool, int24) {
        PoolId poolId = key.toId();
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        TrailState memory state = poolTrailStates[poolId];

        if (!state.isInitialized) return (false, currentTick);

        int24 priceBaseline = state.priceChangeTick;
        int24 tickDistance = currentTick > priceBaseline ? currentTick - priceBaseline : priceBaseline - currentTick;
        uint256 totalMarketInput;

        uint256 orderId = getOrderId(key, currentTick, executeZeroForOne);

        // Split the loop into smaller chunks to reduce stack depth
        for (uint8 choiceIdx = 0; choiceIdx <= uint8(TrailLimitChoice.TWENTY_PERCENT); choiceIdx++) {
            TrailLimitChoice choice = TrailLimitChoice(choiceIdx);
            if (tickDistance < choice.asTickDiff()) continue;

            uint256 choiceInput = processChoiceOrders(poolId, choice, executeZeroForOne, currentTick, orderId);
            totalMarketInput += choiceInput;
        }

        if (totalMarketInput > 0) {
            executeMarketOrder(key, currentTick, executeZeroForOne, totalMarketInput);
        }

        return (false, currentTick);
    }

    /// @notice Process orders for a specific trail choice - isolated to reduce stack depth
    function processChoiceOrders(
        PoolId poolId,
        TrailLimitChoice choice,
        bool zeroForOne,
        int24 currentTick,
        uint256 orderId
    ) internal returns (uint256 totalInput) {
        mapping(uint8 => TrailOrder) storage orders = pendingTrailOrders[poolId][zeroForOne][choice];

        for (uint8 i = 0; i < 256; i++) {
            if (processSingleOrder(orders, i, poolId, zeroForOne, currentTick, orderId)) {
                totalInput += orders[i].inputAmount;
            }
        }
    }

    /// @notice Process single order - minimal stack usage
    function processSingleOrder(
        mapping(uint8 => TrailOrder) storage orders,
        uint8 index,
        PoolId poolId,
        bool zeroForOne,
        int24 currentTick,
        uint256 orderId
    ) internal returns (bool executed) {
        TrailOrder storage order = orders[index];
        if (order.inputAmount == 0) return false;

        // Expiry check first (cheap)
        if (block.timestamp > order.expiryTimestamp) {
            delete orders[index];
            return false;
        }

        TrailState memory state = poolTrailStates[poolId];
        if (!_shouldExecuteOrder(state.isDownward, currentTick, order.initialTick, zeroForOne)) {
            return false;
        }

        // Execute order
        claimTokensSupply[orderId] += order.inputAmount;
        _mint(order.sender, orderId, order.inputAmount, "");
        delete orders[index];
        return true;
    }

    /// @notice Ultra-lightweight execution condition - 4 params only
    function _shouldExecuteOrder(bool isDownward, int24 currentTick, int24 initialTick, bool zeroForOne)
        private
        pure
        returns (bool)
    {
        if (isDownward) {
            // STOP LOSS
            return (zeroForOne && currentTick <= initialTick) || (!zeroForOne && currentTick >= initialTick);
        }
        // TAKE PROFIT
        return (zeroForOne && currentTick >= initialTick) || (!zeroForOne && currentTick <= initialTick);
    }

    /// @notice Returns the nearest usable tick below the given tick respecting tick spacing
    function getLowerUsableTick(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 intervals = tick / tickSpacing;

        // Solidity truncates towards zero for int division, handle negatives correctly
        if (tick < 0 && tick % tickSpacing != 0) {
            intervals--;
        }
        return intervals * tickSpacing;
    }

    /// @notice Computes an order ID from the pool key, tick, and swap direction
    /// @param key Pool key for the order
    /// @param tick Tick associated with the order
    /// @param zeroForOne Swap direction (token0 to token1)
    /// @return Unique order ID
    function getOrderId(PoolKey calldata key, int24 tick, bool zeroForOne) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(key.toId(), tick, zeroForOne)));
    }

    /// @notice Place a new trailing limit order with specified parameters
    /// @param key Pool to place order in
    /// @param initialTick Tick at placement time (price baseline)
    /// @param inputAmount Amount of input tokens for the order
    /// @param trailPct Trailing percentage choice
    /// @param zeroForOne Direction of swap desired
    /// @return orderId Unique ID for the placed order (as bytes32)
    function placeTrailOrder(
        PoolKey calldata key,
        int24 initialTick,
        uint256 inputAmount,
        TrailLimitChoice trailPct,
        bool zeroForOne
    ) external returns (bytes32 orderId) {
        if (inputAmount == 0) revert InvalidOrder();

        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());

        TrailOrder memory order = TrailOrder({
            sender: msg.sender,
            initialTick: initialTick,
            inputAmount: inputAmount,
            trailPctIndex: trailPct,
            zeroForOne: zeroForOne,
            expiryTimestamp: block.timestamp + 12 hours
        });

        PoolId poolId = key.toId();
        uint8 orderIndx = poolTrailOrderIndexes[poolId][zeroForOne][trailPct];
        pendingTrailOrders[poolId][zeroForOne][trailPct][orderIndx] = order;
        poolTrailOrderIndexes[poolId][zeroForOne][trailPct] = uint8((orderIndx + 1) % 256);

        address inputToken = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        IERC20(inputToken).safeTransferFrom(msg.sender, address(this), inputAmount);

        orderId = bytes32(getOrderId(key, currentTick, zeroForOne));
        emit OrderPlaced(orderId, msg.sender, zeroForOne, uint128(inputAmount), trailPct.asTickDiff());
    }

    /// @notice Cancel a pending trailing order partially or fully
    /// @param key Pool of the order
    /// @param zeroForOne Direction of the order
    /// @param trailPct Trailing percentage tier of the order
    /// @param orderIndx Index of order in storage
    /// @param amountToCancel Amount to cancel and refund
    function cancelOrder(
        PoolKey calldata key,
        bool zeroForOne,
        TrailLimitChoice trailPct,
        uint8 orderIndx,
        uint256 amountToCancel
    ) external {
        PoolId poolId = key.toId();
        TrailOrder storage order = pendingTrailOrders[poolId][zeroForOne][trailPct][orderIndx];
        uint256 orderIdNum = getOrderId(key, lastTicks[poolId], zeroForOne);

        if (amountToCancel == 0 || order.inputAmount < amountToCancel) {
            revert NotEnoughToClaim();
        }
        if (msg.sender != order.sender) {
            revert NotOrderOwner();
        }

        order.inputAmount -= amountToCancel;

        address refundToken = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        IERC20(refundToken).safeTransfer(msg.sender, amountToCancel);

        emit OrderCancelled(bytes32(orderIdNum));
    }

    /// @notice Redeem by burning claim tokens for output tokens after order execution
    /// @param key Pool key related to order
    /// @param tickToSellAt Tick at which order was executed
    /// @param zeroForOne Swap direction
    /// @param inputAmountToClaimFor Amount of claim tokens to redeem
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

    /// @notice Execute an aggregated market order from multiple trailing orders
    /// @param key Pool key
    /// @param tick Current tick at execution
    /// @param zeroForOne Swap direction
    /// @param inputAmount Total input amount to swap
    function executeMarketOrder(PoolKey calldata key, int24 tick, bool zeroForOne, uint256 inputAmount) internal {
        _executeOrder(key, tick, zeroForOne, inputAmount);
    }

    /// @dev Internal call to perform swap and update balances accordingly
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

    /// @dev Helper to perform swap and settle token balances to or from pool manager
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

    /// @dev Settle tokens owed to pool manager by transferring tokens
    function _settle(Currency currency, uint128 amount) internal {
        poolManager.sync(currency);
        currency.transfer(address(poolManager), amount);
        poolManager.settle();
    }

    /// @dev Take tokens from pool manager into this contract
    function _take(Currency currency, uint128 amount) internal {
        poolManager.take(currency, address(this), amount);
    }
}
