// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {FactoryV1} from "../src/v1/FactoryV1.sol";
import {TokenV1Factory} from "../src/v1/TokenV1Factory.sol";
import {DistributionV1Factory} from "../src/v1/DistributionV1Factory.sol";
import {DistributorV1, DistributorConfig} from "../src/v1/DistributorV1.sol";
import {TransferToHook} from "../src/utils/hooks/TransferToHook.sol";
import {BuyAndBurnHookV3} from "../src/utils/hooks/BuyAndBurnHookV3.sol";
import {INonfungiblePositionManager} from "../src/external-interfaces/INonfungiblePositionManager.sol";
import {IPermit2} from "../src/external-interfaces/IPermit2.sol";
import {FixedEmission, FixedEmissionConfig} from "../src/utils/emission-function/FixedEmission.sol";
import {LinearEmission} from "../src/utils/emission-function/LinearEmission.sol";
import {ExponentialEmission} from "../src/utils/emission-function/ExponentialEmission.sol";
import {EmissionFunction} from "../src/utils/emission-function/EmissionFunction.sol";
import {Share} from "../src/utils/Shares.sol";
import {Hook} from "../src/utils/Hook.sol";

contract FactoryV1Script is Script {
    function run() external returns (FactoryV1 factory) {
        // --- config (override via env vars) ---
        address initialOwner = vm.envOr("INITIAL_OWNER", msg.sender);
        uint256 protocolFeeBps = vm.envOr("PROTOCOL_FEE_BPS", uint256(500)); // 5%

        // chain-specific external addresses (Uniswap V3 on the target chain)
        address positionManager = vm.envAddress("POSITION_MANAGER");
        address permit2 = vm.envAddress("PERMIT2");
        address swapRouter = vm.envAddress("SWAP_ROUTER");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        // EmissionFunctions
        FixedEmission fixedEmission = new FixedEmission();
        LinearEmission linearEmission = new LinearEmission();
        ExponentialEmission exponentialEmission = new ExponentialEmission();

        // sample DistributorV1 deployment so it gets verified on etherscan with `--verify`
        // (all instances share identical bytecode, so instances created later by
        // DistributionV1Factory are auto-verified against this one)
        Share[] memory sampleShares = new Share[](1);
        sampleShares[0] = Share({shareBps: 10000, hook: Hook({contractAddress: address(0), callData: ""})});
        DistributorV1 sampleDistributor = new DistributorV1(
            initialOwner,
            DistributorConfig({
                distributionToken: address(1),
                participationToken: address(1),
                epochDuration: 1,
                startTimestamp: block.timestamp,
                minParticipation: 0,
                claimDelaySeconds: 0,
                allowFutureEpochParticipation: true,
                shares: sampleShares,
                emissionFunction: EmissionFunction({
                    emissionContract: fixedEmission, curveConfig: abi.encode(FixedEmissionConfig({amount: 1}))
                }),
                allowlistSigner: address(0),
                allowlistDeadline: 0,
                numberOfEpochs: 1,
                totalDistributionAmount: 1
            })
        );

        // Hooks
        TransferToHook transferToHook = new TransferToHook();
        BuyAndBurnHookV3 buyAndBurnHook = new BuyAndBurnHookV3(swapRouter);

        // Child deployers
        TokenV1Factory tokenFactory = new TokenV1Factory();
        DistributionV1Factory distributorFactory = new DistributionV1Factory();

        factory = new FactoryV1(
            initialOwner,
            protocolFeeBps,
            transferToHook,
            buyAndBurnHook,
            INonfungiblePositionManager(positionManager),
            IPermit2(permit2),
            tokenFactory,
            distributorFactory
        );

        console.log("fixedEmission", address(fixedEmission));
        console.log("linearEmission", address(linearEmission));
        console.log("exponentialEmission", address(exponentialEmission));
        console.log("sampleDistributor", address(sampleDistributor));
        console.log("transferToHook", address(transferToHook));
        console.log("buyAndBurnHook", address(buyAndBurnHook));
        console.log("tokenFactory", address(tokenFactory));
        console.log("distributorFactory", address(distributorFactory));
        console.log("factoryV1", address(factory));

        vm.stopBroadcast();
    }
}
