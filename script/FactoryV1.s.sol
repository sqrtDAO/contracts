// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {FactoryV1} from "../src/v1/FactoryV1.sol";
import {TransferToHook} from "../src/utils/hooks/TransferToHook.sol";
import {BuyAndBurnHookV3} from "../src/utils/hooks/BuyAndBurnHookV3.sol";
import {INonfungiblePositionManager} from "../src/external-interfaces/INonfungiblePositionManager.sol";
import {IPermit2} from "../src/external-interfaces/IPermit2.sol";

contract FactoryV1Script is Script {
    function run() external returns (FactoryV1 factory) {
        // --- config (override via env vars) ---
        address initialOwner = vm.envOr("INITIAL_OWNER", msg.sender);
        uint256 protocolFeeBps = vm.envOr("PROTOCOL_FEE_BPS", uint256(500)); // 5%
        address protocolFeeReceiver = vm.envOr("PROTOCOL_FEE_RECEIVER", msg.sender);

        // chain-specific external addresses (Uniswap V3 on the target chain)
        address positionManager = vm.envAddress("POSITION_MANAGER");
        address permit2 = vm.envAddress("PERMIT2");
        address swapRouter = vm.envAddress("SWAP_ROUTER");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        TransferToHook transferToHook = new TransferToHook();
        BuyAndBurnHookV3 buyAndBurnHook = new BuyAndBurnHookV3(swapRouter);

        factory = new FactoryV1(
            initialOwner,
            protocolFeeBps,
            protocolFeeReceiver,
            transferToHook,
            buyAndBurnHook,
            INonfungiblePositionManager(positionManager),
            IPermit2(permit2)
        );

        vm.stopBroadcast();
    }
}
