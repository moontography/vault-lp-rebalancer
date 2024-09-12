// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../src/UniV3Rebalancer.sol";
import "@uniswap/v3-core/contracts/libraries/FixedPoint96.sol";

contract GetUniV3RebalancerInfo is Script {
    function run() external view {
        address _rebalancer = vm.envAddress("REBALANCER");
        UniV3Rebalancer rebalancer = UniV3Rebalancer(_rebalancer);
        (bool _shouldRebalance, ) = rebalancer.checkUpkeep("");

        IUniswapV3Pool _pool = IUniswapV3Pool(rebalancer.POOL());
        IERC20Metadata _token0 = IERC20Metadata(_pool.token0());
        // IERC20Metadata _token1 = IERC20Metadata(_pool.token1());
        (uint160 _sqrtPriceX96, , , , , , ) = _pool.slot0();
        uint256 _priceX96 = FullMath.mulDiv(_sqrtPriceX96, _sqrtPriceX96, FixedPoint96.Q96);

        (, , , uint160 _sqrtPriceAX96, uint160 _sqrtPriceBX96) = rebalancer.currentPosition();
        uint256 _priceAX96 = FullMath.mulDiv(_sqrtPriceAX96, _sqrtPriceAX96, FixedPoint96.Q96);
        uint256 _priceBX96 = FullMath.mulDiv(_sqrtPriceBX96, _sqrtPriceBX96, FixedPoint96.Q96);

        console.log("UniV3Rebalancer", address(rebalancer));
        console.log(
            "Current & Upper/Lower Tick Prices",
            (_priceX96 * 10 ** _token0.decimals()) / FixedPoint96.Q96,
            (_priceAX96 * 10 ** _token0.decimals()) / FixedPoint96.Q96,
            (_priceBX96 * 10 ** _token0.decimals()) / FixedPoint96.Q96
        );
        console.log("Total Shares", rebalancer.totalSupply());
        console.log("Total Liquidity", rebalancer.totalAssets());
        console.log("totalToken0Assets", rebalancer.totalToken0Assets());
        console.log("totalToken1Assets", rebalancer.totalToken1Assets());
        console.log(
            "totalAssetsUSDC",
            rebalancer.totalToken1Assets() +
                (_priceX96 * rebalancer.totalToken0Assets()) /
                FixedPoint96.Q96
        );
        console.log("checkUpkeep", _shouldRebalance);
    }
}
