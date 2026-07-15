// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {FactoryV1} from "../src/v1/FactoryV1.sol";
import {INonfungiblePositionManager} from "../src/external-interfaces/INonfungiblePositionManager.sol";
import {DistributorV1, DistributorConfig, Range} from "../src/v1/DistributorV1.sol";
import {FixedEmission, FixedEmissionConfig} from "../src/utils/emission-function/FixedEmission.sol";
import {EmissionFunction} from "../src/utils/emission-function/EmissionFunction.sol";
import {Hook} from "src/utils/Hook.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract FactoryV1Test is Test {
    FactoryV1 public factory;
    ERC20Mock public distributionToken;
    ERC20Mock public participationToken;
    FixedEmission public emission;
    DummyHook public drainHook;

    address public owner = address(0xCAFE);
    address public protocolFeeReceiver = address(0xBEEF);
    address public user = address(0x1234);

    uint256 public epochDuration = 100;
    uint256 public claimDelaySeconds = 10;
    uint256 public startTimestamp = 1_000;

    function setUp() public {
        vm.warp(startTimestamp);

        distributionToken = new ERC20Mock();
        participationToken = new ERC20Mock();
        emission = new FixedEmission();
        drainHook = new DummyHook();

        distributionToken.mint(address(this), 1_000 ether);
        participationToken.mint(user, 1_000 ether);

        factory = new FactoryV1(owner, 0, protocolFeeReceiver, INonfungiblePositionManager(address(0x1)));
    }

    function _createDistributor(uint256 feeBps, address feeReceiver, uint256 participationAmount)
        internal
        returns (address)
    {
        vm.prank(owner);
        factory.setProtocolFeeBps(feeBps);
        vm.prank(owner);
        factory.setProtocolFeeReceiver(feeReceiver);

        DistributorConfig memory config = DistributorConfig({
            distributionToken: address(distributionToken),
            participationToken: address(participationToken),
            epochDuration: epochDuration,
            startTimestamp: startTimestamp,
            minParticipation: 1 ether,
            claimDelaySeconds: claimDelaySeconds,
            allowFutureEpochParticipation: true,
            drainHook: Hook({contractAddress: address(drainHook), callData: ""}),
            emissionFunction: EmissionFunction({
                emissionContract: emission, curveConfig: abi.encode(FixedEmissionConfig({amount: 100 ether}))
            }),
            allowlistSigner: address(0),
            allowlistDeadline: 0,
            numberOfEpochs: 100,
            totalDistributionAmount: 100 ether
        });

        vm.prank(user);
        participationToken.approve(address(factory), participationAmount);

        distributionToken.mint(user, 1_000 ether);
        vm.prank(user);
        distributionToken.approve(address(factory), type(uint256).max);

        vm.prank(user);
        return factory.createDistributor(config);
    }

    function testDynamicProtocolFeeUpdateFeeAndAddress() public {
        address distributorAddr1 = _createDistributor(20, address(0xAAAA), 10 ether);
        DistributorV1 distributor1 = DistributorV1(distributorAddr1);

        assertEq(distributor1.PROTOCOL_FEE_BPS(), 20);
        assertEq(distributor1.PROTOCOL_FEE_RECEIVER(), address(0xAAAA));

        // this line updates factory settings
        address distributorAddr2 = _createDistributor(50, address(0xBBBB), 10 ether);
        DistributorV1 distributor2 = DistributorV1(distributorAddr2);

        assertEq(distributor1.PROTOCOL_FEE_BPS(), 20);
        assertEq(distributor1.PROTOCOL_FEE_RECEIVER(), address(0xAAAA));

        assertEq(distributor2.PROTOCOL_FEE_BPS(), 50);
        assertEq(distributor2.PROTOCOL_FEE_RECEIVER(), address(0xBBBB));
    }

    function testRevertNonOwnerUpdatesProtocolFeeBps() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        factory.setProtocolFeeBps(99);
    }

    function testRevertNonOwnerUpdatesProtocolFeeReceiver() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        factory.setProtocolFeeReceiver(address(0xDEAD));
    }
}

contract DummyHook {
    bool public called;

    fallback(bytes calldata) external returns (bytes memory) {
        called = true;
        return "";
    }
}
