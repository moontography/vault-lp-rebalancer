// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../src/UniV3Rebalancer.sol";

contract CollectFeesUniV3Rebalancer is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address _rebalancer = vm.envAddress("REBALANCER");
        UniV3Rebalancer rebalancer = UniV3Rebalancer(_rebalancer);

        rebalancer.protocolCollect();

        vm.stopBroadcast();

        console.log("Protocol fee collection successful");
    }
}
