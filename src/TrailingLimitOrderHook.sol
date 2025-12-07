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

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

contract TrailingLimitOrderHook is BaseHook, ERC1155 {
    using StateLibrary for IPoolManager;
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    // ERRORS
    error InvalidOrder();
    error NothingToClaim();
    error NotEnoughToClaim();

    // This will be later modified to something like
    // mapping (PoolId poolId => mapping (int24 tickToSellAt => mapping(trailPct => mapping( bool zeroForOne => uint256 inputAmount)))) public pendingOrders;
    mapping(PoolId poolId => mapping(int24 tickToSellAt => mapping(bool zeroForOne => uint256 inputAmount))) public
        pendingOrders;
    mapping(uint256 orderId => uint256 claimsSupply) public claimTokensSupply;
    mapping(uint256 orderId => uint256 outputClaimable) public claimableOutputTokens;

    mapping(PoolId poolId => int24 lastTick) public lastTicks;

    event OrderPlaced(bytes32 indexed orderId, address indexed owner, bool isToken0, uint128 size, int24 trailTicks);
    event OrderCancelled(bytes32 indexed orderId);
    event OrderExecuted(bytes32 indexed orderId, uint128 executedSize, int24 newTick);

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
        return this.afterInitialize.selector;
    }

    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        if(sender == address(this)) return (this.afterSwap.selector, 0);

        bool tryMore = true;
        int24 currentTick;

        while(tryMore){
            (tryMore, currentTick) = tryExecutingOrders(key, !params.zeroForOne);
        }

        lastTicks[key.toId()] = currentTick;
        return (this.afterSwap.selector, 0);
    }

    function tryExecutingOrders(
        PoolKey calldata key,
        bool executeZeroForOne
    ) internal returns (bool tryMore, int24 newTick) {
        (, int24 currentTick, ,) = poolManager.getSlot0(key.toId());
        int24 lastTick = lastTicks[key.toId()];
        
        // If tick has increased (currentTick > lastTick)
        // Token0 price increases
        if(currentTick > lastTick){
            // Loop over all ticks from lastTick to currentTick
            // and execute orders for token0 (zeroForOne = false)

            for(
                int24 tick = lastTick;
                tick < currentTick;
                tick += key.tickSpacing
            ){
                uint256 inputAmount = pendingOrders[key.toId()][tick][executeZeroForOne];
                if(inputAmount > 0){
                    executeOrder(key, tick, executeZeroForOne, inputAmount);
                    return (true, currentTick);
                }
            }
        }

        // If tick has decreased (currentTick < lastTick)
        // Token1 price increases
        else {
            for(int24 tick = lastTick; tick > currentTick; tick -= key.tickSpacing){
                uint256 inputAmount = pendingOrders[key.toId()][tick][executeZeroForOne];
                if (inputAmount > 0) {
                    executeOrder(key, tick, executeZeroForOne, inputAmount);
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

    function placeOrder(PoolKey calldata key, int24 tickToSellAt, bool zeroForOne, uint256 inputAmount)
        external
        returns (int24)
    {
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);

        pendingOrders[key.toId()][tick][zeroForOne] += inputAmount;

        uint256 orderId = getOrderId(key, tick, zeroForOne);
        claimTokensSupply[orderId] += inputAmount;
        _mint(msg.sender, orderId, inputAmount, "");

        address sellToken = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        IERC20(sellToken).safeTransferFrom(msg.sender, address(this), inputAmount);

        return tick;
    }

    function cancelOrder(PoolKey calldata key, int24 tickToSellAt, bool zeroForOne, uint256 amountToCancel) external {
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        uint256 orderId = getOrderId(key, tick, zeroForOne);

        if (balanceOf(msg.sender, orderId) < amountToCancel) {
            revert NotEnoughToClaim();
        }

        pendingOrders[key.toId()][tick][zeroForOne] -= amountToCancel;
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

    function executeOrder(PoolKey calldata key, int24 tick, bool zeroForOne, uint256 inputAmount) internal {
        BalanceDelta delta = swapAndSettleBalances(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(inputAmount),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        pendingOrders[key.toId()][tick][zeroForOne] -= inputAmount;
        uint256 orderId = getOrderId(key, tick, zeroForOne);
        uint256 outputAmount = zeroForOne ? uint256(int256(delta.amount1())) : uint256(int256(delta.amount0()));

        claimableOutputTokens[orderId] += outputAmount;
    }
}   
