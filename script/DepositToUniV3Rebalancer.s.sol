// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../src/UniV3Rebalancer.sol";

contract DepositToUniV3Rebalancer is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        address _me = vm.envAddress("ME");
        require(_me != address(0));
        uint256 _amt = vm.envUint("AMT");
        require(_amt > 0);

        address _rebalancer = vm.envAddress("REBALANCER");
        UniV3Rebalancer rebalancer = UniV3Rebalancer(_rebalancer);

        rebalancer.deposit(_amt, _me);

        vm.stopBroadcast();

        console.log("Deposit successful");
    }
}
