// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

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

import {TrailingLimitOrderHook, TrailLimitChoice, TrailLimitChoiceLib } from "../src/TrailingLimitOrderHook.sol";


contract TrailingLimitOrderHookTest is Test, Deployers, ERC1155Holder {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using TrailLimitChoiceLib for TrailLimitChoice;

    TrailingLimitOrderHook hook;
    MockERC20 token0;
    MockERC20 token1;
    uint8 orderIndex;

    function setUp() public {
        // Deploy v4 core contracts
        deployFreshManagerAndRouters();
        swapRouter = new PoolSwapTest(manager);

        // Deploy two test tokens
        (Currency currency0, Currency currency1) = deployMintAndApprove2Currencies();
        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        // Deploy hook with correct flags
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags);
        deployCodeTo("TrailingLimitOrderHook.sol:TrailingLimitOrderHook", abi.encode(manager, "https://example.com"), hookAddress);
        hook = TrailingLimitOrderHook(hookAddress);

        // Approve hook to spend tokens
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);

        // Initialize pool
        (key,) = initPool(currency0, currency1, hook, 3000, 60, SQRT_PRICE_1_1);

        // Add initial liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        // Mint more tokens for testing
        deal(address(token0), address(this), 1000 ether);
        deal(address(token1), address(this), 1000 ether);
    }

    /// @notice Helper to place order and return index by parsing event
    function placeOrder(TrailLimitChoice choice, int24 initialTick, uint256 amount, bool zeroForOne)
        internal
        returns (uint8)
    {
        uint8 index = hook.poolTrailOrderIndexes(key.toId(), zeroForOne, choice);
        vm.recordLogs();
        hook.placeTrailOrder(key, initialTick, amount, choice, zeroForOne);
        orderIndex = index;
        return index;
    }

    function test_placeTrailOrder_Success() public {
        uint256 amount = 1 ether;
        TrailLimitChoice choice = TrailLimitChoice.ONE_PERCENT;

        uint256 initialBalance = token0.balanceOf(address(this));
        bytes32 orderId = hook.placeTrailOrder(key, 0, amount, choice, true);

        uint256 orderKey = hook.getOrderId(key, 0, true);
        assertEq(hook.balanceOf(address(this), orderKey), amount);
        assertEq(token0.balanceOf(address(this)), initialBalance - amount);
        assertTrue(bytes32(orderId) != bytes32(0));
    }

    function test_placeTrailOrder_ZeroAmount_Reverts() public {
        vm.expectRevert(TrailingLimitOrderHook.InvalidOrder.selector);
        hook.placeTrailOrder(key, 0, 0, TrailLimitChoice.ONE_PERCENT, true);
    }

    function test_fuzz_placeTrailOrder(uint256 amount, uint8 choiceIdx, int24 tick) public {
        vm.assume(amount > 0 && amount < 100 ether);
        TrailLimitChoice choice = TrailLimitChoice(bound(choiceIdx, 0, 4));
        vm.assume(tick > TickMath.MIN_TICK + 100 && tick < TickMath.MAX_TICK - 100);

        uint256 initialBalance = token0.balanceOf(address(this));
        hook.placeTrailOrder(key, tick, amount, choice, true);

        uint256 orderKey = hook.getOrderId(key, tick, true);
        assertEq(hook.balanceOf(address(this), orderKey), amount);
        assertEq(token0.balanceOf(address(this)), initialBalance - amount);
    }

    function test_cancelOrder_FullAmount() public {
        uint256 amount = 1 ether;
        TrailLimitChoice choice = TrailLimitChoice.ONE_PERCENT;
        uint8 index = placeOrder(choice, 0, amount, true);

        uint256 initialBalance = token0.balanceOf(address(this));
        uint256 orderKey = hook.getOrderId(key, 0, true);

        hook.cancelOrder(key, true, choice, index, amount);

        assertEq(hook.balanceOf(address(this), orderKey), 0);
        assertEq(token0.balanceOf(address(this)), initialBalance);
    }

    function test_cancelOrder_PartialAmount() public {
        uint256 amount = 2 ether;
        TrailLimitChoice choice = TrailLimitChoice.ONE_PERCENT;
        uint8 index = placeOrder(choice, 0, amount, true);

        uint256 initialBalance = token0.balanceOf(address(this));
        uint256 partialAmount = 1 ether;

        hook.cancelOrder(key, true, choice, index, partialAmount);

        uint256 orderKey = hook.getOrderId(key, 0, true);
        assertEq(hook.balanceOf(address(this), orderKey), amount - partialAmount);
        assertEq(token0.balanceOf(address(this)), initialBalance + partialAmount);
    }

    function test_cancelOrder_ZeroAmount_Reverts() public {
        TrailLimitChoice choice = TrailLimitChoice.ONE_PERCENT;
        placeOrder(choice, 0, 1 ether, true);

        vm.expectRevert(TrailingLimitOrderHook.NotEnoughToClaim.selector);
        hook.cancelOrder(key, true, choice, orderIndex, 0);
    }

    function test_cancelOrder_InsufficientAmount_Reverts() public {
        TrailLimitChoice choice = TrailLimitChoice.ONE_PERCENT;
        placeOrder(choice, 0, 1 ether, true);

        vm.expectRevert(TrailingLimitOrderHook.NotEnoughToClaim.selector);
        hook.cancelOrder(key, true, choice, orderIndex, 2 ether);
    }

    function test_cancelOrder_NotOwner_Reverts() public {
        TrailLimitChoice choice = TrailLimitChoice.ONE_PERCENT;
        address user = makeAddr("user");
        vm.startPrank(user);
        deal(address(token0), user, 10 ether);
        token0.approve(address(hook), type(uint256).max);
        hook.placeTrailOrder(key, 0, 1 ether, choice, true);
        vm.stopPrank();

        vm.expectRevert(TrailingLimitOrderHook.NotOrderOwner.selector);
        hook.cancelOrder(key, true, choice, orderIndex, 1 ether);
    }

    function test_redeem_ZeroClaimable_Reverts() public {
        uint256 orderId = hook.getOrderId(key, 0, true);

        vm.expectRevert(TrailingLimitOrderHook.NothingToClaim.selector);
        hook.redeem(key, 0, true, 1 ether);
    }

    // function test_redeem_InsufficientERC1155Balance_Reverts() public {
    //     // Place order to get ERC1155 tokens
    //     placeOrder(TrailLimitChoice.ONE_PERCENT, 0, 1 ether, true);
        
    //     uint256 orderId = hook.getOrderId(key, 0, true);
        
    //     // Burn all ERC1155 tokens first
    //     hook._burn(address(this), orderId, 1 ether);
        
    //     // Try to redeem without ERC1155 balance
    //     vm.expectRevert(TrailingLimitOrderHook.NotEnoughToClaim.selector);
    //     hook.redeem(key, 0, true, 1 ether);
    // }

    function test_hookPermissions() public {
        Hooks.Permissions memory perms = hook.getHookPermissions();
        assertFalse(perms.beforeInitialize);
        assertTrue(perms.afterInitialize);
        assertFalse(perms.beforeSwap);
        assertTrue(perms.afterSwap);
    }

    function test_getHookPermissions_MatchesDeployFlags() public {
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);
        Hooks.Permissions memory perms = hook.getHookPermissions();

        assertEq(
            uint160(perms.afterInitialize ? Hooks.AFTER_INITIALIZE_FLAG : 0) |
            uint160(perms.afterSwap ? Hooks.AFTER_SWAP_FLAG : 0),
            flags
        );
    }

    function test_getOrderId_Consistency() public {
        uint256 orderId1 = hook.getOrderId(key, 100, true);
        uint256 orderId2 = hook.getOrderId(key, 100, true);
        assertEq(orderId1, orderId2);
        
        uint256 orderId3 = hook.getOrderId(key, 100, false);
        assertTrue(orderId1 != orderId3);
    }

    function test_trailOrder_TriggerTakeProfit_ZeroForOne() public {
        uint256 amount = 0.1 ether;
        TrailLimitChoice choice = TrailLimitChoice.ONE_PERCENT;

        // Place order at current tick
        (, int24 currentTick,,) = StateLibrary.getSlot0(manager, key.toId());
        placeOrder(choice, currentTick, amount, true);

        // Perform large oneForZero swap to move price up significantly
        // This should trigger take-profit condition in afterSwap
        SwapParams memory params = SwapParams({
            zeroForOne: false,
            amountSpecified: -5 ether,
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(60))
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: true,
            settleUsingBurn: false
        });

        deal(address(token1), address(this), 10 ether);
        swapRouter.swap(key, params, testSettings, "");

        // Check if order was executed by checking claimable tokens
        uint256 orderId = hook.getOrderId(key, currentTick + choice.asTickDiff(), true);
        assertGt(hook.claimableOutputTokens(orderId), 0, "Take profit should have executed");
    }

    function test_trailOrder_TriggerTakeProfit_OneForZero() public {
        uint256 amount = 0.1 ether;
        TrailLimitChoice choice = TrailLimitChoice.ONE_PERCENT;

        (, int24 currentTick,,) = StateLibrary.getSlot0(manager, key.toId());
        placeOrder(choice, currentTick, amount, false);

        // Perform large zeroForOne swap to move price down
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -5 ether,
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(60))
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: true,
            settleUsingBurn: false
        });

        deal(address(token0), address(this), 10 ether);
        swapRouter.swap(key, params, testSettings, "");

        uint256 orderId = hook.getOrderId(key, currentTick - choice.asTickDiff(), false);
        assertGt(hook.claimableOutputTokens(orderId), 0, "Take profit should have executed");
    }

    function test_trailOrder_ExpiryCleanup() public {
        uint256 amount = 0.1 ether;
        TrailLimitChoice choice = TrailLimitChoice.ONE_PERCENT;

        // Place order
        (, int24 currentTick,,) = StateLibrary.getSlot0(manager, key.toId());
        placeOrder(choice, currentTick, amount, true);

        // Warp past 12 hour expiry
        vm.warp(block.timestamp + 13 hours);

        // Trigger swap - expired order should be cleaned up (deleted)
        SwapParams memory params = SwapParams({
            zeroForOne: false,
            amountSpecified: -0.1 ether,
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(60))
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: true,
            settleUsingBurn: false
        });

        swapRouter.swap(key, params, testSettings, "");

        // Order should not have been executed (no claimable tokens)
        uint256 orderId = hook.getOrderId(key, currentTick, true);
        assertEq(hook.claimableOutputTokens(orderId), 0, "Expired order should not execute");
    }

    function test_trailOrder_MultipleThresholds() public {
        uint256 amount = 0.05 ether;

        (, int24 currentTick,,) = StateLibrary.getSlot0(manager, key.toId());

        // Place orders at different trail percentages
        placeOrder(TrailLimitChoice.ONE_PERCENT, currentTick, amount, true);
        placeOrder(TrailLimitChoice.FIVE_PERCENT, currentTick, amount, true);

        // Small price move - only 1% threshold should trigger
        SwapParams memory params = SwapParams({
            zeroForOne: false,
            amountSpecified: -1 ether, // Moderate move
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(60))
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: true,
            settleUsingBurn: false
        });

        swapRouter.swap(key, params, testSettings, "");

        // 1% order should execute
        uint256 orderId1 = hook.getOrderId(key, currentTick + 100, true);
        assertGt(hook.claimableOutputTokens(orderId1), 0);

        // 5% order should NOT execute yet
        uint256 orderId5 = hook.getOrderId(key, currentTick + 490, true);
        assertEq(hook.claimableOutputTokens(orderId5), 0);
    }

    function test_poolTrailStates_Initialization() public {
        (int24 _priceChangeTick, bool isInitialized, bool _isDownward) = hook.poolTrailStates(key.toId());
        assertTrue(isInitialized);
        assertEq(hook.lastTicks(key.toId()), 0);
    }
}
