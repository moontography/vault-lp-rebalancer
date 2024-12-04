// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../src/UniV3Rebalancer.sol";
import "../src/interfaces/IUniswapV3Factory.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployUniV3Rebalancer is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        address _me = vm.addr(deployerPrivateKey);

        // Arbitrum WETH/USDC
        IUniswapV3Pool _pool = IUniswapV3Pool(0xC6962004f452bE9203591991D15f6b388e09E8D0);

        // Deploy UniV3Rebalancer
        UniV3Rebalancer rebalancer = new UniV3Rebalancer(
            "t1",
            "T1",
            IERC20(address(0)),
            address(_pool),
            0xE592427A0AEce92De3Edee1F18E0157C05861564, // SwapRouter
            5,
            _me
        );

        // Perform initial deposit (example values, adjust as needed)
        address token0 = _pool.token0(); // WETH
        address token1 = _pool.token1(); // USDC

        (uint128 _liquidity, , ) = rebalancer.getLiquidityAndRequiredAmountsFromToken(
            2 * 1e6,
            token1
        );

        // Approve tokens
        IERC20(token0).approve(address(rebalancer), type(uint256).max);
        IERC20(token1).approve(address(rebalancer), type(uint256).max);

        // Deposit
        rebalancer.deposit(_liquidity, _me);

        vm.stopBroadcast();

        console.log("UniV3Rebalancer deployed at:", address(rebalancer));
    }
}
