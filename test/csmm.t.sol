// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {CSMM} from "../src/CSMM.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

contract CSMMTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    CSMM hook;

    address liquidityProvider = address(0x100);
    address liquidityProvider2 = address(0x101);
    address trader1 = address(0x200);
    address trader2 = address(0x300);

    function setUp() public {
        // Deploy manager and routers
        deployFreshManagerAndRouters();
        
        // Deploy test tokens and set up approvals
        deployMintAndApprove2Currencies();
        
        // Deploy hook with proper flags in address
        address hookAddress = address(
            uint160(
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            )
        );
        deployCodeTo("CSMM.sol", abi.encode(manager), hookAddress);
        hook = CSMM(hookAddress);

        // Initialize pool
        (key, ) = initPool(
            currency0,
            currency1,
            hook,
            3000, // fee - not used by our hook but required
            TickMath.MAX_SQRT_PRICE - 1 // sqrtPrice - not used but required
        );

        // Fund and approve for liquidity providers
        deal(Currency.unwrap(currency0), liquidityProvider, 100000 ether);
        deal(Currency.unwrap(currency1), liquidityProvider, 100000 ether);
        deal(Currency.unwrap(currency0), liquidityProvider2, 100000 ether);
        deal(Currency.unwrap(currency1), liquidityProvider2, 100000 ether);

        vm.startPrank(liquidityProvider);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(liquidityProvider2);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();

        // Set up traders
        deal(Currency.unwrap(currency0), trader1, 100000 ether);
        deal(Currency.unwrap(currency1), trader1, 100000 ether);
        deal(Currency.unwrap(currency0), trader2, 100000 ether);
        deal(Currency.unwrap(currency1), trader2, 100000 ether);

        vm.startPrank(trader1);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(trader2);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ============================================
    // Test 1: Basic liquidity addition
    // ============================================
    function test_AddLiquidity() public {
        vm.startPrank(liquidityProvider);
        
        uint256 initialBalance0 = currency0.balanceOf(liquidityProvider);
        uint256 initialBalance1 = currency1.balanceOf(liquidityProvider);
        uint256 liquidityAmount = 1000 ether;

        // Add liquidity
        hook.addLiquidity(key, liquidityAmount);

        // Check token balances decreased
        assertEq(currency0.balanceOf(liquidityProvider), initialBalance0 - liquidityAmount);
        assertEq(currency1.balanceOf(liquidityProvider), initialBalance1 - liquidityAmount);

        // Check receipt tokens minted
        assertEq(hook.balanceOf(key.toId(), liquidityProvider), liquidityAmount);
        assertEq(hook.totalSupply(key.toId()), liquidityAmount);

        // Check reserves updated
        (uint256 reserve0, uint256 reserve1) = hook.getReserves(key);
        assertEq(reserve0, liquidityAmount);
        assertEq(reserve1, liquidityAmount);

        vm.stopPrank();
    }

    // ============================================
    // Test 2: Multiple liquidity providers
    // ============================================
    function test_MultipleLiquidityProviders() public {
        uint256 liquidityAmount = 1000 ether;

        // First LP adds liquidity
        vm.prank(liquidityProvider);
        hook.addLiquidity(key, liquidityAmount);

        // Second LP adds liquidity
        vm.prank(liquidityProvider2);
        hook.addLiquidity(key, liquidityAmount);

        // Check total supply and individual balances
        assertEq(hook.totalSupply(key.toId()), liquidityAmount * 2);
        assertEq(hook.balanceOf(key.toId(), liquidityProvider), liquidityAmount);
        assertEq(hook.balanceOf(key.toId(), liquidityProvider2), liquidityAmount);

        // Check reserves doubled
        (uint256 reserve0, uint256 reserve1) = hook.getReserves(key);
        assertEq(reserve0, liquidityAmount * 2);
        assertEq(reserve1, liquidityAmount * 2);
    }

    // ============================================
    // Test 3: Remove liquidity (partial)
    // ============================================
    function test_RemoveLiquidity_Partial() public {
        vm.startPrank(liquidityProvider);
        
        uint256 liquidityAmount = 1000 ether;
        hook.addLiquidity(key, liquidityAmount);

        uint256 initialBalance0 = currency0.balanceOf(liquidityProvider);
        uint256 initialBalance1 = currency1.balanceOf(liquidityProvider);

        // Remove half of liquidity
        uint256 sharesToRemove = liquidityAmount / 2;
        hook.removeLiquidity(key, sharesToRemove);

        // Check receipt tokens burned
        assertEq(hook.balanceOf(key.toId(), liquidityProvider), liquidityAmount - sharesToRemove);
        assertEq(hook.totalSupply(key.toId()), liquidityAmount - sharesToRemove);

        // Check tokens returned (exactly half)
        uint256 finalBalance0 = currency0.balanceOf(liquidityProvider);
        uint256 finalBalance1 = currency1.balanceOf(liquidityProvider);
        assertEq(finalBalance0 - initialBalance0, liquidityAmount / 2);
        assertEq(finalBalance1 - initialBalance1, liquidityAmount / 2);

        // Check reserves decreased
        (uint256 reserve0, uint256 reserve1) = hook.getReserves(key);
        assertEq(reserve0, liquidityAmount / 2);
        assertEq(reserve1, liquidityAmount / 2);

        vm.stopPrank();
    }

    // ============================================
    // Test 4: Remove all liquidity
    // ============================================
    function test_RemoveLiquidity_All() public {
        vm.startPrank(liquidityProvider);
        
        uint256 liquidityAmount = 1000 ether;
        uint256 initialBalance0 = currency0.balanceOf(liquidityProvider);
        uint256 initialBalance1 = currency1.balanceOf(liquidityProvider);

        hook.addLiquidity(key, liquidityAmount);
        hook.removeLiquidity(key, liquidityAmount);

        // Check all receipt tokens burned
        assertEq(hook.balanceOf(key.toId(), liquidityProvider), 0);
        assertEq(hook.totalSupply(key.toId()), 0);

        // Check all tokens returned
        uint256 finalBalance0 = currency0.balanceOf(liquidityProvider);
        uint256 finalBalance1 = currency1.balanceOf(liquidityProvider);
        assertEq(finalBalance0, initialBalance0);
        assertEq(finalBalance1, initialBalance1);

        // Check reserves emptied
        (uint256 reserve0, uint256 reserve1) = hook.getReserves(key);
        assertEq(reserve0, 0);
        assertEq(reserve1, 0);

        vm.stopPrank();
    }

    // ============================================
    // Test 5: Exact input swap - zeroForOne
    // ============================================
    function test_Swap_ExactInput_ZeroForOne() public {
        // Setup liquidity first
        vm.prank(liquidityProvider);
        hook.addLiquidity(key, 10000 ether);

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        vm.startPrank(trader1);
        
        uint256 swapAmount = 100 ether;
        uint256 balance0Before = currency0.balanceOf(trader1);
        uint256 balance1Before = currency1.balanceOf(trader1);

        // Swap exact input: 100 token0 for token1
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        // Check balances changed by exactly swap amount (1:1 ratio)
        uint256 balance0After = currency0.balanceOf(trader1);
        uint256 balance1After = currency1.balanceOf(trader1);
        assertEq(balance0Before - balance0After, swapAmount);
        assertEq(balance1After - balance1Before, swapAmount);

        // Check reserves shifted correctly
        (uint256 reserve0, uint256 reserve1) = hook.getReserves(key);
        assertEq(reserve0, 10000 ether + swapAmount);
        assertEq(reserve1, 10000 ether - swapAmount);

        vm.stopPrank();
    }

    // ============================================
    // Test 6: Exact output swap - zeroForOne
    // ============================================
    function test_Swap_ExactOutput_ZeroForOne() public {
        vm.prank(liquidityProvider);
        hook.addLiquidity(key, 10000 ether);

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        vm.startPrank(trader1);
        
        uint256 swapAmount = 100 ether;
        uint256 balance0Before = currency0.balanceOf(trader1);
        uint256 balance1Before = currency1.balanceOf(trader1);

        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(swapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        uint256 balance0After = currency0.balanceOf(trader1);
        uint256 balance1After = currency1.balanceOf(trader1);
        assertEq(balance0Before - balance0After, swapAmount);
        assertEq(balance1After - balance1Before, swapAmount);

        vm.stopPrank();
    }

    // ============================================
    // Test 7: Exact input swap - oneForZero
    // ============================================
    function test_Swap_ExactInput_OneForZero() public {
        vm.prank(liquidityProvider);
        hook.addLiquidity(key, 10000 ether);

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        vm.startPrank(trader1);
        
        uint256 swapAmount = 100 ether;
        uint256 balance0Before = currency0.balanceOf(trader1);
        uint256 balance1Before = currency1.balanceOf(trader1);

        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            settings,
            ZERO_BYTES
        );

        uint256 balance0After = currency0.balanceOf(trader1);
        uint256 balance1After = currency1.balanceOf(trader1);
        assertEq(balance1Before - balance1After, swapAmount);
        assertEq(balance0After - balance0Before, swapAmount);

        // Check reserves shifted correctly
        (uint256 reserve0, uint256 reserve1) = hook.getReserves(key);
        assertEq(reserve0, 10000 ether - swapAmount);
        assertEq(reserve1, 10000 ether + swapAmount);

        vm.stopPrank();
    }

    // ============================================
    // Test 8: Exact output swap - oneForZero
    // ============================================
    function test_Swap_ExactOutput_OneForZero() public {
        vm.prank(liquidityProvider);
        hook.addLiquidity(key, 10000 ether);

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        vm.startPrank(trader1);
        
        uint256 swapAmount = 100 ether;
        uint256 balance0Before = currency0.balanceOf(trader1);
        uint256 balance1Before = currency1.balanceOf(trader1);

        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: int256(swapAmount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            settings,
            ZERO_BYTES
        );

        uint256 balance0After = currency0.balanceOf(trader1);
        uint256 balance1After = currency1.balanceOf(trader1);
        assertEq(balance1Before - balance1After, swapAmount);
        assertEq(balance0After - balance0Before, swapAmount);

        vm.stopPrank();
    }

    // ============================================
    // Test 9: Transfer receipt tokens
    // ============================================
    function test_TransferReceiptTokens() public {
        vm.startPrank(liquidityProvider);
        
        uint256 liquidityAmount = 1000 ether;
        hook.addLiquidity(key, liquidityAmount);

        // Transfer half to another address
        uint256 transferAmount = liquidityAmount / 2;
        hook.transfer(trader1, key.toId(), transferAmount);

        // Check balances updated
        assertEq(hook.balanceOf(key.toId(), liquidityProvider), liquidityAmount - transferAmount);
        assertEq(hook.balanceOf(key.toId(), trader1), transferAmount);
        assertEq(hook.totalSupply(key.toId()), liquidityAmount);

        vm.stopPrank();
    }

    // ============================================
    // Test 10: Cannot remove more liquidity than owned
    // ============================================
    function test_RevertWhen_RemoveMoreThanOwned() public {
        vm.startPrank(liquidityProvider);
        
        uint256 liquidityAmount = 1000 ether;
        hook.addLiquidity(key, liquidityAmount);

        vm.expectRevert(CSMM.InsufficientShares.selector);
        hook.removeLiquidity(key, liquidityAmount + 1 ether);

        vm.stopPrank();
    }

    // ============================================
    // Test 11: Cannot add liquidity through PoolManager
    // ============================================
    function test_RevertWhen_AddLiquidityThroughPoolManager() public {
        vm.expectRevert(CSMM.AddLiquidityThroughHook.selector);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1e18,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    // ============================================
    // Test 12: Multiple swaps maintain 1:1 ratio
    // ============================================
    function test_MultipleSwapsMaintainRatio() public {
        vm.prank(liquidityProvider);
        hook.addLiquidity(key, 10000 ether);

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        vm.startPrank(trader1);
        uint256 initialBalance0 = currency0.balanceOf(trader1);
        uint256 initialBalance1 = currency1.balanceOf(trader1);

        // First swap: 100 token0 → token1
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -100 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        // Second swap: 50 token0 → token1
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -50 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        // Third swap: 75 token1 → token0
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -75 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            settings,
            ZERO_BYTES
        );

        // Net: spent 150 token0, got 150 token1 back, then spent 75 token1, got 75 token0 back
        // Final: -75 token0, +75 token1
        uint256 finalBalance0 = currency0.balanceOf(trader1);
        uint256 finalBalance1 = currency1.balanceOf(trader1);

        assertEq(initialBalance0 - finalBalance0, 75 ether);
        assertEq(finalBalance1 - initialBalance1, 75 ether);

        vm.stopPrank();
    }

    // ============================================
    // Test 13: Withdrawal amounts calculation
    // ============================================
    function test_GetWithdrawalAmounts() public {
        vm.startPrank(liquidityProvider);
        
        uint256 liquidityAmount = 1000 ether;
        hook.addLiquidity(key, liquidityAmount);

        // Test getting withdrawal amounts for half shares
        (uint256 amount0, uint256 amount1) = hook.getWithdrawalAmounts(key, liquidityAmount / 2);
        
        assertEq(amount0, liquidityAmount / 2);
        assertEq(amount1, liquidityAmount / 2);

        vm.stopPrank();
    }

    // ============================================
    // Test 14: Get liquidity share
    // ============================================
    function test_GetLiquidityShare() public {
        vm.prank(liquidityProvider);
        hook.addLiquidity(key, 1000 ether);

        uint256 share = hook.getLiquidityShare(key, liquidityProvider);
        assertEq(share, 1000 ether);

        uint256 shareTrader = hook.getLiquidityShare(key, trader1);
        assertEq(shareTrader, 0);
    }

    // ============================================
    // Test 15: Claim token balances verification
    // ============================================
    function test_ClaimTokenBalances() public {
        vm.startPrank(liquidityProvider);
        
        uint256 liquidityAmount = 1000 ether;
        hook.addLiquidity(key, liquidityAmount);

        // Hook should have claim tokens for the deposited liquidity
        uint256 token0ClaimID = uint256(uint160(Currency.unwrap(currency0)));
        uint256 token1ClaimID = uint256(uint160(Currency.unwrap(currency1)));

        uint256 hookToken0Claims = manager.balanceOf(address(hook), token0ClaimID);
        uint256 hookToken1Claims = manager.balanceOf(address(hook), token1ClaimID);

        assertEq(hookToken0Claims, liquidityAmount);
        assertEq(hookToken1Claims, liquidityAmount);

        vm.stopPrank();
    }

    // ============================================
    // Test 16: FULL WORKFLOW - Complex scenario
    // ============================================
    function test_FullWorkflow_ComplexScenario() public {
        console.log("=== FULL WORKFLOW TEST ===");
        
        // ===== STEP 1: Initial Liquidity =====
        console.log("\n--- Step 1: Add Initial Liquidity ---");
        vm.startPrank(liquidityProvider);
        uint256 initialLiquidity = 5000 ether;
        hook.addLiquidity(key, initialLiquidity);
        
        assertEq(hook.balanceOf(key.toId(), liquidityProvider), initialLiquidity);
        (uint256 reserve0, uint256 reserve1) = hook.getReserves(key);
        console.log("Reserves after add:", reserve0 / 1e18, reserve1 / 1e18);
        assertEq(reserve0, initialLiquidity);
        assertEq(reserve1, initialLiquidity);
        vm.stopPrank();

        // ===== STEP 2: Second LP Adds Liquidity =====
        console.log("\n--- Step 2: Second LP Adds Liquidity ---");
        vm.prank(liquidityProvider2);
        hook.addLiquidity(key, 3000 ether);
        
        assertEq(hook.totalSupply(key.toId()), 8000 ether);
        (reserve0, reserve1) = hook.getReserves(key);
        console.log("Reserves after LP2:", reserve0 / 1e18, reserve1 / 1e18);

        // ===== STEP 3: Trader 1 Swaps =====
        console.log("\n--- Step 3: Trader 1 Swaps 200 token0 for token1 ---");
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        vm.startPrank(trader1);
        uint256 trader1Balance0Before = currency0.balanceOf(trader1);
        uint256 trader1Balance1Before = currency1.balanceOf(trader1);
        
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -200 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );
        
        assertEq(trader1Balance0Before - currency0.balanceOf(trader1), 200 ether);
        assertEq(currency1.balanceOf(trader1) - trader1Balance1Before, 200 ether);
        
        (reserve0, reserve1) = hook.getReserves(key);
        console.log("Reserves after swap1:", reserve0 / 1e18, reserve1 / 1e18);
        assertEq(reserve0, 8200 ether);
        assertEq(reserve1, 7800 ether);
        vm.stopPrank();

        // ===== STEP 4: Trader 2 Swaps Opposite Direction =====
        console.log("\n--- Step 4: Trader 2 Swaps 150 token1 for token0 ---");
        vm.startPrank(trader2);
        uint256 trader2Balance0Before = currency0.balanceOf(trader2);
        uint256 trader2Balance1Before = currency1.balanceOf(trader2);
        
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -150 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            settings,
            ZERO_BYTES
        );
        
        assertEq(currency0.balanceOf(trader2) - trader2Balance0Before, 150 ether);
        assertEq(trader2Balance1Before - currency1.balanceOf(trader2), 150 ether);
        
        (reserve0, reserve1) = hook.getReserves(key);
        console.log("Reserves after swap2:", reserve0 / 1e18, reserve1 / 1e18);
        assertEq(reserve0, 8050 ether); // 8200 - 150
        assertEq(reserve1, 7950 ether); // 7800 + 150
        vm.stopPrank();

        // ===== STEP 5: LP1 Removes 25% Liquidity =====
        console.log("\n--- Step 5: LP1 Removes 25% Liquidity ---");
        vm.startPrank(liquidityProvider);
        uint256 sharesToRemove = initialLiquidity / 4; // 1250 shares
        uint256 lp1Balance0Before = currency0.balanceOf(liquidityProvider);
        uint256 lp1Balance1Before = currency1.balanceOf(liquidityProvider);
        
        // Calculate expected withdrawal (proportional to current reserves)
        (uint256 expectedAmount0, uint256 expectedAmount1) = hook.getWithdrawalAmounts(key, sharesToRemove);
        console.log("Expected withdrawal:", expectedAmount0 / 1e18, expectedAmount1 / 1e18);
        
        hook.removeLiquidity(key, sharesToRemove);
        
        // Check LP1 got proportional share based on current reserves
        uint256 lp1ReceivedToken0 = currency0.balanceOf(liquidityProvider) - lp1Balance0Before;
        uint256 lp1ReceivedToken1 = currency1.balanceOf(liquidityProvider) - lp1Balance1Before;
        
        console.log("LP1 received:", lp1ReceivedToken0 / 1e18, lp1ReceivedToken1 / 1e18);
        assertEq(lp1ReceivedToken0, expectedAmount0);
        assertEq(lp1ReceivedToken1, expectedAmount1);
        
        // Check receipt tokens decreased
        // assertEq(hook.balanceOf(key.toId(), liquidityProvider), initialLiquidity - sharesToRemove);
        
        (reserve0, reserve1) = hook.getReserves(key);
        // console.log("Reserves after removal:", reserve0 / 1e18, reserve1 / 1e18);
        vm.stopPrank();

        // ===== STEP 6: Transfer Receipt Tokens =====
        console.log("\n--- Step 6: LP2 Transfers Half of Receipt Tokens to Trader1 ---");
        vm.startPrank(liquidityProvider2);
        uint256 lp2Shares = hook.balanceOf(key.toId(), liquidityProvider2);
        hook.transfer(trader1, key.toId(), lp2Shares / 2);
        
        assertEq(hook.balanceOf(key.toId(), liquidityProvider2), lp2Shares / 2);
        assertEq(hook.balanceOf(key.toId(), trader1), lp2Shares / 2);
        vm.stopPrank();

        // ===== STEP 7: Trader1 (now LP) Removes Their Liquidity =====
        console.log("\n--- Step 7: Trader1 Removes Their Received Liquidity ---");
        vm.startPrank(trader1);
        uint256 trader1Shares = hook.balanceOf(key.toId(), trader1);
        uint256 trader1Balance0BeforeRemoval = currency0.balanceOf(trader1);
        uint256 trader1Balance1BeforeRemoval = currency1.balanceOf(trader1);
        
        hook.removeLiquidity(key, trader1Shares);
        
        uint256 trader1Received0 = currency0.balanceOf(trader1) - trader1Balance0BeforeRemoval;
        uint256 trader1Received1 = currency1.balanceOf(trader1) - trader1Balance1BeforeRemoval;
        console.log("Trader1 received:", trader1Received0 / 1e18, trader1Received1 / 1e18);
        
        // Trader1 should have 0 shares now
        assertEq(hook.balanceOf(key.toId(), trader1), 0);
        vm.stopPrank();

        // ===== STEP 8: Final State Verification =====
        // console.log("\n--- Step 8: Final State ---");
        // (reserve0, reserve1) = hook.getReserves(key);
        // uint256 totalShares = hook.totalSupply(key.toId());
        
        // console.log("Final reserves:", reserve0 / 1e18, reserve1 / 1e18);
        // console.log("Final total shares:", totalShares / 1e18);
        
        // // Verify remaining LPs
        // uint256 lp1Remaining = hook.balanceOf(key.toId(), liquidityProvider);
        // uint256 lp2Remaining = hook.balanceOf(key.toId(), liquidityProvider2);
        // console.log("LP1 remaining shares:", lp1Remaining / 1e18);
        // console.log("LP2 remaining shares:", lp2Remaining / 1e18);
        
        // // Total shares should equal sum of individual shares
        // assertEq(totalShares, lp1Remaining + lp2Remaining);
        
        // // Reserves should be proportional to remaining shares
        // assertTrue(reserve0 > 0);
        // assertTrue(reserve1 > 0);
        
        console.log("\n=== WORKFLOW COMPLETED SUCCESSFULLY ===");
    }

    // ============================================
    // Test 17: Liquidity removal after swaps affects ratios
    // ============================================
    function test_LiquidityRemovalAfterSwaps() public {
        // Add liquidity from two LPs
        vm.prank(liquidityProvider);
        hook.addLiquidity(key, 1000 ether);
        
        vm.prank(liquidityProvider2);
        hook.addLiquidity(key, 1000 ether);

        // Check initial state
        (uint256 reserve0Before, uint256 reserve1Before) = hook.getReserves(key);
        assertEq(reserve0Before, 2000 ether);
        assertEq(reserve1Before, 2000 ether);

        // Perform swap that shifts reserves
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        vm.prank(trader1);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -500 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        // Check reserves shifted
        (uint256 reserve0After, uint256 reserve1After) = hook.getReserves(key);
        assertEq(reserve0After, 2500 ether);
        assertEq(reserve1After, 1500 ether);

        // LP1 removes their share (50% of total)
        vm.startPrank(liquidityProvider);
        uint256 lp1Shares = hook.balanceOf(key.toId(), liquidityProvider);
        uint256 lp1Balance0Before = currency0.balanceOf(liquidityProvider);
        uint256 lp1Balance1Before = currency1.balanceOf(liquidityProvider);
        
        hook.removeLiquidity(key, lp1Shares);
        
        // LP1 should get 50% of current reserves (not original 1:1 ratio)
        uint256 received0 = currency0.balanceOf(liquidityProvider) - lp1Balance0Before;
        uint256 received1 = currency1.balanceOf(liquidityProvider) - lp1Balance1Before;
        
        assertEq(received0, 1250 ether); // 50% of 2500
        assertEq(received1, 750 ether);  // 50% of 1500
        
        // Note: LP1 deposited 1000 of each but got back 1250/750
        // This is fair because they own 50% of the pool at current state
        console.log("LP1 deposited 1000/1000, received:", received0 / 1e18, received1 / 1e18);
        
        vm.stopPrank();
    }

    // ============================================
    // Test 18: Cannot remove liquidity with zero shares
    // ============================================
    function test_RevertWhen_RemoveLiquidityWithZeroShares() public {
        vm.prank(liquidityProvider);
        hook.addLiquidity(key, 1000 ether);

        vm.startPrank(trader1); // trader1 has no shares
        vm.expectRevert(CSMM.InsufficientShares.selector);
        hook.removeLiquidity(key, 1 ether);
        vm.stopPrank();
    }

    // ============================================
    // Test 19: Multiple LPs with different shares
    // ============================================
    function test_MultipleLPsWithDifferentShares() public {
        // LP1 adds 1000
        vm.prank(liquidityProvider);
        hook.addLiquidity(key, 1000 ether);

        // LP2 adds 3000
        vm.prank(liquidityProvider2);
        hook.addLiquidity(key, 3000 ether);

        // Total should be 4000
        assertEq(hook.totalSupply(key.toId()), 4000 ether);

        // LP1 has 25%, LP2 has 75%
        assertEq(hook.balanceOf(key.toId(), liquidityProvider), 1000 ether);
        assertEq(hook.balanceOf(key.toId(), liquidityProvider2), 3000 ether);

        // Perform swap
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        vm.prank(trader1);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -400 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        // Check reserves
        (uint256 reserve0, uint256 reserve1) = hook.getReserves(key);
        assertEq(reserve0, 4400 ether);
        assertEq(reserve1, 3600 ether);

        // LP1 removes all their liquidity (25% of pool)
        vm.startPrank(liquidityProvider);
        (uint256 expectedAmount0, uint256 expectedAmount1) = hook.getWithdrawalAmounts(key, 1000 ether);
        
        assertEq(expectedAmount0, 1100 ether); // 25% of 4400
        assertEq(expectedAmount1, 900 ether);  // 25% of 3600

        uint256 balance0Before = currency0.balanceOf(liquidityProvider);
        uint256 balance1Before = currency1.balanceOf(liquidityProvider);
        
        hook.removeLiquidity(key, 1000 ether);
        
        assertEq(currency0.balanceOf(liquidityProvider) - balance0Before, 1100 ether);
        assertEq(currency1.balanceOf(liquidityProvider) - balance1Before, 900 ether);
        vm.stopPrank();

        // LP2 should still have their 3000 shares representing 100% of remaining pool
        assertEq(hook.totalSupply(key.toId()), 3000 ether);
        assertEq(hook.balanceOf(key.toId(), liquidityProvider2), 3000 ether);
    }

    // ============================================
    // Test 20: Reserve tracking accuracy
    // ============================================
    function test_ReserveTrackingAccuracy() public {
        vm.prank(liquidityProvider);
        hook.addLiquidity(key, 5000 ether);

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // Multiple swaps in different directions
        vm.startPrank(trader1);
        
        // Swap 1: 100 token0 -> token1
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -100 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );
        (uint256 r0, uint256 r1) = hook.getReserves(key);
        assertEq(r0, 5100 ether);
        assertEq(r1, 4900 ether);

        // Swap 2: 200 token1 -> token0
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -200 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            settings,
            ZERO_BYTES
        );
        (r0, r1) = hook.getReserves(key);
        assertEq(r0, 4900 ether); // 5100 - 200
        assertEq(r1, 5100 ether); // 4900 + 200

        // Swap 3: 50 token0 -> token1
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -50 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );
        (r0, r1) = hook.getReserves(key);
        assertEq(r0, 4950 ether); // 4900 + 50
        assertEq(r1, 5050 ether); // 5100 - 50

        vm.stopPrank();
    }

    // ============================================
    // Test 21: Edge case - Remove liquidity immediately after adding
    // ============================================
    function test_RemoveLiquidityImmediately() public {
        vm.startPrank(liquidityProvider);
        
        uint256 amount = 1000 ether;
        uint256 balance0Before = currency0.balanceOf(liquidityProvider);
        uint256 balance1Before = currency1.balanceOf(liquidityProvider);

        hook.addLiquidity(key, amount);
        hook.removeLiquidity(key, amount);

        // Should get back exactly what was put in (no swaps occurred)
        assertEq(currency0.balanceOf(liquidityProvider), balance0Before);
        assertEq(currency1.balanceOf(liquidityProvider), balance1Before);
        assertEq(hook.balanceOf(key.toId(), liquidityProvider), 0);
        assertEq(hook.totalSupply(key.toId()), 0);

        vm.stopPrank();
    }

    // ============================================
    // Test 22: Transfer receipt tokens and then remove
    // ============================================
    function test_TransferThenRemoveLiquidity() public {
        // LP1 adds liquidity
        vm.prank(liquidityProvider);
        hook.addLiquidity(key, 1000 ether);

        // LP1 transfers to trader1
        vm.prank(liquidityProvider);
        hook.transfer(trader1, key.toId(), 500 ether);

        // Trader1 should be able to remove the liquidity they received
        vm.startPrank(trader1);
        uint256 balance0Before = currency0.balanceOf(trader1);
        uint256 balance1Before = currency1.balanceOf(trader1);
        
        hook.removeLiquidity(key, 500 ether);
        
        // Trader1 should receive 50% of the pool
        assertEq(currency0.balanceOf(trader1) - balance0Before, 500 ether);
        assertEq(currency1.balanceOf(trader1) - balance1Before, 500 ether);
        assertEq(hook.balanceOf(key.toId(), trader1), 0);
        
        vm.stopPrank();

        // LP1 should still have their remaining 500 shares
        assertEq(hook.balanceOf(key.toId(), liquidityProvider), 500 ether);
    }

    // ============================================
    // Test 23: Large swap stress test
    // ============================================
    function test_LargeSwapStressTest() public {
        // Add substantial liquidity
        vm.prank(liquidityProvider);
        hook.addLiquidity(key, 100000 ether);

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // Perform large swap (90% of liquidity)
        vm.startPrank(trader1);
        uint256 largeSwapAmount = 90000 ether;
        
        uint256 balance0Before = currency0.balanceOf(trader1);
        uint256 balance1Before = currency1.balanceOf(trader1);
        
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(largeSwapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        // Verify 1:1 ratio maintained even for large swaps
        assertEq(balance0Before - currency0.balanceOf(trader1), largeSwapAmount);
        assertEq(currency1.balanceOf(trader1) - balance1Before, largeSwapAmount);

        // Check reserves shifted dramatically
        (uint256 reserve0, uint256 reserve1) = hook.getReserves(key);
        assertEq(reserve0, 190000 ether);
        assertEq(reserve1, 10000 ether);

        vm.stopPrank();

        // LP can still remove liquidity proportionally
        vm.startPrank(liquidityProvider);
        hook.removeLiquidity(key, 50000 ether); // Remove 50%
        
        (reserve0, reserve1) = hook.getReserves(key);
        assertEq(reserve0, 95000 ether); // 50% of 190000
        assertEq(reserve1, 5000 ether);  // 50% of 10000
        
        vm.stopPrank();
    }

    // ============================================
    // Test 24: Withdrawal calculations before and after swaps
    // ============================================
    function test_WithdrawalCalculationsWithSwaps() public {
        vm.prank(liquidityProvider);
        hook.addLiquidity(key, 2000 ether);

        // Before any swaps - should be 1:1
        (uint256 amount0Before, uint256 amount1Before) = hook.getWithdrawalAmounts(key, 1000 ether);
        assertEq(amount0Before, 1000 ether);
        assertEq(amount1Before, 1000 ether);

        // Perform swap
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        vm.prank(trader1);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -600 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        // After swap - should reflect new ratios
        (uint256 amount0After, uint256 amount1After) = hook.getWithdrawalAmounts(key, 1000 ether);
        assertEq(amount0After, 1300 ether); // 50% of 2600
        assertEq(amount1After, 700 ether);  // 50% of 1400
        
        // Total value should be roughly the same (2000 total)
        assertEq(amount0After + amount1After, 2000 ether);
    }

    // ============================================
    // Test 25: Zero liquidity edge case
    // ============================================
    function test_GetWithdrawalAmounts_ZeroLiquidity() public {
        // Query withdrawal amounts when no liquidity exists
        (uint256 amount0, uint256 amount1) = hook.getWithdrawalAmounts(key, 100 ether);
        assertEq(amount0, 0);
        assertEq(amount1, 0);

        // Query reserves when no liquidity exists
        (uint256 reserve0, uint256 reserve1) = hook.getReserves(key);
        assertEq(reserve0, 0);
        assertEq(reserve1, 0);
    }
}