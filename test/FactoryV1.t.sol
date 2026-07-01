// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {FactoryV1} from "../src/distributor/v1/FactoryV1.sol";
import {DistributorV1, DistributorConfig, Range} from "../src/distributor/v1/DistributorV1.sol";
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

        factory = new FactoryV1(owner);
    }

    function _approveAndFund(address distributorAddr) internal {
        distributionToken.mint(distributorAddr, 1_000 ether);

        vm.prank(address(factory));
        participationToken.approve(distributorAddr, type(uint256).max);
    }

    function _createDistributor(uint256 feeInv, address feeReceiver, uint256 participationAmount)
        internal
        returns (address)
    {
        vm.prank(owner);
        factory.setProtocolFeeInv(feeInv);
        vm.prank(owner);
        factory.setProtocolFeeReceiver(feeReceiver);

        uint256 nonce = vm.getNonce(address(factory));
        address distributorAddr = vm.computeCreateAddress(address(factory), nonce);
        _approveAndFund(distributorAddr);

        vm.prank(user);
        participationToken.approve(address(factory), participationAmount);

        DistributorConfig memory config = DistributorConfig({
            distributionToken: address(distributionToken),
            participationToken: address(participationToken),
            epochDuration: epochDuration,
            startTimestamp: startTimestamp,
            protocolFeeInv: 0,
            protocolFeeReceiver: address(0),
            minParticipation: 1 ether,
            claimDelaySeconds: claimDelaySeconds,
            allowFutureEpochParticipation: true,
            drainHook: Hook({contractAddress: address(drainHook), callData: ""}),
            emissionFunction: EmissionFunction({
                emissionContract: emission, curveConfig: abi.encode(FixedEmissionConfig({amount: 100 ether}))
            }),
            allowlistSigner: address(0),
            allowlistDeadline: 0
        });

        vm.prank(user);
        return factory.createDistributor(config, participationAmount, Range({from: 0, length: 1}));
    }

    function testInitialParticipation() public {
        address distributorAddr = _createDistributor(10, protocolFeeReceiver, 10 ether);
        DistributorV1 distributor = DistributorV1(distributorAddr);

        assertEq(distributor.epochUserParticipation(0, user), 10 ether);
        assertEq(distributor.epochTotalParticipation(0), 10 ether);
    }

    function testDynamicProtocolFeeUpdateFeeAndAddress() public {
        address distributorAddr1 = _createDistributor(20, address(0xAAAA), 10 ether);
        DistributorV1 distributor1 = DistributorV1(distributorAddr1);

        assertEq(distributor1.PROTOCOL_FEE_INV(), 20);
        assertEq(distributor1.PROTOCOL_FEE_RECEIVER(), address(0xAAAA));

        // this line updates factory settings
        address distributorAddr2 = _createDistributor(50, address(0xBBBB), 10 ether);
        DistributorV1 distributor2 = DistributorV1(distributorAddr2);

        assertEq(distributor1.PROTOCOL_FEE_INV(), 20);
        assertEq(distributor1.PROTOCOL_FEE_RECEIVER(), address(0xAAAA));

        assertEq(distributor2.PROTOCOL_FEE_INV(), 50);
        assertEq(distributor2.PROTOCOL_FEE_RECEIVER(), address(0xBBBB));
    }

    function testProtocolFeeDeductedOnClaim() public {
        uint256 feeInv = 4;
        uint256 participationAmount = 10 ether;

        address distributorAddr = _createDistributor(feeInv, protocolFeeReceiver, participationAmount);
        DistributorV1 distributor = DistributorV1(distributorAddr);

        uint256 feeBefore = participationToken.balanceOf(protocolFeeReceiver);

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);

        vm.prank(user);
        distributor.claim(Range({from: 0, length: 1}));

        uint256 feeAfter = participationToken.balanceOf(protocolFeeReceiver);
        assertEq(feeAfter - feeBefore, participationAmount / feeInv);
    }

    function testRevertNonOwnerUpdatesProtocolFeeInv() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        factory.setProtocolFeeInv(99);
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
