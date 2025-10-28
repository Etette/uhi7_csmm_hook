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
        
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        
        address hookAddress = address(
            uint160(
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            )
        );
        deployCodeTo("CSMM.sol", abi.encode(manager), hookAddress);
        hook = CSMM(hookAddress);

        
        (key, ) = initPool(
            currency0,
            currency1,
            hook,
            3000, 
            TickMath.MAX_SQRT_PRICE - 1 
        );

        // fund and approve for liquidity providers
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

        // traders setup
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

  
    function test_AddLiquidity() public {
        vm.startPrank(liquidityProvider);
        
        uint256 initialBalance0 = currency0.balanceOf(liquidityProvider);
        uint256 initialBalance1 = currency1.balanceOf(liquidityProvider);
        uint256 liquidityAmount = 1000 ether;

        // add liquidity
        hook.addLiquidity(key, liquidityAmount);

        assertEq(currency0.balanceOf(liquidityProvider), initialBalance0 - liquidityAmount);
        assertEq(currency1.balanceOf(liquidityProvider), initialBalance1 - liquidityAmount);

        // is receipt tokens minted?
        assertEq(hook.balanceOf(key.toId(), liquidityProvider), liquidityAmount);
        assertEq(hook.totalSupply(key.toId()), liquidityAmount);

        // is reserves updated?
        (uint256 reserve0, uint256 reserve1) = hook.getReserves(key);
        assertEq(reserve0, liquidityAmount);
        assertEq(reserve1, liquidityAmount);

        vm.stopPrank();
    }


    function test_MultipleLiquidityProviders() public {
        uint256 liquidityAmount = 1000 ether;

        vm.prank(liquidityProvider);
        hook.addLiquidity(key, liquidityAmount);

        vm.prank(liquidityProvider2);
        hook.addLiquidity(key, liquidityAmount);
        
        assertEq(hook.totalSupply(key.toId()), liquidityAmount * 2);
        assertEq(hook.balanceOf(key.toId(), liquidityProvider), liquidityAmount);
        assertEq(hook.balanceOf(key.toId(), liquidityProvider2), liquidityAmount);

        (uint256 reserve0, uint256 reserve1) = hook.getReserves(key);
        assertEq(reserve0, liquidityAmount * 2);
        assertEq(reserve1, liquidityAmount * 2);
    }

    
    function test_RemoveLiquidity_Partial() public {
        vm.startPrank(liquidityProvider);
        
        uint256 liquidityAmount = 1000 ether;
        hook.addLiquidity(key, liquidityAmount);

        uint256 initialBalance0 = currency0.balanceOf(liquidityProvider);
        uint256 initialBalance1 = currency1.balanceOf(liquidityProvider);

        // remove half liquidity
        uint256 sharesToRemove = liquidityAmount / 2;
        hook.removeLiquidity(key, sharesToRemove);

        // is receipt tokens burned?
        assertEq(hook.balanceOf(key.toId(), liquidityProvider), liquidityAmount - sharesToRemove);
        assertEq(hook.totalSupply(key.toId()), liquidityAmount - sharesToRemove);

        uint256 finalBalance0 = currency0.balanceOf(liquidityProvider);
        uint256 finalBalance1 = currency1.balanceOf(liquidityProvider);
        assertEq(finalBalance0 - initialBalance0, liquidityAmount / 2);
        assertEq(finalBalance1 - initialBalance1, liquidityAmount / 2);

        (uint256 reserve0, uint256 reserve1) = hook.getReserves(key);
        assertEq(reserve0, liquidityAmount / 2);
        assertEq(reserve1, liquidityAmount / 2);

        vm.stopPrank();
    }

    function test_RemoveLiquidity_All() public {
        vm.startPrank(liquidityProvider);
        
        uint256 liquidityAmount = 1000 ether;
        uint256 initialBalance0 = currency0.balanceOf(liquidityProvider);
        uint256 initialBalance1 = currency1.balanceOf(liquidityProvider);

        hook.addLiquidity(key, liquidityAmount);
        hook.removeLiquidity(key, liquidityAmount);

       
        assertEq(hook.balanceOf(key.toId(), liquidityProvider), 0);
        assertEq(hook.totalSupply(key.toId()), 0);

       
        uint256 finalBalance0 = currency0.balanceOf(liquidityProvider);
        uint256 finalBalance1 = currency1.balanceOf(liquidityProvider);
        assertEq(finalBalance0, initialBalance0);
        assertEq(finalBalance1, initialBalance1);

        (uint256 reserve0, uint256 reserve1) = hook.getReserves(key);
        assertEq(reserve0, 0);
        assertEq(reserve1, 0);

        vm.stopPrank();
    }

    function test_Swap_ExactInput_ZeroForOne() public {
       
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
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

      
        uint256 balance0After = currency0.balanceOf(trader1);
        uint256 balance1After = currency1.balanceOf(trader1);
        assertEq(balance0Before - balance0After, swapAmount);
        assertEq(balance1After - balance1Before, swapAmount);

       
        (uint256 reserve0, uint256 reserve1) = hook.getReserves(key);
        assertEq(reserve0, 10000 ether + swapAmount);
        assertEq(reserve1, 10000 ether - swapAmount);

        vm.stopPrank();
    }

   
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

        // has reserves shifted correctly?
        (uint256 reserve0, uint256 reserve1) = hook.getReserves(key);
        assertEq(reserve0, 10000 ether - swapAmount);
        assertEq(reserve1, 10000 ether + swapAmount);

        vm.stopPrank();
    }

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

    function test_TransferReceiptTokens() public {
        vm.startPrank(liquidityProvider);
        
        uint256 liquidityAmount = 1000 ether;
        hook.addLiquidity(key, liquidityAmount);

        // transfer half to another address
        uint256 transferAmount = liquidityAmount / 2;
        hook.transfer(trader1, key.toId(), transferAmount);

        // is bal updated?
        assertEq(hook.balanceOf(key.toId(), liquidityProvider), liquidityAmount - transferAmount);
        assertEq(hook.balanceOf(key.toId(), trader1), transferAmount);
        assertEq(hook.totalSupply(key.toId()), liquidityAmount);

        vm.stopPrank();
    }

    function test_RevertWhen_RemoveMoreThanOwned() public {
        vm.startPrank(liquidityProvider);
        
        uint256 liquidityAmount = 1000 ether;
        hook.addLiquidity(key, liquidityAmount);

        vm.expectRevert(CSMM.InsufficientShares.selector);
        hook.removeLiquidity(key, liquidityAmount + 1 ether);

        vm.stopPrank();
    }

  
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

        // swap 100 token0 → token1
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

        // swap 50 token0 → token1
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

        //  swap 75 token1 → token0
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

        // total = -75 token0, +75 token1
        uint256 finalBalance0 = currency0.balanceOf(trader1);
        uint256 finalBalance1 = currency1.balanceOf(trader1);
        // assert deltas
        assertEq(initialBalance0 - finalBalance0, 75 ether);
        assertEq(finalBalance1 - initialBalance1, 75 ether);

        vm.stopPrank();
    }


    function test_GetWithdrawalAmounts() public {
        vm.startPrank(liquidityProvider);
        
        uint256 liquidityAmount = 1000 ether;
        hook.addLiquidity(key, liquidityAmount);

        (uint256 amount0, uint256 amount1) = hook.getWithdrawalAmounts(key, liquidityAmount / 2);
        
        assertEq(amount0, liquidityAmount / 2);
        assertEq(amount1, liquidityAmount / 2);

        vm.stopPrank();
    }

    
    function test_GetLiquidityShare() public {
        vm.prank(liquidityProvider);
        hook.addLiquidity(key, 1000 ether);

        uint256 share = hook.getLiquidityShare(key, liquidityProvider);
        assertEq(share, 1000 ether);

        uint256 shareTrader = hook.getLiquidityShare(key, trader1);
        assertEq(shareTrader, 0);
    }

   
    function test_ClaimTokenBalances() public {
        vm.startPrank(liquidityProvider);
        
        uint256 liquidityAmount = 1000 ether;
        hook.addLiquidity(key, liquidityAmount);

        uint256 token0ClaimID = uint256(uint160(Currency.unwrap(currency0)));
        uint256 token1ClaimID = uint256(uint160(Currency.unwrap(currency1)));

        uint256 hookToken0Claims = manager.balanceOf(address(hook), token0ClaimID);
        uint256 hookToken1Claims = manager.balanceOf(address(hook), token1ClaimID);

        assertEq(hookToken0Claims, liquidityAmount);
        assertEq(hookToken1Claims, liquidityAmount);

        vm.stopPrank();
    }


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

        // ===== STEP 4: Trader 2 Swaps in opposite Direction =====
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
        
        // expected withdrawal must be proportional to current reserves
        (uint256 expectedAmount0, uint256 expectedAmount1) = hook.getWithdrawalAmounts(key, sharesToRemove);
        console.log("Expected withdrawal:", expectedAmount0 / 1e18, expectedAmount1 / 1e18);
        
        hook.removeLiquidity(key, sharesToRemove);
        
        // check LP1 got proportional share based on current reserves
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

    
    function test_LiquidityRemovalAfterSwaps() public {
      
        vm.prank(liquidityProvider);
        hook.addLiquidity(key, 1000 ether);
        
        vm.prank(liquidityProvider2);
        hook.addLiquidity(key, 1000 ether);

        
        (uint256 reserve0Before, uint256 reserve1Before) = hook.getReserves(key);
        assertEq(reserve0Before, 2000 ether);
        assertEq(reserve1Before, 2000 ether);

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

        (uint256 reserve0After, uint256 reserve1After) = hook.getReserves(key);
        assertEq(reserve0After, 2500 ether);
        assertEq(reserve1After, 1500 ether);

        vm.startPrank(liquidityProvider);
        uint256 lp1Shares = hook.balanceOf(key.toId(), liquidityProvider);
        uint256 lp1Balance0Before = currency0.balanceOf(liquidityProvider);
        uint256 lp1Balance1Before = currency1.balanceOf(liquidityProvider);
        
        hook.removeLiquidity(key, lp1Shares);
        
        uint256 received0 = currency0.balanceOf(liquidityProvider) - lp1Balance0Before;
        uint256 received1 = currency1.balanceOf(liquidityProvider) - lp1Balance1Before;
        
        assertEq(received0, 1250 ether); // 50% of 2500
        assertEq(received1, 750 ether);  // 50% of 1500
      
        console.log("LP1 deposited 1000/1000, received:", received0 / 1e18, received1 / 1e18);
        
        vm.stopPrank();
    }

 
    function test_RevertWhen_RemoveLiquidityWithZeroShares() public {
        vm.prank(liquidityProvider);
        hook.addLiquidity(key, 1000 ether);

        vm.startPrank(trader1); // trader1 has no shares
        vm.expectRevert(CSMM.InsufficientShares.selector);
        hook.removeLiquidity(key, 1 ether);
        vm.stopPrank();
    }

 
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

    function test_RemoveLiquidityImmediately() public {
        vm.startPrank(liquidityProvider);
        
        uint256 amount = 1000 ether;
        uint256 balance0Before = currency0.balanceOf(liquidityProvider);
        uint256 balance1Before = currency1.balanceOf(liquidityProvider);

        hook.addLiquidity(key, amount);
        hook.removeLiquidity(key, amount);

        // Should get back exactly what was put in bc no swaps occurred
        assertEq(currency0.balanceOf(liquidityProvider), balance0Before);
        assertEq(currency1.balanceOf(liquidityProvider), balance1Before);
        assertEq(hook.balanceOf(key.toId(), liquidityProvider), 0);
        assertEq(hook.totalSupply(key.toId()), 0);

        vm.stopPrank();
    }

   
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

    function test_WithdrawalCalculationsWithSwaps() public {
        vm.prank(liquidityProvider);
        hook.addLiquidity(key, 2000 ether);

        
        (uint256 amount0Before, uint256 amount1Before) = hook.getWithdrawalAmounts(key, 1000 ether);
        assertEq(amount0Before, 1000 ether);
        assertEq(amount1Before, 1000 ether);

   
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

        
        (uint256 amount0After, uint256 amount1After) = hook.getWithdrawalAmounts(key, 1000 ether);
        assertEq(amount0After, 1300 ether); // 50% of 2600
        assertEq(amount1After, 700 ether);  // 50% of 1400
        
        assertEq(amount0After + amount1After, 2000 ether);
    }

   
    function test_GetWithdrawalAmounts_ZeroLiquidity() public {
        
        (uint256 amount0, uint256 amount1) = hook.getWithdrawalAmounts(key, 100 ether);
        assertEq(amount0, 0);
        assertEq(amount1, 0);

        (uint256 reserve0, uint256 reserve1) = hook.getReserves(key);
        assertEq(reserve0, 0);
        assertEq(reserve1, 0);
    }
}