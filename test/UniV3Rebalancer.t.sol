// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/UniV3Rebalancer.sol";
import "../src/interfaces/IUniswapV3Factory.sol";
import "../src/interfaces/IUniswapV3Pool.sol";

contract UniV3RebalancerTest is Test {
    UniV3Rebalancer public rebalancer;
    IERC20 public token0;
    IERC20 public token1;
    IUniswapV3Pool public pool;
    ISwapRouter public swapRouter;

    uint256 public constant REBALANCE_PERCENTAGE = 50; // 5% range

    function setUp() public {
        // Arbitrum One
        pool = IUniswapV3Pool(0xC6962004f452bE9203591991D15f6b388e09E8D0);
        swapRouter = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
        token0 = IERC20(pool.token0());
        token1 = IERC20(pool.token1());

        // Deploy rebalancer
        rebalancer = new UniV3Rebalancer(
            "Test",
            "T",
            IERC20(address(0)),
            address(pool),
            address(swapRouter),
            REBALANCE_PERCENTAGE,
            address(this)
        );

        // Mint tokens to the MockSwapRouter
        deal(address(token0), address(this), 100e18);
        deal(address(token1), address(this), 100e18);
    }

    function testInitialDeposit() public {
        (uint256 depositAmount0, uint256 depositAmount1) = _seed();

        (uint160 _sqrtPriceX96, int24 _currentTick, , , , , ) = pool.slot0();
        (int24 _lt, int24 _ut) = rebalancer.calculateTicks(_currentTick);
        uint128 _liquidity = LiquidityAmounts.getLiquidityForAmounts(
            _sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(_lt),
            TickMath.getSqrtRatioAtTick(_ut),
            depositAmount0,
            depositAmount1
        );

        // Perform the initial deposit
        uint256 sharesMinted = rebalancer.deposit(_liquidity, address(this));

        // Check that shares were minted
        assertEq(
            rebalancer.balanceOf(address(this)),
            sharesMinted,
            "Incorrect number of shares minted"
        );

        // Check that the total supply of shares equals the minted shares
        assertEq(rebalancer.totalSupply(), sharesMinted, "Total supply should equal minted shares");

        // Check that the rebalancer's asset balance is zero (all assets should be in the pool)
        assertEq(
            token0.balanceOf(address(rebalancer)),
            0,
            "Rebalancer should have transferred all assets to the pool"
        );

        // Check that the total assets in the rebalancer match the deposit
        assertApproxEqRel(
            rebalancer.totalAssets(),
            _liquidity,
            0.01e18, // 1% tolerance due to potential slippage
            "Total assets should approximately match the initial deposit"
        );
    }

    function testSubsequentDeposits() public {
        uint256 initialDeposit0 = 10 * 10 ** IERC20Metadata(address(token0)).decimals();
        uint256 initialDeposit1 = 10 * 10 ** IERC20Metadata(address(token1)).decimals();
        uint256 subsequentDeposit0 = 5 * 10 ** IERC20Metadata(address(token0)).decimals();
        uint256 subsequentDeposit1 = 5 * 10 ** IERC20Metadata(address(token1)).decimals();

        // Mint some tokens for the test contract
        deal(address(token0), address(this), initialDeposit0 + subsequentDeposit0);
        deal(address(token1), address(this), initialDeposit1 + subsequentDeposit1);

        // Approve tokens for rebalancer
        token0.approve(address(rebalancer), initialDeposit0 + subsequentDeposit0);
        token1.approve(address(rebalancer), initialDeposit1 + subsequentDeposit1);

        (uint160 _sqrtPriceX96, int24 _currentTick, , , , , ) = pool.slot0();
        (int24 _lt, int24 _ut) = rebalancer.calculateTicks(_currentTick);
        uint128 _liquidityInitial = LiquidityAmounts.getLiquidityForAmounts(
            _sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(_lt),
            TickMath.getSqrtRatioAtTick(_ut),
            initialDeposit0,
            initialDeposit1
        );

        // Perform the initial deposit
        uint256 initialShares = rebalancer.deposit(_liquidityInitial, address(this));

        uint256 totalAssetsBeforeSubsequent = rebalancer.totalAssets();

        uint128 _liquiditySubsequent = LiquidityAmounts.getLiquidityForAmounts(
            _sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(_lt),
            TickMath.getSqrtRatioAtTick(_ut),
            subsequentDeposit0,
            subsequentDeposit1
        );

        // Perform a subsequent deposit
        uint256 subsequentShares = rebalancer.deposit(_liquiditySubsequent, address(this));

        // Calculate expected shares for the subsequent deposit
        uint256 expectedSubsequentShares = (_liquiditySubsequent * initialShares) /
            totalAssetsBeforeSubsequent;

        // Check that the correct number of shares were minted for the subsequent deposit
        assertApproxEqRel(
            subsequentShares,
            expectedSubsequentShares,
            0.01e18, // 1% tolerance due to potential slippage
            "Incorrect number of shares minted for subsequent deposit"
        );

        // Check that the total supply of shares equals the sum of initial and subsequent shares
        assertEq(
            rebalancer.totalSupply(),
            initialShares + subsequentShares,
            "Total supply should equal sum of all minted shares"
        );

        // Check that the rebalancer's asset balance is zero (all assets should be in the pool)
        assertEq(
            token0.balanceOf(address(rebalancer)),
            0,
            "Rebalancer should have transferred all assets to the pool"
        );
    }

    function testWithdraw() public {
        (uint256 initialDeposit0, uint256 initialDeposit1) = _seed();

        (uint160 _sqrtPriceX96, int24 _currentTick, , , , , ) = pool.slot0();
        (int24 _lt, int24 _ut) = rebalancer.calculateTicks(_currentTick);
        uint128 _liquidity = LiquidityAmounts.getLiquidityForAmounts(
            _sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(_lt),
            TickMath.getSqrtRatioAtTick(_ut),
            initialDeposit0,
            initialDeposit1
        );

        // Perform the initial deposit
        uint256 sharesMinted = rebalancer.deposit(_liquidity, address(this));

        // Calculate expected shares to burn
        uint256 totalAssets = rebalancer.totalAssets();
        uint256 withdrawAmount = (totalAssets * 4) / 10;

        (uint256 _amount0ThatShouldBeWithdrawn, ) = LiquidityAmounts.getAmountsForLiquidity(
            _sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(_lt),
            TickMath.getSqrtRatioAtTick(_ut),
            uint128(withdrawAmount)
        );

        // Perform withdrawal
        uint256 initialBalance = token0.balanceOf(address(this));
        uint256 sharesBurned = rebalancer.withdraw(withdrawAmount, address(this), address(this));

        // Check that the correct number of shares were burned
        assertEq(
            sharesBurned,
            (withdrawAmount * sharesMinted) / totalAssets,
            "Incorrect number of shares burned"
        );

        // Check that the user's balance increased by approximately the withdrawal amount
        assertApproxEqRel(
            token0.balanceOf(address(this)) - initialBalance,
            (_amount0ThatShouldBeWithdrawn * 99) / 100, // account for protocol fee
            0.01e18, // 1% tolerance due to potential slippage
            "User should have received approximately the withdrawn assets"
        );

        // Check that the total supply of shares decreased correctly
        assertEq(
            rebalancer.totalSupply(),
            sharesMinted - sharesBurned,
            "Total supply should have decreased by the burned shares"
        );

        // // Check that the rebalancer's asset balance is zero (all assets should be in the pool)
        // assertApproxEqRel(
        //     token0.balanceOf(address(rebalancer)),
        //     1,
        //     0.01e18,
        //     "Rebalancer should have transferred all assets to the pool"
        // );

        // Check that the total assets in the rebalancer decreased correctly
        assertApproxEqRel(
            rebalancer.totalAssets(),
            totalAssets - withdrawAmount,
            0.01e18, // 1% tolerance due to potential slippage
            "Total assets should have decreased by approximately the withdrawn amount"
        );
    }

    function testConvertToShares() public {
        (uint256 initialDeposit0, uint256 initialDeposit1) = _seed();

        (uint160 _sqrtPriceX96, int24 _currentTick, , , , , ) = pool.slot0();
        (int24 _lt, int24 _ut) = rebalancer.calculateTicks(_currentTick);
        uint128 _liquidity = LiquidityAmounts.getLiquidityForAmounts(
            _sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(_lt),
            TickMath.getSqrtRatioAtTick(_ut),
            initialDeposit0,
            initialDeposit1
        );

        // Perform the initial deposit
        uint256 initialShares = rebalancer.deposit(_liquidity, address(this));

        // Test conversion when totalSupply > 0
        uint256 testAmount = 5e17;
        uint256 expectedShares = (testAmount * initialShares) / _liquidity;
        assertApproxEqRel(
            rebalancer.convertToShares(testAmount),
            expectedShares,
            0.01e18, // 1% tolerance due to potential slippage
            "Incorrect share conversion when totalSupply > 0"
        );

        // Test conversion when totalSupply = 0
        vm.prank(address(this));
        rebalancer.withdraw(rebalancer.totalAssets(), address(this), address(this));
        assertEq(
            rebalancer.convertToShares(testAmount),
            testAmount,
            "Incorrect share conversion when totalSupply = 0"
        );
    }

    function testConvertToAssets() public {
        (uint256 initialDeposit0, uint256 initialDeposit1) = _seed();

        (uint160 _sqrtPriceX96, int24 _currentTick, , , , , ) = pool.slot0();
        (int24 _lt, int24 _ut) = rebalancer.calculateTicks(_currentTick);
        uint128 _liquidity = LiquidityAmounts.getLiquidityForAmounts(
            _sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(_lt),
            TickMath.getSqrtRatioAtTick(_ut),
            initialDeposit0,
            initialDeposit1
        );

        // Perform the initial deposit
        uint256 initialShares = rebalancer.deposit(_liquidity, address(this));

        // Test conversion when totalSupply > 0
        uint256 testShares = initialShares / 2;
        uint256 expectedAssets = (testShares * _liquidity) / initialShares;
        assertApproxEqRel(
            rebalancer.convertToAssets(testShares),
            expectedAssets,
            0.01e18, // 1% tolerance due to potential slippage
            "Incorrect asset conversion when totalSupply > 0"
        );

        // Test conversion when totalSupply = 0
        vm.prank(address(this));
        rebalancer.withdraw(rebalancer.totalAssets(), address(this), address(this));
        assertEq(
            rebalancer.convertToAssets(testShares),
            testShares,
            "Incorrect asset conversion when totalSupply = 0"
        );
    }

    function testCheckUpkeep() public {
        (uint256 initialDeposit0, uint256 initialDeposit1) = _seed();

        (uint160 _sqrtPriceX96, int24 _currentTick, , , , , ) = pool.slot0();
        (int24 _lt, int24 _ut) = rebalancer.calculateTicks(_currentTick);
        uint128 _liquidity = LiquidityAmounts.getLiquidityForAmounts(
            _sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(_lt),
            TickMath.getSqrtRatioAtTick(_ut),
            initialDeposit0,
            initialDeposit1
        );

        rebalancer.deposit(_liquidity, address(this));

        // Check initial state
        (bool needsUpkeep, ) = rebalancer.checkUpkeep("");
        assertFalse(needsUpkeep, "Should not need upkeep initially");

        // Execute price movement
        uint256 _swapAmt = token0.balanceOf(address(pool));
        deal(address(token0), address(this), _swapAmt);
        _swapTokens(_swapAmt, true);

        // Wait for the minimum rebalance frequency
        skip(10 minutes + 1);

        (needsUpkeep, ) = rebalancer.checkUpkeep("");
        assertTrue(needsUpkeep, "Should need upkeep after price movement");
    }

    function testPerformUpkeep() public {
        (uint256 initialDeposit0, uint256 initialDeposit1) = _seed();

        (uint160 _sqrtPriceX96, int24 _currentTick, , , , , ) = pool.slot0();
        (int24 _lt, int24 _ut) = rebalancer.calculateTicks(_currentTick);
        uint128 _depositLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            _sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(_lt),
            TickMath.getSqrtRatioAtTick(_ut),
            initialDeposit0,
            initialDeposit1
        );
        rebalancer.deposit(_depositLiquidity, address(this));

        // Execute price movement
        uint256 _swapAmt = token0.balanceOf(address(pool));
        deal(address(token0), address(this), _swapAmt);
        _swapTokens(_swapAmt, true);

        // Wait for the minimum rebalance frequency
        skip(10 minutes + 1);

        // Perform upkeep
        (bool needsUpkeep, bytes memory performData) = rebalancer.checkUpkeep("");
        assertTrue(needsUpkeep, "Should need upkeep before performing it");
        rebalancer.performUpkeep(performData);

        (, int24 _lowerTick, int24 _upperTick, , ) = rebalancer.currentPosition();

        // Check if position changed
        (uint128 _liquidityAfter, , , , ) = pool.positions(
            keccak256(abi.encodePacked(address(rebalancer), _lowerTick, _upperTick))
        );

        assertTrue(_liquidityAfter > 0, "Liquidity should be added after performUpkeep");
    }

    function testDepositFromToken() public {
        (uint256 initialDeposit0, ) = _seed();

        uint256 initialShares = rebalancer.totalSupply();
        (uint128 liquidity, uint256 shares) = rebalancer.depositFromToken(initialDeposit0, token0);

        assertTrue(liquidity > 0, "Liquidity should be added after deposit");
        assertTrue(shares > 0, "Shares should be minted after deposit");
        assertGt(
            rebalancer.totalSupply(),
            initialShares,
            "Total supply should increase after deposit"
        );
    }

    function testGetLiquidityAndRequiredAmountsFromToken() public {
        (uint256 initialDeposit0, uint256 initialDeposit1) = _seed();

        // Test with token0
        (uint128 liquidity0, , uint256 amount1) = rebalancer
            .getLiquidityAndRequiredAmountsFromToken(initialDeposit0, address(token0));

        assertTrue(liquidity0 > 0, "Liquidity for token0 should be greater than 0");
        assertTrue(amount1 > 0, "Amount1 should be greater than 0");
        // assertEq(amount0, initialDeposit0, "Amount0 should equal the initial deposit");

        // Test with token1
        (uint128 liquidity1, uint256 amount0ForToken1, ) = rebalancer
            .getLiquidityAndRequiredAmountsFromToken(initialDeposit1, address(token1));

        assertTrue(liquidity1 > 0, "Liquidity for token1 should be greater than 0");
        assertTrue(amount0ForToken1 > 0, "Amount0 for token1 deposit should be greater than 0");
        // assertEq(
        //     amount1ForToken1,
        //     initialDeposit1,
        //     "Amount1 for token1 deposit should equal the initial deposit"
        // );

        // Verify that liquidity is calculated correctly
        (, int24 currentTick, , , , , ) = pool.slot0();
        (int24 lowerTick, int24 upperTick) = rebalancer.calculateTicks(currentTick);

        uint128 expectedLiquidity0 = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtRatioAtTick(lowerTick),
            TickMath.getSqrtRatioAtTick(upperTick),
            initialDeposit0
        );

        uint128 expectedLiquidity1 = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtRatioAtTick(lowerTick),
            TickMath.getSqrtRatioAtTick(upperTick),
            initialDeposit1
        );

        assertEq(
            liquidity0,
            expectedLiquidity0,
            "Calculated liquidity for token0 should match expected value"
        );
        assertEq(
            liquidity1,
            expectedLiquidity1,
            "Calculated liquidity for token1 should match expected value"
        );

        // // Verify that the amounts are consistent
        // (uint256 verifyAmount0, uint256 verifyAmount1) = LiquidityAmounts.getAmountsForLiquidity(
        //     sqrtPriceX96,
        //     TickMath.getSqrtRatioAtTick(lowerTick),
        //     TickMath.getSqrtRatioAtTick(upperTick),
        //     liquidity0
        // );

        // assertApproxEqRel(
        //     verifyAmount0,
        //     amount0,
        //     0.001e18,
        //     "Verified amount0 should be close to calculated amount0"
        // );
        // assertApproxEqRel(
        //     verifyAmount1,
        //     amount1,
        //     0.001e18,
        //     "Verified amount1 should be close to calculated amount1"
        // );
    }

    function _seed() internal returns (uint256 initialDeposit0, uint256 initialDeposit1) {
        initialDeposit0 = 10 * 10 ** IERC20Metadata(address(token0)).decimals();
        initialDeposit1 = 10 * 10 ** IERC20Metadata(address(token1)).decimals();

        // Mint some tokens for the test contract
        deal(address(token0), address(this), initialDeposit0);
        deal(address(token1), address(this), initialDeposit1);

        // Approve tokens for rebalancer
        token0.approve(address(rebalancer), initialDeposit0);
        token1.approve(address(rebalancer), initialDeposit1);
    }

    function _swapTokens(uint256 _amountIn, bool _zeroForOne) internal {
        IERC20 tokenIn = _zeroForOne ? token0 : token1;
        IERC20 tokenOut = _zeroForOne ? token1 : token0;

        tokenIn.approve(address(swapRouter), _amountIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            fee: pool.fee(),
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: _amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        swapRouter.exactInputSingle(params);
    }
}
