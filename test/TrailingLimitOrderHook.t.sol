// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test, console, Vm} from "forge-std/Test.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {TrailingLimitOrderHook, TrailLimitChoice, TrailLimitChoiceLib} from "../src/TrailingLimitOrderHook.sol";

contract TrailingLimitOrderHookTest is Test, Deployers, ERC1155Holder {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TrailLimitChoiceLib for TrailLimitChoice;

    TrailingLimitOrderHook hook;
    MockERC20 token0;
    MockERC20 token1;
    PoolId poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        swapRouter = new PoolSwapTest(manager);

        (Currency currency0, Currency currency1) = deployMintAndApprove2Currencies();
        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags);
        deployCodeTo(
            "TrailingLimitOrderHook.sol:TrailingLimitOrderHook", abi.encode(manager, "https://example.com"), hookAddress
        );
        hook = TrailingLimitOrderHook(hookAddress);

        // Approve everything
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);

        // ✅ INSPIRATION: Wide usable tick range + realistic liquidity
        (key,) = initPool(currency0, currency1, hook, 3000, 60, SQRT_PRICE_1_1);
        poolId = key.toId();

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60), // -315252
                tickUpper: TickMath.maxUsableTick(60), // 315240
                liquidityDelta: 10 ether, // Small realistic amount
                salt: bytes32(0)
            }),
            ""
        );

        deal(address(token0), address(this), 1_000_000 ether);
        deal(address(token1), address(this), 1_000_000 ether);
        deal(address(token0), address(swapRouter), 1_000_000 ether);
        deal(address(token1), address(swapRouter), 1_000_000 ether);
    }

    function placeOrder(uint256 amount, TrailLimitChoice choice, uint256 expiry, bool zeroForOne)
        internal
        returns (uint256)
    {
        hook.placeTrailOrder(key, amount, choice, expiry, zeroForOne);
        return hook.orderCount(poolId, zeroForOne, choice) - 1;
    }

    function test_placeTrailOrder_Success() public {
        uint256 amount = 1 ether;
        uint256 initialBalance = token0.balanceOf(address(this));

        hook.placeTrailOrder(key, amount, TrailLimitChoice.ONE_PERCENT, 24 hours, true);
        (, int24 currentTick,,) = manager.getSlot0(poolId);
        uint256 orderId = hook.getOrderId(key, currentTick, true);

        assertEq(hook.balanceOf(address(this), orderId), amount);
        assertEq(token0.balanceOf(address(this)), initialBalance - amount);
    }

    function test_placeTrailOrder_ZeroAmount_Reverts() public {
        vm.expectRevert(TrailingLimitOrderHook.InvalidOrder.selector);
        hook.placeTrailOrder(key, 0, TrailLimitChoice.ONE_PERCENT, 24 hours, true);
    }

    function test_trailOrder_MultipleThresholds() public {
        uint256 amount = 0.01 ether;
        (, int24 startTick,,) = manager.getSlot0(poolId);
        console.log("=== START TICK ===", int256(startTick));

        placeOrder(amount, TrailLimitChoice.ONE_PERCENT, 24 hours, true);
        placeOrder(amount, TrailLimitChoice.FIVE_PERCENT, 24 hours, true);

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // SWAP 1: BIG momentum UP → peak=200+, baseline trails
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, // tick UP
                amountSpecified: -0.15 ether, // BIGGER for >100 ticks
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            testSettings,
            ""
        );
        (, int24 tick1,,) = manager.getSlot0(poolId);
        console.log("=== SWAP1 PEAK ===", int256(tick1));

        // SWAP 2: Partial reversal → 200→120 (80 tick pullback <100, no exec)
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true, // tick DOWN
                amountSpecified: 0.08 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            testSettings,
            ""
        );
        (, int24 tick2,,) = manager.getSlot0(poolId);
        console.log("=== SWAP2 PARTIAL ===", int256(tick2));
        assertEq(hook.orderCount(poolId, true, TrailLimitChoice.ONE_PERCENT), 1); // Pending

        // SWAP 3: BIG reversal → 120→10 (peak-10=190+ >100, 1% EXECUTES!)
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: 0.1 ether, // BIG drop
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            testSettings,
            ""
        );
        (, int24 endTick,,) = manager.getSlot0(poolId);
        console.log("=== SWAP3 TRIGGER ===", int256(endTick));

        assertEq(hook.orderCount(poolId, true, TrailLimitChoice.ONE_PERCENT), 0); // EXECUTED
        assertEq(hook.orderCount(poolId, true, TrailLimitChoice.FIVE_PERCENT), 1); // PENDING (190<490)
    }

    function test_trailOrder_TakeProfit_ZeroForOne() public {
        uint256 amount = 0.01 ether;
        vm.recordLogs();

        placeOrder(amount, TrailLimitChoice.ONE_PERCENT, 24 hours, true);

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // STEP 1: Build peak (tick 0→250+)
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -0.2 ether, // BIG upswing
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            testSettings,
            ""
        );

        // STEP 2: Reversal past threshold (250→<150)
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: 0.5 ether, // BIGGER drop (>100 ticks)
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            testSettings,
            ""
        );

        bool hasOrderExecuted;

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            console.log("=== EVENT %s ===", i);
            console.logBytes32(logs[i].topics[0]); // Event signature
            console.logBytes32(logs[i].topics[1]); // orderId (indexed)
            console.logBytes32(logs[i].topics[2]); // owner (indexed)

            // Decode OrderExecuted data (executedSize + executionTick)
            // bytes32 orderExecutedTopic = keccak256("OrderExecuted(bytes32,address,uint128,int24)");
            // bytes32 orderExecutedTopic = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;
            // bytes32 orderExecutedTopic = 0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f;
            bytes32 orderExecutedTopic = 0x9436f0f45137443f7df1f84b51ffe9f6e3d5a67d517d51df8857e66e661f0e1d;

            // Only expect one of these to be fired
            if (logs[i].topics[0] == orderExecutedTopic) {
                // Manual ABI decode non-indexed params from data
                (uint128 executedSize, int24 executionTick) = abi.decode(logs[i].data, (uint128, int24));
                console.log("OrderExecuted!");
                console.log("executedSize:", uint256(executedSize));
                console.log("executionTick:", int256(executionTick));

                uint256 orderId = hook.getOrderId(key, -82, true);
                console.log("Current Tick:", executionTick);
                console.log("Queried OrderId:", orderId);

                hasOrderExecuted = true;
            }
        }
        if (!hasOrderExecuted) {
            revert("No OrderExecuted event fired");
        }
    }

    function test_cancelOrder_PartialAmount() public {
        uint256 amount = 2 ether;
        uint256 orderIdx = placeOrder(amount, TrailLimitChoice.ONE_PERCENT, 24 hours, true);
        uint256 partialAmount = 1 ether;
        uint256 initialBalance = token0.balanceOf(address(this));

        hook.cancelOrder(key, TrailLimitChoice.ONE_PERCENT, orderIdx, partialAmount, true);
        assertEq(token0.balanceOf(address(this)), initialBalance + partialAmount);
    }

    function test_cancelOrder_ZeroAmount_Reverts() public {
        uint256 orderIdx = placeOrder(1 ether, TrailLimitChoice.ONE_PERCENT, 24 hours, true);
        vm.expectRevert(TrailingLimitOrderHook.NotEnoughToClaim.selector);
        hook.cancelOrder(key, TrailLimitChoice.ONE_PERCENT, orderIdx, 0, true);
    }

    function test_cancelOrder_InsufficientAmount_Reverts() public {
        uint256 orderIdx = placeOrder(1 ether, TrailLimitChoice.ONE_PERCENT, 24 hours, true);
        vm.expectRevert(TrailingLimitOrderHook.NotEnoughToClaim.selector);
        hook.cancelOrder(key, TrailLimitChoice.ONE_PERCENT, orderIdx, 2 ether, true);
    }

    function test_cancelOrder_NotOwner_Reverts() public {
        address user = makeAddr("user");
        vm.startPrank(user);
        deal(address(token0), user, 10 ether);
        token0.approve(address(hook), type(uint256).max);
        uint256 orderIdx = placeOrder(1 ether, TrailLimitChoice.ONE_PERCENT, 24 hours, true);
        vm.stopPrank();

        vm.prank(address(0xdead));
        vm.expectRevert(TrailingLimitOrderHook.NotEnoughToClaim.selector);
        hook.cancelOrder(key, TrailLimitChoice.ONE_PERCENT, orderIdx, 1 ether, true);
    }

    function test_poolTrailStates_Initialization() public {
        (, int24 poolTick,,) = manager.getSlot0(poolId);
        (int24 priceTick, bool initialized, bool downward) = hook.poolTrailStates(poolId);
        assertTrue(initialized);
        assertEq(priceTick, poolTick);
        assertFalse(downward);
    }

    function test_redeem_ZeroClaimable_Reverts() public {
        vm.expectRevert(TrailingLimitOrderHook.NothingToClaim.selector);
        hook.redeem(key, 0, true, 1 ether);
    }

    function test_placeTrailOrder_InsufficientBalance_Reverts() public {
        deal(address(token0), address(this), 0); // Empty user balance
        vm.expectRevert();
        hook.placeTrailOrder(key, 1 ether, TrailLimitChoice.ONE_PERCENT, 24 hours, true);
    }

    function test_cancelOrder_NonExistingOrder_Reverts() public {
        uint256 nonExistingOrderIndex = 999; // Index that doesn't exist
        vm.expectRevert(TrailingLimitOrderHook.NotEnoughToClaim.selector);
        hook.cancelOrder(key, TrailLimitChoice.ONE_PERCENT, nonExistingOrderIndex, 1 ether, true);
    }

    function test_cancelOrder_AlreadyExecutedOrder_Reverts() public {
        uint256 orderIdx = placeOrder(1 ether, TrailLimitChoice.ONE_PERCENT, 24 hours, true);
        forceExecuteOrder(orderIdx);

        vm.expectRevert();
        hook.cancelOrder(key, TrailLimitChoice.ONE_PERCENT, orderIdx, 1 ether, true);
    }

    function test_redeem_ExhaustedSupply_Reverts() public {
        uint256 orderIdx = placeOrder(1 ether, TrailLimitChoice.ONE_PERCENT, 24 hours, true);
        forceExecuteOrder(orderIdx);
        vm.expectRevert(TrailingLimitOrderHook.NothingToClaim.selector);
        hook.redeem(key, -50, true, 1 ether); // Redeem full amount
    }

    function test_tryExecutingTrailOrders_AllTransitions() public {
        uint256 amount = 0.01 ether;
        placeOrder(amount, TrailLimitChoice.ONE_PERCENT, 24 hours, true);

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Execute various swaps to cover state transitions
        performSwap(false, 0.05 ether); // Tick goes up
        performSwap(true, 0.05 ether); // Tick comes down
    }

    function test_TrailLimitChoice_BoundaryValues() public {
        // Test boundary TrailLimitChoice values
        assertEq(TrailLimitChoiceLib.asTickDiff(TrailLimitChoice.ONE_PERCENT), 100);
        assertEq(TrailLimitChoiceLib.asTickDiff(TrailLimitChoice.TWENTY_PERCENT), 1800);
    }

    function performSwap(bool zeroForOne, uint256 amountSpecified) internal {
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(amountSpecified),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            testSettings,
            ""
        );
    }

    function forceExecuteOrder(uint256) internal {
        // Move ticks to cause execution
        performSwap(false, 0.5 ether); 
        // performSwap(false, 0.15 ether); 
    }
}
