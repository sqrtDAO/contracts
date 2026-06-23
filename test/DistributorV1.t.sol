// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {DistributorV1, Range, GetInfoResult} from "../src/distributor/v1/DistributorV1.sol";
import {FixedEmission, FixedEmissionConfig} from "../src/utils/emission-function/FixedEmission.sol";
import {EmissionFunction} from "../src/utils/emission-function/EmissionFunction.sol";
import {Hook} from "src/utils/Hook.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract DistributorV1Test is Test {
    DistributorV1 public distributor;
    ERC20Mock public distributionToken;
    ERC20Mock public participationToken;
    FixedEmission public emission;
    DummyHook public drainHook;

    address public protocolFeeReceiver = address(0xBEEF);
    address public participant = address(0x1234);

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
        participationToken.mint(participant, 1_000 ether);

        distributionToken.transfer(address(this), 0); // no-op to keep balances consistent

        distributor = new DistributorV1(
            address(distributionToken),
            address(participationToken),
            epochDuration,
            startTimestamp,
            10,
            protocolFeeReceiver,
            1 ether,
            claimDelaySeconds,
            Hook({contractAddress: address(drainHook), callData: ""}),
            EmissionFunction({
                emissionContract: emission, curveConfig: abi.encode(FixedEmissionConfig({amount: 100 ether}))
            })
        );

        distributionToken.transfer(address(distributor), 1_000 ether);
    }

    function testParticipateAndClaimAfterDelay() public {
        vm.prank(participant);
        participationToken.approve(address(distributor), 100 ether);

        vm.prank(participant);
        distributor.participate(10 ether, 2);

        assertEq(distributor.epochTotalParticipation(0), 10 ether);
        assertEq(distributor.epochUserParticipation(0, participant), 10 ether);
        assertEq(distributor.epochUserParticipation(1, participant), 10 ether);

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);

        vm.prank(participant);
        uint256 claimed = distributor.claim(Range({from: 0, length: 1}));

        assertEq(claimed, 100 ether);
        assertEq(distributionToken.balanceOf(participant), 100 ether);
        assertEq(distributor.epochUserParticipation(0, participant), 0);
    }

    function testClaimRevertsUntilDelayExpires() public {
        vm.prank(participant);
        participationToken.approve(address(distributor), 10 ether);

        vm.prank(participant);
        distributor.participate(10 ether, 1);

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds - 1);
        vm.expectRevert(bytes("Too soon to claim"));
        distributor.claim(Range({from: 0, length: 1}));
    }

    function testClaimTriggersDrainHookAfterEpoch() public {
        vm.prank(participant);
        participationToken.approve(address(distributor), 10 ether);

        vm.prank(participant);
        distributor.participate(10 ether, 1);

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);

        assertFalse(drainHook.called());

        vm.prank(participant);
        uint256 claimed = distributor.claim(Range({from: 0, length: 1}));

        assertEq(claimed, 100 ether);
        assertTrue(drainHook.called());
        assertEq(distributor.nextDrainHookToCall(), 1);
    }

    function testGetInfoReturnsClaimDelaySeconds() public {
        GetInfoResult memory info = distributor.getInfo(address(0), Range({from: 0, length: 0}));

        assertEq(info.claimDelaySeconds, claimDelaySeconds);
        assertEq(info.distributionToken, address(distributionToken));
        assertEq(info.participationToken, address(participationToken));
        assertEq(info.epochDuration, epochDuration);
        assertEq(info.startingTimestamp, startTimestamp);
    }

    function testGetInfoWithRangeReturnsParticipationData() public {
        vm.prank(participant);
        participationToken.approve(address(distributor), 20 ether);

        vm.prank(participant);
        distributor.participate(10 ether, 2);

        GetInfoResult memory info = distributor.getInfo(participant, Range({from: 0, length: 2}));

        assertEq(info.epochs.length, 2);
        assertEq(info.epochs[0].userParticipationAmount, 10 ether);
        assertEq(info.epochs[0].totalParticipationAmount, 10 ether);
        assertEq(info.epochs[0].rewardAmount, 100 ether);
        assertEq(info.epochs[1].userParticipationAmount, 10 ether);
        assertEq(info.epochs[1].totalParticipationAmount, 10 ether);
        assertEq(info.epochs[1].rewardAmount, 100 ether);
    }

    function testDiscoverRewardsReturnsParticipatedEpochs() public {
        vm.prank(participant);
        participationToken.approve(address(distributor), 30 ether);

        vm.prank(participant);
        distributor.participate(10 ether, 3);

        (uint256 nextEpoch, uint256[] memory epochs) = distributor.discoverRewards(0, 5, participant, 5);

        assertEq(nextEpoch, 5);
        assertEq(epochs.length, 3);
        assertEq(epochs[0], 0);
        assertEq(epochs[1], 1);
        assertEq(epochs[2], 2);

        (nextEpoch, epochs) = distributor.discoverRewards(1, 5, participant, 5);

        assertEq(nextEpoch, 6);
        assertEq(epochs.length, 2);
        assertEq(epochs[0], 1);
        assertEq(epochs[1], 2);
    }
}

contract DummyHook {
    bool public called;

    fallback(bytes calldata) external returns (bytes memory) {
        called = true;
        return "";
    }
}
