// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {FactoryV1} from "../src/v1/FactoryV1.sol";
import {TokenV1Factory} from "../src/v1/TokenV1Factory.sol";
import {DistributionV1Factory} from "../src/v1/DistributionV1Factory.sol";
import {INonfungiblePositionManager} from "../src/external-interfaces/INonfungiblePositionManager.sol";
import {IPermit2} from "../src/external-interfaces/IPermit2.sol";
import {DistributorV1, DistributorConfig} from "../src/v1/DistributorV1.sol";
import {FixedEmission, FixedEmissionConfig} from "../src/utils/emission-function/FixedEmission.sol";
import {EmissionFunction} from "../src/utils/emission-function/EmissionFunction.sol";
import {Share} from "src/utils/Shares.sol";
import {Hook} from "src/utils/Hook.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {TransferToHook} from "src/utils/hooks/TransferToHook.sol";
import {BuyAndBurnHookV3} from "src/utils/hooks/BuyAndBurnHookV3.sol";

contract FactoryV1Test is Test {
    FactoryV1 public factory;
    ERC20Mock public distributionToken;
    ERC20Mock public participationToken;
    FixedEmission public emission;

    address public owner = address(0xCAFE);
    address public user = address(0x1234);

    uint256 public epochDuration = 100;
    uint256 public claimDelaySeconds = 10;
    uint256 public startTimestamp = 1_000;

    function setUp() public {
        vm.warp(startTimestamp);

        distributionToken = new ERC20Mock();
        participationToken = new ERC20Mock();
        emission = new FixedEmission();

        distributionToken.mint(address(this), 1_000 ether);
        participationToken.mint(user, 1_000 ether);

        factory = new FactoryV1(
            owner,
            0,
            new TransferToHook(),
            new BuyAndBurnHookV3(address(0x0)),
            INonfungiblePositionManager(address(0x1)),
            IPermit2(address(0x2)),
            new TokenV1Factory(),
            new DistributionV1Factory()
        );
    }

    function _createDistributor(uint256 feeBps, uint256 participationAmount) internal returns (address) {
        vm.prank(owner);
        factory.setProtocolFeeBps(feeBps);

        // user shares must sum to (10000 - feeBps) — factory injects the protocol fee share
        Share[] memory shares = new Share[](1);
        shares[0] = Share({shareBps: 10000 - feeBps, hook: Hook({contractAddress: address(0), callData: ""})});

        DistributorConfig memory config = DistributorConfig({
            distributionToken: address(distributionToken),
            participationToken: address(participationToken),
            epochDuration: epochDuration,
            startTimestamp: startTimestamp,
            minParticipation: 1 ether,
            claimDelaySeconds: claimDelaySeconds,
            allowFutureEpochParticipation: true,
            emissionFunction: EmissionFunction({
                emissionContract: emission, curveConfig: abi.encode(FixedEmissionConfig({amount: 100 ether}))
            }),
            shares: shares,
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
        return factory.createDistributor(config, true);
    }

    function testDynamicProtocolFeeUpdateFeeAndAddress() public {
        address distributorAddr1 = _createDistributor(20, 10 ether);
        DistributorV1 distributor1 = DistributorV1(distributorAddr1);

        // Protocol fee share is the last injected share (index 1)
        (uint256 bps1, Hook memory hook1) = distributor1.shares(1);
        assertEq(bps1, 20);
        assertEq(hook1.contractAddress, address(factory.TRANSFER_TO_HOOK()));

        // Total shares = 2 (user share + protocol fee)
        (uint256 userBps,) = distributor1.shares(0);
        assertEq(userBps, 9980);

        // this line updates factory settings
        address distributorAddr2 = _createDistributor(50, 10 ether);
        DistributorV1 distributor2 = DistributorV1(distributorAddr2);

        // First distributor unchanged
        (userBps,) = distributor1.shares(0);
        assertEq(userBps, 9980);
        (bps1,) = distributor1.shares(1);
        assertEq(bps1, 20);

        // Second distributor has updated fee
        (uint256 bps2, Hook memory hook2) = distributor2.shares(1);
        (userBps,) = distributor2.shares(0);
        assertEq(userBps, 9950);
        assertEq(bps2, 50);
        assertEq(hook2.contractAddress, address(factory.TRANSFER_TO_HOOK()));
    }

    function testRevertNonOwnerUpdatesProtocolFeeBps() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        factory.setProtocolFeeBps(99);
    }

    function testDrainTokens() public {
        // mint some tokens to factory
        ERC20Mock token = new ERC20Mock();
        token.mint(address(factory), 500 ether);

        address recipient = address(0xFACE);
        vm.prank(owner);
        factory.drain(address(token), recipient);

        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(recipient), 500 ether);
    }

    function testRevertDrainNonOwner() public {
        ERC20Mock token = new ERC20Mock();
        token.mint(address(factory), 500 ether);

        vm.prank(address(0xDEAD));
        vm.expectRevert();
        factory.drain(address(token), address(0xDEAD));
    }
}
