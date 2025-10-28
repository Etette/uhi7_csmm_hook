// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

contract CSMM is IHooks {
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable poolManager;

    error AddLiquidityThroughHook();
    error InsufficientShares();
    error InsufficientLiquidity();
    error OnlyPoolManager();
    error HookNotImplemented();

    // LP tokens and actions events
    event Transfer(address indexed from, address indexed to, uint256 amount, PoolId indexed id);
    event HookModifyLiquidity(
        bytes32 indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1
    );
    event HookSwap(
        bytes32 indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint128 hookLPfeeAmount0,
        uint128 hookLPfeeAmount1
    );

    // store LP receipt tokens
    mapping(PoolId => uint256) public totalSupply;
    mapping(PoolId => mapping(address => uint256)) public balanceOf;
    
    // reserves tracker
    mapping(PoolId => uint256) public reserve0;
    mapping(PoolId => uint256) public reserve1;

    struct CallbackData {
        uint256 amount0;
        uint256 amount1;
        Currency currency0;
        Currency currency1;
        address sender;
        PoolId poolId;
        bool isRemoveLiquidity; // add/remove flag
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true, 
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, 
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, 
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // --- Receipt Token Functions ---
    function _mint(address to, PoolId poolId, uint256 amount) internal {
        totalSupply[poolId] += amount;
        balanceOf[poolId][to] += amount;
        emit Transfer(address(0), to, amount, poolId);
    }

    function _burn(address from, PoolId poolId, uint256 amount) internal {
        if (balanceOf[poolId][from] < amount) revert InsufficientShares();
        totalSupply[poolId] -= amount;
        balanceOf[poolId][from] -= amount;
        emit Transfer(from, address(0), amount, poolId);
    }

    function transfer(address to, PoolId poolId, uint256 amount) external returns (bool) {
        _burn(msg.sender, poolId, amount);
        _mint(to, poolId, amount);
        return true;
    }

    // --- Liquidity Management ---
    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert AddLiquidityThroughHook();
    }

    function addLiquidity(PoolKey calldata key, uint256 amountEach) external {
        PoolId poolId = key.toId();
        poolManager.unlock(abi.encode(CallbackData(amountEach, amountEach, key.currency0, key.currency1, msg.sender, poolId, false)));
        
        // update reserves
        reserve0[poolId] += amountEach;
        reserve1[poolId] += amountEach;
    
        _mint(msg.sender, poolId, amountEach);
        
        emit HookModifyLiquidity(PoolId.unwrap(poolId), msg.sender, int128(uint128(amountEach)), int128(uint128(amountEach)));
    }

    function removeLiquidity(PoolKey calldata key, uint256 shares) external {
        PoolId poolId = key.toId();
        if (balanceOf[poolId][msg.sender] < shares) revert InsufficientShares();

        uint256 totalShares = totalSupply[poolId];
        uint256 amount0 = (shares * reserve0[poolId]) / totalShares;
        uint256 amount1 = (shares * reserve1[poolId]) / totalShares;

        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidity();

        reserve0[poolId] -= amount0;
        reserve1[poolId] -= amount1;
    
        _burn(msg.sender, poolId, shares);
        
        poolManager.unlock(abi.encode(CallbackData(amount0, amount1, key.currency0, key.currency1, msg.sender, poolId, true)));
        
        emit HookModifyLiquidity(PoolId.unwrap(poolId), msg.sender, -int128(uint128(amount0)), -int128(uint128(amount1)));
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        if (!callbackData.isRemoveLiquidity) {
            // settle tokens from user and take claim tokens
            callbackData.currency0.settle(poolManager, callbackData.sender, callbackData.amount0, false);
            callbackData.currency1.settle(poolManager, callbackData.sender, callbackData.amount1, false);
            callbackData.currency0.take(poolManager, address(this), callbackData.amount0, true);
            callbackData.currency1.take(poolManager, address(this), callbackData.amount1, true);
        } else {
            // burn hook's claim tokens and send underlying to user
            callbackData.currency0.settle(poolManager, address(this), callbackData.amount0, true);
            callbackData.currency1.settle(poolManager, address(this), callbackData.amount1, true);
            callbackData.currency0.take(poolManager, callbackData.sender, callbackData.amount0, false);
            callbackData.currency1.take(poolManager, callbackData.sender, callbackData.amount1, false);
        }
        return "";
    }

    // --- Swap Logic ---
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        uint256 amountInOutPositive = params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified);

        // swap delta for 1:1 pricing
        BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(
            int128(-params.amountSpecified),
            int128(params.amountSpecified)
        );

        // manage claim tokens for the swap and update reserves
        if (params.zeroForOne) {
            key.currency0.take(poolManager, address(this), amountInOutPositive, true);
            key.currency1.settle(poolManager, address(this), amountInOutPositive, true);
            
            reserve0[poolId] += amountInOutPositive;
            reserve1[poolId] -= amountInOutPositive;
            
            emit HookSwap(PoolId.unwrap(poolId), sender, -int128(uint128(amountInOutPositive)), int128(uint128(amountInOutPositive)), 0, 0);
        } else {
            key.currency0.settle(poolManager, address(this), amountInOutPositive, true);
            key.currency1.take(poolManager, address(this), amountInOutPositive, true);
            
            reserve0[poolId] -= amountInOutPositive;
            reserve1[poolId] += amountInOutPositive;
            
            emit HookSwap(PoolId.unwrap(poolId), sender, int128(uint128(amountInOutPositive)), -int128(uint128(amountInOutPositive)), 0, 0);
        }
        return (this.beforeSwap.selector, beforeSwapDelta, 0);
    }

    // --- helpers ---
    function getLiquidityShare(PoolKey calldata key, address user) external view returns (uint256) {
        return balanceOf[key.toId()][user];
    }

    function getWithdrawalAmounts(PoolKey calldata key, uint256 shares) external view returns (uint256 amount0, uint256 amount1) {
        PoolId poolId = key.toId();
        uint256 total = totalSupply[poolId];
        if (total == 0) return (0, 0);
        amount0 = (shares * reserve0[poolId]) / total;
        amount1 = (shares * reserve1[poolId]) / total;
    }
    
    function getReserves(PoolKey calldata key) external view returns (uint256, uint256) {
        PoolId poolId = key.toId();
        return (reserve0[poolId], reserve1[poolId]);
    }

    // --- IHooks Implementation (Unimplemented hooks) ---
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function afterSwap(
        address,
        PoolKey calldata,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, int128) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}