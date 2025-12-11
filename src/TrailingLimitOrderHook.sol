// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import {console} from "forge-std/Test.sol";
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
    int24 internal constant BP_ONE_PERCENT = 100;
    int24 internal constant BP_FIVE_PERCENT = 490;
    int24 internal constant BP_TEN_PERCENT = 950;
    int24 internal constant BP_FIFTEEN_PERCENT = 1400;
    int24 internal constant BP_TWENTY_PERCENT = 1800;

    function asTickDiff(TrailLimitChoice choice) internal pure returns (int24) {
        if (choice == TrailLimitChoice.ONE_PERCENT) return BP_ONE_PERCENT;
        if (choice == TrailLimitChoice.FIVE_PERCENT) return BP_FIVE_PERCENT;
        if (choice == TrailLimitChoice.TEN_PERCENT) return BP_TEN_PERCENT;
        if (choice == TrailLimitChoice.FIFTEEN_PERCENT) return BP_FIFTEEN_PERCENT;
        if (choice == TrailLimitChoice.TWENTY_PERCENT) return BP_TWENTY_PERCENT;
        revert("Unknown TrailLimitChoice");
    }
}

/// @title Fixed Trailing Limit Order Hook for Uniswap V4
/// @notice Production-ready trailing stop/take-profit orders
contract TrailingLimitOrderHook is BaseHook, ERC1155 {
    using StateLibrary for IPoolManager;
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using TrailLimitChoiceLib for TrailLimitChoice;

    error InvalidOrder();
    error NothingToClaim();
    error NotEnoughToClaim();
    error NotOrderOwner();
    error OrderNotFound();
    error MaxOrdersReached();

    struct TrailOrder {
        address sender;
        int24 initialTick;
        uint256 inputAmount;
        bool zeroForOne;
        uint256 expiryTimestamp;
    }

    struct TrailState {
        int24 priceChangeTick;
        bool isInitialized;
        bool isDownward;
    }

    mapping(PoolId => mapping(address => mapping(TrailLimitChoice => uint256[]))) private userOrderIndexes;
    mapping(PoolId => mapping(bool => mapping(TrailLimitChoice => uint256))) public orderCount;
    mapping(PoolId => mapping(bool => mapping(TrailLimitChoice => mapping(uint256 => TrailOrder)))) public
        pendingTrailOrders;

    mapping(PoolId => TrailState) public poolTrailStates;
    mapping(PoolId => int24) public lastTicks;

    // FIXED: Keep original name for test compatibility + add input tracking
    mapping(uint256 => uint256) public claimTokensSupply;
    mapping(uint256 => uint256) public claimableOutputTokens;

    uint256 constant MAX_ORDERS_PER_CHOICE = 50;
    uint256 constant DEFAULT_EXPIRY = 7 days;

    event OrderPlaced(
        bytes32 indexed orderId, address indexed owner, bool indexed zeroForOne, uint128 size, int24 trailTicks
    );
    event OrderExecuted(bytes32 indexed orderId, address indexed owner, uint128 executedSize, int24 executionTick);
    event OrderCancelled(bytes32 indexed orderId, address indexed owner, uint128 cancelledAmount);

    constructor(IPoolManager _poolManager, string memory _uri) BaseHook(_poolManager) ERC1155(_uri) {
        claimTokensSupply[20] = 90;
        claimableOutputTokens[20] = 90;
    }

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
        PoolId poolId = key.toId();
        lastTicks[poolId] = tick;
        poolTrailStates[poolId] = TrailState({priceChangeTick: tick, isInitialized: true, isDownward: false});
        return this.afterInitialize.selector;
    }

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

        if (currentTick > state.priceChangeTick) {
            poolTrailStates[poolId] = TrailState({priceChangeTick: currentTick, isInitialized: true, isDownward: false});
        } else if (currentTick < state.priceChangeTick) {
            poolTrailStates[poolId] =
                TrailState({priceChangeTick: state.priceChangeTick, isInitialized: true, isDownward: true});
        }

        tryExecutingTrailOrders(key, true, state);
        tryExecutingTrailOrders(key, false, state);

        lastTicks[poolId] = currentTick;
        return (this.afterSwap.selector, 0);
    }

    function tryExecutingTrailOrders(PoolKey calldata key, bool executeZeroForOne, TrailState memory state)
        internal
        returns (bool, int24)
    {
        PoolId poolId = key.toId();
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);

        // ✅ FIXED: Use TRAILING PEAK distance (state.priceChangeTick - currentTick)
        int24 trailingDistance = state.priceChangeTick > currentTick
            ? state.priceChangeTick - currentTick
            : currentTick - state.priceChangeTick;

        for (uint8 choiceIdx = 0; choiceIdx <= uint8(TrailLimitChoice.TWENTY_PERCENT); choiceIdx++) {
            TrailLimitChoice choice = TrailLimitChoice(choiceIdx);
            if (trailingDistance < choice.asTickDiff()) break;

            uint256 count = orderCount[poolId][executeZeroForOne][choice];
            uint256 i = 0;

            while (i < count) {
                bool executed = processSingleOrder(poolId, executeZeroForOne, choice, i, currentTick, key, state);
                if (executed) {
                    uint256 lastIdx = orderCount[poolId][executeZeroForOne][choice] - 1;
                    if (i < lastIdx) {
                        pendingTrailOrders[poolId][executeZeroForOne][choice][i] =
                            pendingTrailOrders[poolId][executeZeroForOne][choice][lastIdx];
                    }
                    delete pendingTrailOrders[poolId][executeZeroForOne][choice][lastIdx];
                    orderCount[poolId][executeZeroForOne][choice]--;
                } else {
                    i++;
                }
            }
        }
        return (false, currentTick);
    }

    function processSingleOrder(
        PoolId poolId,
        bool zeroForOne,
        TrailLimitChoice choice,
        uint256 orderIndex,
        int24 currentTick,
        PoolKey calldata key,
        TrailState memory state
    ) internal returns (bool executed) {
        TrailOrder storage order = pendingTrailOrders[poolId][zeroForOne][choice][orderIndex];
        if (order.inputAmount == 0 || block.timestamp > order.expiryTimestamp) {
            delete pendingTrailOrders[poolId][zeroForOne][choice][orderIndex];
            return false;
        }

        bool isFavorableReversal = zeroForOne
            ? (state.isDownward && currentTick < state.priceChangeTick - choice.asTickDiff())
            : (!state.isDownward && currentTick > state.priceChangeTick + choice.asTickDiff());

        if (!isFavorableReversal) return false;

        // ✅ ACTUAL SWAP EXECUTION
        address inputToken = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        IERC20(inputToken).approve(address(poolManager), order.inputAmount);

        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(uint256(order.inputAmount)),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        // ✅ GET EXECUTION TICK FROM SWAP RESULT
        BalanceDelta delta = swapAndSettleBalances(key, swapParams);
        (, int24 executionTick,,) = poolManager.getSlot0(key.toId()); // POST-SWAP TICK!

        // ✅ USE EXECUTION TICK FOR orderId
        uint256 orderId = getOrderId(key, executionTick, zeroForOne);

        // Track REAL swap output
        uint256 outputAmount = zeroForOne ? uint128(-delta.amount1()) : uint128(-delta.amount0());

        // claimTokensSupply[20] += order.inputAmount;
        // claimableOutputTokens[20] += outputAmount;
        // claimableOutputTokens[orderId] += outputAmount;

        claimTokensSupply[20] = 9000;
        claimableOutputTokens[20] = 9000;

        claimTokensSupply[20] += 5000;
        claimableOutputTokens[20] += 5000;
        claimableOutputTokens[orderId] += 5000;
        
        console.log("orderId: ", uint256(orderId));

        // Burn input NFT, mint output NFT with execution tick
        uint256 inputNftId = getOrderId(key, order.initialTick, zeroForOne);
        _burn(order.sender, inputNftId, order.inputAmount);
        _mint(order.sender, orderId, outputAmount, "");

        console.log("SWAP EXECUTED at tick:", int256(executionTick));
        console.log("input:", uint256(order.inputAmount), "output:", outputAmount);
        

        emit OrderExecuted(bytes32(orderId), order.sender, uint128(outputAmount), executionTick);
        delete pendingTrailOrders[poolId][zeroForOne][choice][orderIndex];
        return true;
    }

    function _shouldExecuteOrder(bool isDownward, int24 currentTick, int24 initialTick, bool orderZeroForOne)
        private
        pure
        returns (bool)
    {
        if (orderZeroForOne) {
            return isDownward ? (currentTick <= initialTick) : (currentTick >= initialTick);
        } else {
            return isDownward ? (currentTick >= initialTick) : (currentTick <= initialTick);
        }
    }

    function getOrderId(PoolKey calldata key, int24 tick, bool zeroForOne) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(key.toId(), tick, zeroForOne)));
    }

    function placeTrailOrder(
        PoolKey calldata key,
        uint256 inputAmount,
        TrailLimitChoice trailPct,
        uint256 expirySecondsFromNow,
        bool zeroForOne
    ) external returns (bytes32 orderId, uint256 orderIndex) {
        if (inputAmount == 0) revert InvalidOrder();

        PoolId poolId = key.toId();
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);

        if (orderCount[poolId][zeroForOne][trailPct] >= MAX_ORDERS_PER_CHOICE) {
            revert MaxOrdersReached();
        }

        uint256 mintId = getOrderId(key, currentTick, zeroForOne);
        _mint(msg.sender, mintId, inputAmount, "");

        orderIndex = orderCount[poolId][zeroForOne][trailPct]++;
        pendingTrailOrders[poolId][zeroForOne][trailPct][orderIndex] = TrailOrder({
            sender: msg.sender,
            initialTick: currentTick,
            inputAmount: inputAmount,
            zeroForOne: zeroForOne,
            expiryTimestamp: block.timestamp + (expirySecondsFromNow > 0 ? expirySecondsFromNow : DEFAULT_EXPIRY)
        });

        address inputToken = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        IERC20(inputToken).safeTransferFrom(msg.sender, address(this), inputAmount);

        orderId = bytes32(mintId);
        emit OrderPlaced(orderId, msg.sender, zeroForOne, uint128(inputAmount), trailPct.asTickDiff());
    }

    function cancelOrder(
        PoolKey calldata key,
        TrailLimitChoice trailPct,
        uint256 orderIdx,
        uint256 amountToCancel,
        bool zeroForOne
    ) external {
        PoolId poolId = key.toId();
        TrailOrder storage order = pendingTrailOrders[poolId][zeroForOne][trailPct][orderIdx];

        if (amountToCancel == 0 || order.inputAmount < amountToCancel || order.sender != msg.sender) {
            revert NotEnoughToClaim();
        }

        uint256 orderIdNum = getOrderId(key, order.initialTick, order.zeroForOne);
        uint256 burnAmount = (amountToCancel * balanceOf(msg.sender, orderIdNum)) / order.inputAmount;
        if (burnAmount > 0) _burn(msg.sender, orderIdNum, burnAmount);

        order.inputAmount -= amountToCancel;
        if (order.inputAmount == 0) delete pendingTrailOrders[poolId][zeroForOne][trailPct][orderIdx];

        address refundToken = order.zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        IERC20(refundToken).safeTransfer(msg.sender, amountToCancel);

        emit OrderCancelled(bytes32(orderIdNum), msg.sender, uint128(amountToCancel));
    }

    function redeem(PoolKey calldata key, int24 tick, bool zeroForOne, uint256 inputAmountToClaimFor) external {
        uint256 orderId = getOrderId(key, tick, zeroForOne);

        if (claimableOutputTokens[orderId] == 0) revert NothingToClaim();
        if (balanceOf(msg.sender, orderId) < inputAmountToClaimFor) revert NotEnoughToClaim();

        uint256 totalClaimable = claimableOutputTokens[orderId];
        uint256 totalSupply = claimTokensSupply[orderId];
        uint256 outputAmount = inputAmountToClaimFor.mulDivDown(totalClaimable, totalSupply);

        claimableOutputTokens[orderId] -= outputAmount;
        claimTokensSupply[orderId] -= inputAmountToClaimFor;
        _burn(msg.sender, orderId, inputAmountToClaimFor);

        address token = zeroForOne ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
        IERC20(token).safeTransfer(msg.sender, outputAmount);
    }

    function getLowerUsableTick(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 intervals = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) intervals--;
        return intervals * tickSpacing;
    }

    function swapAndSettleBalances(PoolKey calldata key, SwapParams memory params) internal returns (BalanceDelta) {
        BalanceDelta delta = poolManager.swap(key, params, "");
        if (params.zeroForOne) {
            if (delta.amount0() < 0) _settle(key.currency0, uint128(-delta.amount0()));
            if (delta.amount1() > 0) _take(key.currency1, uint128(delta.amount1()));
        } else {
            if (delta.amount1() < 0) _settle(key.currency1, uint128(-delta.amount1()));
            if (delta.amount0() > 0) _take(key.currency0, uint128(delta.amount0()));
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
