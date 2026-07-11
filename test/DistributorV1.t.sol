// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {DistributorV1, DistributorConfig, Range, GetInfoResult} from "../src/distributor/v1/DistributorV1.sol";
import {FixedEmission, FixedEmissionConfig} from "../src/utils/emission-function/FixedEmission.sol";
import {EmissionFunction} from "../src/utils/emission-function/EmissionFunction.sol";
import {Hook} from "src/utils/Hook.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

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

        require(distributionToken.transfer(address(this), 0), "transfer failed"); // no-op to keep balances consistent

        distributor = new DistributorV1(
            address(this),
            DistributorConfig({
                distributionToken: address(distributionToken),
                participationToken: address(participationToken),
                epochDuration: epochDuration,
                startTimestamp: startTimestamp,
                protocolFeeBps: 1000,
                protocolFeeReceiver: protocolFeeReceiver,
                minParticipation: 1 ether,
                claimDelaySeconds: claimDelaySeconds,
                allowFutureEpochParticipation: true,
                drainHookOnlyPassedEpochs: false,
                drainHook: Hook({contractAddress: address(drainHook), callData: ""}),
                emissionFunction: EmissionFunction({
                    emissionContract: emission, curveConfig: abi.encode(FixedEmissionConfig({amount: 100 ether}))
                }),
                allowlistSigner: address(0),
                allowlistDeadline: 0,
                numberOfEpochs: 100,
                totalDistributionAmount: 100 ether
            })
        );

        require(distributionToken.transfer(address(distributor), 1_000 ether), "transfer failed");
    }

    function testParticipateAndClaimAfterDelay() public {
        vm.prank(participant);
        participationToken.approve(address(distributor), 100 ether);

        vm.prank(participant);
        distributor.participate(10 ether, Range({from: 0, length: 2}), participant, new bytes(0));

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
        distributor.participate(10 ether, Range({from: 0, length: 1}), participant, new bytes(0));

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds - 1);
        vm.expectRevert(bytes("Too soon to claim"));
        distributor.claim(Range({from: 0, length: 1}));
    }

    function testClaimTriggersDrainHookAfterEpoch() public {
        vm.prank(participant);
        participationToken.approve(address(distributor), 10 ether);

        vm.prank(participant);
        distributor.participate(10 ether, Range({from: 0, length: 1}), participant, new bytes(0));

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);

        assertFalse(drainHook.called());

        vm.prank(participant);
        uint256 claimed = distributor.claim(Range({from: 0, length: 1}));

        assertEq(claimed, 100 ether);
        assertTrue(drainHook.called());
        assertEq(distributor.nextDrainHookToCall(), 1);
    }

    function testGetInfoReturnsClaimDelaySeconds() public view {
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
        distributor.participate(10 ether, Range({from: 0, length: 2}), participant, new bytes(0));

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
        distributor.participate(10 ether, Range({from: 0, length: 3}), participant, new bytes(0));

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

    function testMultipleUsersDividendDistribution() public {
        address userA = participant;
        address userB = address(0x5678);

        participationToken.mint(userB, 1_000 ether);

        uint256 userAAmount = 10 ether;
        uint256 userBAmount = 30 ether;

        vm.startPrank(userA);
        participationToken.approve(address(distributor), userAAmount);
        distributor.participate(userAAmount, Range({from: 0, length: 1}), userA, new bytes(0));
        vm.stopPrank();

        vm.startPrank(userB);
        participationToken.approve(address(distributor), userBAmount);
        distributor.participate(userBAmount, Range({from: 0, length: 1}), userB, new bytes(0));
        vm.stopPrank();

        assertEq(distributor.epochTotalParticipation(0), userAAmount + userBAmount);
        assertEq(distributor.epochUserParticipation(0, userA), userAAmount);
        assertEq(distributor.epochUserParticipation(0, userB), userBAmount);

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);

        uint256 expectedUserA = (userAAmount * 100 ether) / (userAAmount + userBAmount);
        uint256 expectedUserB = (userBAmount * 100 ether) / (userAAmount + userBAmount);

        vm.prank(userA);
        uint256 claimedA = distributor.claim(Range({from: 0, length: 1}));
        assertEq(claimedA, expectedUserA);
        assertEq(distributionToken.balanceOf(userA), expectedUserA);

        vm.prank(userB);
        uint256 claimedB = distributor.claim(Range({from: 0, length: 1}));
        assertEq(claimedB, expectedUserB);
        assertEq(distributionToken.balanceOf(userB), expectedUserB);

        assertEq(claimedA + claimedB, 100 ether);
    }

    function testPassedEpochParticipationNotAllowed() public {
        vm.warp(startTimestamp + epochDuration);
        assertEq(distributor.currentEpoch(), 1);

        vm.prank(participant);
        participationToken.approve(address(distributor), 10 ether);

        vm.prank(participant);
        vm.expectRevert(bytes("Passed epoch participation not allowed"));
        distributor.participate(10 ether, Range({from: 0, length: 1}), participant, new bytes(0));
    }

    function testFutureEpochParticipationAllowed() public {
        assertEq(distributor.currentEpoch(), 0);

        vm.prank(participant);
        participationToken.approve(address(distributor), 10 ether);

        vm.prank(participant);
        distributor.participate(10 ether, Range({from: 2, length: 1}), participant, new bytes(0));

        assertEq(distributor.epochUserParticipation(2, participant), 10 ether);
    }

    function testFutureEpochParticipationNotAllowed() public {
        DistributorV1 noFutureDistributor = new DistributorV1(
            address(this),
            DistributorConfig({
                distributionToken: address(distributionToken),
                participationToken: address(participationToken),
                epochDuration: epochDuration,
                startTimestamp: startTimestamp,
                protocolFeeBps: 1000,
                protocolFeeReceiver: protocolFeeReceiver,
                minParticipation: 1 ether,
                claimDelaySeconds: claimDelaySeconds,
                allowFutureEpochParticipation: false,
                drainHookOnlyPassedEpochs: false,
                drainHook: Hook({contractAddress: address(drainHook), callData: ""}),
                emissionFunction: EmissionFunction({
                    emissionContract: emission, curveConfig: abi.encode(FixedEmissionConfig({amount: 100 ether}))
                }),
                allowlistSigner: address(0),
                allowlistDeadline: 0,
                numberOfEpochs: 100,
                totalDistributionAmount: 100 ether
            })
        );

        distributionToken.mint(address(noFutureDistributor), 1_000 ether);

        assertEq(noFutureDistributor.currentEpoch(), 0);

        vm.prank(participant);
        participationToken.approve(address(noFutureDistributor), 10 ether);

        vm.prank(participant);
        vm.expectRevert(bytes("Future epoch participation not allowed"));
        noFutureDistributor.participate(10 ether, Range({from: 1, length: 1}), participant, new bytes(0));

        vm.prank(participant);
        vm.expectRevert(bytes("Future epoch participation not allowed"));
        noFutureDistributor.participate(10 ether, Range({from: 2, length: 1}), participant, new bytes(0));
    }

    // --- Allowlist tests ---

    function testAllowlistDisabledWorksWithoutSignature() public {
        assertEq(distributor.ALLOWLIST_SIGNER(), address(0));
        vm.prank(participant);
        participationToken.approve(address(distributor), 10 ether);
        vm.prank(participant);
        distributor.participate(10 ether, Range({from: 0, length: 1}), participant, new bytes(0));
        assertEq(distributor.epochUserParticipation(0, participant), 10 ether);
    }

    function testAllowlistRequiresValidSignatureBeforeDeadline() public {
        uint256 signerPk = 0xABCD;
        address signer = vm.addr(signerPk);
        uint256 deadline = block.timestamp + epochDuration;

        DistributorV1 allowlisted = new DistributorV1(
            address(this),
            DistributorConfig({
                distributionToken: address(distributionToken),
                participationToken: address(participationToken),
                epochDuration: epochDuration,
                startTimestamp: startTimestamp,
                protocolFeeBps: 1000,
                protocolFeeReceiver: protocolFeeReceiver,
                minParticipation: 1 ether,
                claimDelaySeconds: claimDelaySeconds,
                allowFutureEpochParticipation: true,
                drainHookOnlyPassedEpochs: false,
                drainHook: Hook({contractAddress: address(drainHook), callData: ""}),
                emissionFunction: EmissionFunction({
                    emissionContract: emission, curveConfig: abi.encode(FixedEmissionConfig({amount: 100 ether}))
                }),
                allowlistSigner: signer,
                allowlistDeadline: deadline,
                numberOfEpochs: 100,
                totalDistributionAmount: 100 ether
            })
        );
        distributionToken.mint(address(allowlisted), 1_000 ether);

        bytes memory badSignature = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));

        vm.prank(participant);
        participationToken.approve(address(allowlisted), 10 ether);

        vm.prank(participant);
        vm.expectRevert(bytes("not allowlisted"));
        allowlisted.participate(10 ether, Range({from: 0, length: 1}), participant, badSignature);
    }

    function testAllowlistAcceptsValidSignature() public {
        uint256 signerPk = 0xABCD;
        address signer = vm.addr(signerPk);
        uint256 deadline = block.timestamp + epochDuration;

        DistributorV1 allowlisted = new DistributorV1(
            address(this),
            DistributorConfig({
                distributionToken: address(distributionToken),
                participationToken: address(participationToken),
                epochDuration: epochDuration,
                startTimestamp: startTimestamp,
                protocolFeeBps: 1000,
                protocolFeeReceiver: protocolFeeReceiver,
                minParticipation: 1 ether,
                claimDelaySeconds: claimDelaySeconds,
                allowFutureEpochParticipation: true,
                drainHookOnlyPassedEpochs: false,
                drainHook: Hook({contractAddress: address(drainHook), callData: ""}),
                emissionFunction: EmissionFunction({
                    emissionContract: emission, curveConfig: abi.encode(FixedEmissionConfig({amount: 100 ether}))
                }),
                allowlistSigner: signer,
                allowlistDeadline: deadline,
                numberOfEpochs: 100,
                totalDistributionAmount: 100 ether
            })
        );
        distributionToken.mint(address(allowlisted), 1_000 ether);
        bytes32 message = keccak256(abi.encode(participant, block.chainid));

        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(message);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(participant);
        participationToken.approve(address(allowlisted), 10 ether);

        vm.prank(participant);
        allowlisted.participate(10 ether, Range({from: 0, length: 1}), participant, signature);

        assertEq(allowlisted.epochUserParticipation(0, participant), 10 ether);
    }

    function testAllowlistBypassedAfterDeadline() public {
        uint256 signerPk = 0xABCD;
        address signer = vm.addr(signerPk);

        uint256 deadline = startTimestamp + epochDuration / 2;

        DistributorV1 allowlisted = new DistributorV1(
            address(this),
            DistributorConfig({
                distributionToken: address(distributionToken),
                participationToken: address(participationToken),
                epochDuration: epochDuration,
                startTimestamp: startTimestamp,
                protocolFeeBps: 1000,
                protocolFeeReceiver: protocolFeeReceiver,
                minParticipation: 1 ether,
                claimDelaySeconds: claimDelaySeconds,
                allowFutureEpochParticipation: true,
                drainHookOnlyPassedEpochs: false,
                drainHook: Hook({contractAddress: address(drainHook), callData: ""}),
                emissionFunction: EmissionFunction({
                    emissionContract: emission, curveConfig: abi.encode(FixedEmissionConfig({amount: 100 ether}))
                }),
                allowlistSigner: signer,
                allowlistDeadline: deadline,
                numberOfEpochs: 100,
                totalDistributionAmount: 100 ether
            })
        );
        distributionToken.mint(address(allowlisted), 1_000 ether);

        vm.warp(deadline + 1);

        vm.prank(participant);
        participationToken.approve(address(allowlisted), 10 ether);

        vm.prank(participant);
        bytes memory emptySig;
        allowlisted.participate(10 ether, Range({from: 0, length: 1}), participant, emptySig);

        assertEq(allowlisted.epochUserParticipation(0, participant), 10 ether);
    }

    // --- claimFor / setClaimFeeBps tests ---

    function testSetClaimFeeBps() public {
        address user = participant;
        assertEq(distributor.claimFeeBps(user), 0);

        vm.expectEmit(true, true, true, true);
        emit DistributorV1.ClaimFeeBpsSet(user, 200);
        vm.prank(user);
        distributor.setClaimFeeBps(200);

        assertEq(distributor.claimFeeBps(user), 200);
    }

    function testSetClaimFeeBpsRevertsAboveMax() public {
        vm.prank(participant);
        vm.expectRevert(bytes("max 10000 bps"));
        distributor.setClaimFeeBps(10001);
    }

    function testClaimForSelfNoFeeTaken() public {
        _setupParticipant();

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);

        vm.prank(participant);
        distributor.setClaimFeeBps(500); // 5%

        vm.prank(participant);
        uint256 claimed = distributor.claimFor(participant, Range({from: 0, length: 1}));

        assertEq(claimed, 100 ether);
        assertEq(distributionToken.balanceOf(participant), 100 ether);
    }

    function testClaimForThirdPartyGetsFee() public {
        _setupParticipant();

        address thirdParty = address(0xCAFE);

        vm.prank(participant);
        distributor.setClaimFeeBps(200); // 2%

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);

        vm.prank(thirdParty);
        uint256 claimed = distributor.claimFor(participant, Range({from: 0, length: 1}));

        uint256 expectedFee = (100 ether * 200) / 10000;
        uint256 expectedUser = 100 ether - expectedFee;

        assertEq(claimed, expectedUser);
        assertEq(distributionToken.balanceOf(participant), expectedUser);
        assertEq(distributionToken.balanceOf(thirdParty), expectedFee);
    }

    function testClaimForWithZeroFee() public {
        _setupParticipant();

        address thirdParty = address(0xCAFE);

        // fee defaults to 0

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);

        vm.prank(thirdParty);
        uint256 claimed = distributor.claimFor(participant, Range({from: 0, length: 1}));

        assertEq(claimed, 100 ether);
        assertEq(distributionToken.balanceOf(participant), 100 ether);
        assertEq(distributionToken.balanceOf(thirdParty), 0);
    }

    function testClaimForMaxFee() public {
        _setupParticipant();

        address thirdParty = address(0xCAFE);

        vm.prank(participant);
        distributor.setClaimFeeBps(10000); // 100% — third party gets everything

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);

        vm.prank(thirdParty);
        uint256 claimed = distributor.claimFor(participant, Range({from: 0, length: 1}));

        assertEq(claimed, 0);
        assertEq(distributionToken.balanceOf(participant), 0);
        assertEq(distributionToken.balanceOf(thirdParty), 100 ether);
    }

    function testClaimForResetsParticipation() public {
        _setupParticipant();

        assertEq(distributor.epochUserParticipation(0, participant), 10 ether);

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);

        vm.prank(address(0xCAFE));
        distributor.claimFor(participant, Range({from: 0, length: 1}));

        assertEq(distributor.epochUserParticipation(0, participant), 0);
    }

    function testClaimForRevertsWhenTooSoon() public {
        _setupParticipant();

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds - 1);

        vm.prank(address(0xCAFE));
        vm.expectRevert(bytes("Too soon to claim"));
        distributor.claimFor(participant, Range({from: 0, length: 1}));
    }

    function testClaimForTriggersDrainHook() public {
        _setupParticipant();

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);

        assertFalse(drainHook.called());

        vm.prank(address(0xCAFE));
        distributor.claimFor(participant, Range({from: 0, length: 1}));

        assertTrue(drainHook.called());
    }

    function testClaimBehavesSameAsClaimForSelf() public {
        _setupParticipant();

        address secondUser = address(0x5678);
        participationToken.mint(secondUser, 1_000 ether);

        vm.startPrank(secondUser);
        participationToken.approve(address(distributor), 10 ether);
        distributor.participate(10 ether, Range({from: 0, length: 1}), secondUser, new bytes(0));
        vm.stopPrank();

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);

        uint256 expected = (10 ether * 100 ether) / (20 ether);

        vm.prank(participant);
        uint256 claimedViaClaim = distributor.claim(Range({from: 0, length: 1}));

        vm.prank(secondUser);
        uint256 claimedViaClaimFor = distributor.claimFor(secondUser, Range({from: 0, length: 1}));

        assertEq(claimedViaClaim, expected);
        assertEq(claimedViaClaimFor, expected);
        assertEq(distributionToken.balanceOf(participant), expected);
        assertEq(distributionToken.balanceOf(secondUser), expected);
    }

    function testClaimMultipleRangesViaClaimFor() public {
        _setupParticipant(2);

        vm.warp(startTimestamp + (2 * epochDuration) + claimDelaySeconds);

        vm.prank(address(0xCAFE));
        uint256 totalClaimed = distributor.claimFor(participant, Range({from: 0, length: 2}));

        assertEq(totalClaimed, 200 ether);
        assertEq(distributionToken.balanceOf(participant), 200 ether);
    }

    function testClaimForThirdPartyRespectsIndividualFee() public {
        address userA = participant;
        address userB = address(0x5678);
        address thirdParty = address(0xCAFE);

        participationToken.mint(userB, 1_000 ether);

        vm.startPrank(userA);
        participationToken.approve(address(distributor), 10 ether);
        distributor.participate(10 ether, Range({from: 0, length: 1}), userA, new bytes(0));
        vm.stopPrank();

        vm.startPrank(userB);
        participationToken.approve(address(distributor), 10 ether);
        distributor.participate(10 ether, Range({from: 0, length: 1}), userB, new bytes(0));
        vm.stopPrank();

        vm.prank(userA);
        distributor.setClaimFeeBps(1000); // 10%

        vm.prank(userB);
        distributor.setClaimFeeBps(200); // 2%

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);

        uint256 userAReward = (10 ether * 100 ether) / (20 ether);
        uint256 userBReward = (10 ether * 100 ether) / (20 ether);

        vm.prank(thirdParty);
        uint256 claimedA = distributor.claimFor(userA, Range({from: 0, length: 1}));

        vm.prank(thirdParty);
        uint256 claimedB = distributor.claimFor(userB, Range({from: 0, length: 1}));

        uint256 feeA = (userAReward * 1000) / 10000;
        uint256 feeB = (userBReward * 200) / 10000;

        assertEq(claimedA, userAReward - feeA);
        assertEq(claimedB, userBReward - feeB);
        assertEq(distributionToken.balanceOf(thirdParty), feeA + feeB);
        assertEq(distributionToken.balanceOf(userA), userAReward - feeA);
        assertEq(distributionToken.balanceOf(userB), userBReward - feeB);
    }

    function testClaimForEmitsClaimed() public {
        _setupParticipant();

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);

        vm.expectEmit(true, true, true, true);
        emit DistributorV1.Claimed(participant, 0, 1, 100 ether);

        vm.prank(address(0xCAFE));
        distributor.claimFor(participant, Range({from: 0, length: 1}));
    }

    function testClaimForFeeEmitsClaimedWithReducedAmount() public {
        _setupParticipant();

        vm.prank(participant);
        distributor.setClaimFeeBps(500); // 5%

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);

        uint256 expectedUserAmount = 100 ether - (100 ether * 500 / 10000);

        vm.expectEmit(true, true, true, true);
        emit DistributorV1.Claimed(participant, 0, 1, expectedUserAmount);

        vm.prank(address(0xCAFE));
        distributor.claimFor(participant, Range({from: 0, length: 1}));
    }

    function testClaimForIsNotReentrant() public {
        _setupParticipant();

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);

        // call claimFor twice — second call should get 0 since participation is zeroed
        vm.prank(address(0xCAFE));
        uint256 first = distributor.claimFor(participant, Range({from: 0, length: 1}));
        assertEq(first, 100 ether);

        vm.prank(address(0xCAFE));
        uint256 second = distributor.claimFor(participant, Range({from: 0, length: 1}));
        assertEq(second, 0);
    }

    function testOriginalClaimStillWorks() public {
        _setupParticipant();

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);

        vm.prank(participant);
        uint256 claimed = distributor.claim(Range({from: 0, length: 1}));

        assertEq(claimed, 100 ether);
        assertEq(distributionToken.balanceOf(participant), 100 ether);
    }

    // --- helpers ---

    function _setupParticipant() internal {
        _setupParticipant(1);
    }

    function _setupParticipant(uint256 numEpochs) internal {
        vm.startPrank(participant);
        participationToken.approve(address(distributor), 10 ether * numEpochs);
        distributor.participate(10 ether, Range({from: 0, length: numEpochs}), participant, new bytes(0));
        vm.stopPrank();
    }

    // --- drainHookOnlyPassedEpochs tests ---

    function _createDistributorWithDrainHook(bool onlyPassedEpochs, address hookAddress)
        internal
        returns (DistributorV1)
    {
        DistributorV1 d = new DistributorV1(
            address(this),
            DistributorConfig({
                distributionToken: address(distributionToken),
                participationToken: address(participationToken),
                epochDuration: epochDuration,
                startTimestamp: startTimestamp,
                protocolFeeBps: 1000,
                protocolFeeReceiver: protocolFeeReceiver,
                minParticipation: 1 ether,
                claimDelaySeconds: claimDelaySeconds,
                allowFutureEpochParticipation: true,
                drainHookOnlyPassedEpochs: onlyPassedEpochs,
                drainHook: Hook({contractAddress: hookAddress, callData: ""}),
                emissionFunction: EmissionFunction({
                    emissionContract: emission, curveConfig: abi.encode(FixedEmissionConfig({amount: 100 ether}))
                }),
                allowlistSigner: address(0),
                allowlistDeadline: 0,
                numberOfEpochs: 100,
                totalDistributionAmount: 100 ether
            })
        );
        distributionToken.mint(address(d), 1_000 ether);
        return d;
    }

    function testDrainHookOnlyPassedEpochsReleasesOnlyPassedParticipation() public {
        PullingHook pullingHook = new PullingHook(address(participationToken));
        DistributorV1 limited = _createDistributorWithDrainHook(true, address(pullingHook));
        participationToken.mint(participant, 20 ether);

        vm.startPrank(participant);
        participationToken.approve(address(limited), 20 ether);
        limited.participate(10 ether, Range({from: 0, length: 1}), participant, new bytes(0));
        limited.participate(10 ether, Range({from: 2, length: 1}), participant, new bytes(0));
        vm.stopPrank();

        assertEq(participationToken.balanceOf(address(limited)), 20 ether);

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);
        assertEq(limited.currentEpoch(), 1);

        vm.prank(participant);
        limited.claim(Range({from: 0, length: 1}));

        uint256 epochBalance = 10 ether;
        uint256 fee = (epochBalance * 1000) / 10000;
        assertEq(pullingHook.pulled(), epochBalance - fee, "hook gets epoch 0 minus fee");
        assertEq(participationToken.balanceOf(address(limited)), 10 ether, "epoch 2 participation remains");
    }

    function testDrainHookOnlyPassedEpochsFalseReleasesAllBalance() public {
        PullingHook pullingHook = new PullingHook(address(participationToken));
        DistributorV1 unlimited = _createDistributorWithDrainHook(false, address(pullingHook));
        participationToken.mint(participant, 20 ether);

        vm.startPrank(participant);
        participationToken.approve(address(unlimited), 20 ether);
        unlimited.participate(10 ether, Range({from: 0, length: 1}), participant, new bytes(0));
        unlimited.participate(10 ether, Range({from: 2, length: 1}), participant, new bytes(0));
        vm.stopPrank();

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);

        vm.prank(participant);
        unlimited.claim(Range({from: 0, length: 1}));

        uint256 totalBalance = 20 ether;
        uint256 fee = (totalBalance * 1000) / 10000;
        assertEq(pullingHook.pulled(), totalBalance - fee, "hook gets all minus fee");
        assertEq(participationToken.balanceOf(address(unlimited)), 0, "all participation drained");
    }

    function testDrainHookOnlyPassedEpochsMultiplePassedEpochs() public {
        PullingHook pullingHook = new PullingHook(address(participationToken));
        DistributorV1 limited = _createDistributorWithDrainHook(true, address(pullingHook));
        participationToken.mint(participant, 30 ether);

        vm.startPrank(participant);
        participationToken.approve(address(limited), 30 ether);
        limited.participate(10 ether, Range({from: 0, length: 3}), participant, new bytes(0));
        vm.stopPrank();

        vm.warp(startTimestamp + (3 * epochDuration) + claimDelaySeconds);
        assertEq(limited.currentEpoch(), 3);

        vm.prank(participant);
        limited.claim(Range({from: 0, length: 1}));

        uint256 epochSum = 30 ether;
        uint256 fee = (epochSum * 1000) / 10000;
        assertEq(pullingHook.pulled(), epochSum - fee, "hook gets all 3 epochs minus fee");
        assertEq(participationToken.balanceOf(address(limited)), 0, "all participation drained");
    }

    function testDrainHookOnlyPassedEpochsNoPassedEpochsReleasesNothing() public {
        PullingHook pullingHook = new PullingHook(address(participationToken));
        DistributorV1 limited = _createDistributorWithDrainHook(true, address(pullingHook));
        participationToken.mint(participant, 10 ether);

        vm.startPrank(participant);
        participationToken.approve(address(limited), 10 ether);
        limited.participate(10 ether, Range({from: 1, length: 1}), participant, new bytes(0));
        vm.stopPrank();

        // Still in epoch 0 — no epochs have passed
        assertEq(limited.currentEpoch(), 0);

        limited.callDrainHook();

        assertEq(pullingHook.pulled(), 0, "no epochs passed, hook gets nothing");
        assertEq(participationToken.balanceOf(address(limited)), 10 ether, "all participation remains");
    }

    function testDrainHookOnlyPassedEpochsCapsAtActualBalance() public {
        PullingHook pullingHook = new PullingHook(address(participationToken));
        DistributorV1 limited = _createDistributorWithDrainHook(true, address(pullingHook));
        participationToken.mint(participant, 10 ether);

        vm.startPrank(participant);
        participationToken.approve(address(limited), 10 ether);
        limited.participate(10 ether, Range({from: 0, length: 1}), participant, new bytes(0));
        vm.stopPrank();

        // Skim 5 ether from the contract — epoch total is 10 but actual balance is 5
        uint256 skimAmount = 5 ether;
        vm.prank(address(limited));
        assertTrue(participationToken.transfer(address(0xDEAD), skimAmount));

        assertEq(participationToken.balanceOf(address(limited)), 10 ether - skimAmount);

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);

        vm.prank(participant);
        limited.claim(Range({from: 0, length: 1}));

        uint256 actualBeforeFee = 10 ether - skimAmount;
        uint256 fee = (actualBeforeFee * 1000) / 10000;
        assertEq(pullingHook.pulled(), actualBeforeFee - fee, "hook gets capped balance minus fee");
    }

    function testDrainHookOnlyPassedEpochsFalseHookGetsMoreThanTrue() public {
        PullingHook hookTrue = new PullingHook(address(participationToken));
        PullingHook hookFalse = new PullingHook(address(participationToken));
        DistributorV1 limited = _createDistributorWithDrainHook(true, address(hookTrue));
        DistributorV1 unlimited = _createDistributorWithDrainHook(false, address(hookFalse));
        participationToken.mint(participant, 40 ether);

        vm.startPrank(participant);
        participationToken.approve(address(limited), 20 ether);
        limited.participate(10 ether, Range({from: 0, length: 1}), participant, new bytes(0));
        limited.participate(10 ether, Range({from: 2, length: 1}), participant, new bytes(0));
        participationToken.approve(address(unlimited), 20 ether);
        unlimited.participate(10 ether, Range({from: 0, length: 1}), participant, new bytes(0));
        unlimited.participate(10 ether, Range({from: 2, length: 1}), participant, new bytes(0));
        vm.stopPrank();

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);

        vm.prank(participant);
        limited.claim(Range({from: 0, length: 1}));
        vm.prank(participant);
        unlimited.claim(Range({from: 0, length: 1}));

        assertTrue(hookFalse.pulled() > hookTrue.pulled(), "false mode should pull more than true mode");
    }

    function testAllowlistSignatureChainIdBindsToChain() public {
        uint256 signerPk = 0xABCD;
        address signer = vm.addr(signerPk);
        uint256 deadline = block.timestamp + epochDuration;

        DistributorV1 allowlisted = new DistributorV1(
            address(this),
            DistributorConfig({
                distributionToken: address(distributionToken),
                participationToken: address(participationToken),
                epochDuration: epochDuration,
                startTimestamp: startTimestamp,
                protocolFeeBps: 1000,
                protocolFeeReceiver: protocolFeeReceiver,
                minParticipation: 1 ether,
                claimDelaySeconds: claimDelaySeconds,
                allowFutureEpochParticipation: true,
                drainHookOnlyPassedEpochs: false,
                drainHook: Hook({contractAddress: address(drainHook), callData: ""}),
                emissionFunction: EmissionFunction({
                    emissionContract: emission, curveConfig: abi.encode(FixedEmissionConfig({amount: 100 ether}))
                }),
                allowlistSigner: signer,
                allowlistDeadline: deadline,
                numberOfEpochs: 100,
                totalDistributionAmount: 100 ether
            })
        );
        distributionToken.mint(address(allowlisted), 1_000 ether);

        bytes32 message = keccak256(abi.encode(participant, block.chainid + 1));
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(message);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(participant);
        participationToken.approve(address(allowlisted), 10 ether);

        vm.prank(participant);
        vm.expectRevert(bytes("not allowlisted"));
        allowlisted.participate(10 ether, Range({from: 0, length: 1}), participant, signature);
    }
}

contract DummyHook {
    bool public called;

    fallback(bytes calldata) external returns (bytes memory) {
        called = true;
        return "";
    }
}

contract PullingHook {
    uint256 public pulled;
    address public token;

    constructor(address _token) {
        token = _token;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        uint256 allowance = IERC20(token).allowance(msg.sender, address(this));
        if (allowance > 0) {
            require(IERC20(token).transferFrom(msg.sender, address(this), allowance));
            pulled += allowance;
        }
        return "";
    }
}
