// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {
    DistributorV1,
    DistributorConfig,
    Range,
    GetContractInfoResult,
    EpochInfo,
    ReleasePolicy
} from "../src/v1/DistributorV1.sol";
import {FixedEmission, FixedEmissionConfig} from "../src/utils/emission-function/FixedEmission.sol";
import {MetadataEntry} from "../src/utils/Metadata.sol";
import {LinearEmission, LinearEmissionConfig} from "../src/utils/emission-function/LinearEmission.sol";
import {ExponentialEmission, ExponentialEmissionConfig} from "../src/utils/emission-function/ExponentialEmission.sol";
import {EmissionFunction} from "../src/utils/emission-function/EmissionFunction.sol";
import {IEmissionFunction} from "../src/utils/emission-function/IEmissionFunction.sol";
import {Share} from "src/utils/Shares.sol";
import {Hook, HookLib} from "src/utils/Hook.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract DistributorV1Test is Test {
    DistributorV1 public distributor;
    ERC20Mock public distributionToken;
    ERC20Mock public participationToken;
    FixedEmission public emission;

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

        distributionToken.mint(address(this), 1_000 ether);
        participationToken.mint(participant, 1_000 ether);

        require(distributionToken.transfer(address(this), 0), "transfer failed"); // no-op to keep balances consistent

        Share[] memory shares = _singleShare(10000, address(0), "");

        distributor = new DistributorV1(
            address(this),
            address(0),
            DistributorConfig({
                distributionToken: address(distributionToken),
                participationToken: address(participationToken),
                epochDuration: epochDuration,
                startTimestamp: startTimestamp,
                minParticipation: 1 ether,
                claimDelaySeconds: claimDelaySeconds,
                allowFutureEpochParticipation: true,
                releasePolicy: ReleasePolicy.Anyone,
                emissionFunction: EmissionFunction({
                    emissionContract: emission, curveConfig: abi.encode(FixedEmissionConfig({amount: 100 ether}))
                }),
                shares: shares,
                allowlistSigner: address(0),
                allowlistDeadline: 0,
                numberOfEpochs: 100,
                totalDistributionAmount: 10_000 ether,
                initialMetadata: new MetadataEntry[](0),
                metadataEditable: true
            })
        );

        require(distributionToken.transfer(address(distributor), 1_000 ether), "transfer failed");
    }

    // --- constructor validation tests ---

    function testConstructorRevertsOnZeroEpochDuration() public {
        DistributorConfig memory config = _defaultConfig();
        config.epochDuration = 0;
        vm.expectRevert(bytes("epoch duration is zero"));
        new DistributorV1(address(this), address(0), config);
    }

    function testConstructorRevertsOnPastStartTimestamp() public {
        vm.warp(startTimestamp + 1);
        DistributorConfig memory config = _defaultConfig();
        config.startTimestamp = startTimestamp;
        vm.expectRevert(bytes("start timestamp in the past"));
        new DistributorV1(address(this), address(0), config);
    }

    function testConstructorRevertsOnZeroNumberOfEpochs() public {
        DistributorConfig memory config = _defaultConfig();
        config.numberOfEpochs = 0;
        vm.expectRevert(bytes("number of epochs is zero"));
        new DistributorV1(address(this), address(0), config);
    }

    function testConstructorAllowsStartTimestampEqualToNow() public {
        DistributorConfig memory config = _defaultConfig();
        DistributorV1 d = new DistributorV1(address(this), address(0), config);
        assertEq(d.currentEpoch(), 0);
    }

    function testConstructorRevertsOnZeroDistributionToken() public {
        DistributorConfig memory config = _defaultConfig();
        config.distributionToken = address(0);
        vm.expectRevert(bytes("distribution token is zero"));
        new DistributorV1(address(this), address(0), config);
    }

    function testConstructorRevertsOnZeroParticipationToken() public {
        DistributorConfig memory config = _defaultConfig();
        config.participationToken = address(0);
        vm.expectRevert(bytes("participation token is zero"));
        new DistributorV1(address(this), address(0), config);
    }

    function testConstructorRevertsOnZeroEmissionContract() public {
        DistributorConfig memory config = _defaultConfig();
        config.emissionFunction.emissionContract = IEmissionFunction(address(0));
        vm.expectRevert(bytes("emission contract is zero"));
        new DistributorV1(address(this), address(0), config);
    }

    function testConstructorRevertsOnExpiredAllowlist() public {
        DistributorConfig memory config = _defaultConfig();
        config.allowlistSigner = address(0xABCD);
        config.allowlistDeadline = block.timestamp - 1;
        vm.expectRevert(bytes("allowlist expired"));
        new DistributorV1(address(this), address(0), config);
    }

    function testConstructorAllowsAllowlistDeadlineEqualToNow() public {
        DistributorConfig memory config = _defaultConfig();
        config.allowlistSigner = address(0xABCD);
        config.allowlistDeadline = block.timestamp;
        new DistributorV1(address(this), address(0), config);
    }

    function testInstancesShareIdenticalDeployedBytecode() public {
        DistributorConfig memory configA = _defaultConfig();
        DistributorConfig memory configB = _defaultConfig();
        configB.distributionToken = address(0x1111);
        configB.participationToken = address(0x2222);
        configB.epochDuration = 86_400;
        configB.startTimestamp = startTimestamp + 999;
        configB.minParticipation = 42;
        configB.claimDelaySeconds = 777;
        configB.allowFutureEpochParticipation = false;
        configB.allowlistSigner = address(0x3333);
        configB.allowlistDeadline = startTimestamp + 888;
        configB.numberOfEpochs = 7;
        configB.totalDistributionAmount = 700 ether;
        configB.shares = _singleShare(10000, address(0x4444), hex"abcd");

        DistributorV1 a = new DistributorV1(address(0xAAAA), address(0), configA);
        DistributorV1 b = new DistributorV1(address(0xBBBB), address(0), configB);

        assertEq(address(distributor).codehash, address(a).codehash);
        assertEq(address(a).codehash, address(b).codehash);
    }

    // --- constructor supply check tests ---

    function testConstructorRevertsWhenTotalDistributionAmountBelowSum() public {
        // default config: 100 epochs of 100 ether = 10_000 ether total rewards
        DistributorConfig memory config = _defaultConfig();
        config.totalDistributionAmount = 9_999 ether;
        vm.expectRevert(bytes("total distribution amount is not enough"));
        new DistributorV1(address(this), address(0), config);
    }

    function testConstructorAllowsExactSum() public {
        DistributorConfig memory config = _defaultConfig();
        config.totalDistributionAmount = 10_000 ether;
        DistributorV1 d = new DistributorV1(address(this), address(0), config);
        assertEq(d.TOTAL_DISTRIBUTION_AMOUNT(), 10_000 ether);
    }

    function testConstructorAllowsOverfundedDistribution() public {
        DistributorConfig memory config = _defaultConfig();
        config.totalDistributionAmount = 20_000 ether;
        DistributorV1 d = new DistributorV1(address(this), address(0), config);
        assertEq(d.TOTAL_DISTRIBUTION_AMOUNT(), 20_000 ether);
    }

    function testConstructorChecksExponentialEmissionSum() public {
        ExponentialEmission exp = new ExponentialEmission();
        DistributorConfig memory config = _defaultConfig();
        // halving emission: 1000 ether, 500 ether, 250 ether, ... -> total ~ 2000 ether
        config.emissionFunction = EmissionFunction({
            emissionContract: exp,
            curveConfig: abi.encode(
                ExponentialEmissionConfig({initialAmount: 1_000 ether, numerator: 1, denominator: 2})
            )
        });

        config.totalDistributionAmount = 1_999 ether;
        vm.expectRevert(bytes("total distribution amount is not enough"));
        new DistributorV1(address(this), address(0), config);

        config.totalDistributionAmount = 2_000 ether;
        DistributorV1 d = new DistributorV1(address(this), address(0), config);
        assertEq(d.TOTAL_DISTRIBUTION_AMOUNT(), 2_000 ether);
    }

    function testConstructorChecksLinearEmissionSum() public {
        LinearEmission linear = new LinearEmission();
        DistributorConfig memory config = _defaultConfig();
        // 1000 ether decreasing by 100 ether per epoch: epochs 0..9 give 1000..100, rest 0 -> 5500 ether
        config.emissionFunction = EmissionFunction({
            emissionContract: linear,
            curveConfig: abi.encode(LinearEmissionConfig({base: 1_000 ether, slope: -100 ether}))
        });

        config.totalDistributionAmount = 5_499 ether;
        vm.expectRevert(bytes("total distribution amount is not enough"));
        new DistributorV1(address(this), address(0), config);

        config.totalDistributionAmount = 5_500 ether;
        DistributorV1 d = new DistributorV1(address(this), address(0), config);
        assertEq(d.TOTAL_DISTRIBUTION_AMOUNT(), 5_500 ether);
    }

    function testTotalClaimedMatchesCalculateTotal() public {
        // single participant participating in the first 10 epochs must be able to claim
        // exactly the amount the emission function promises for those epochs
        vm.prank(participant);
        participationToken.approve(address(distributor), 100 ether);

        vm.prank(participant);
        distributor.participate(10 ether, Range({from: 0, length: 10}), participant, new bytes(0));

        vm.warp(startTimestamp + (10 * epochDuration) + claimDelaySeconds);

        vm.prank(participant);
        uint256 claimed = distributor.claim(participant, Range({from: 0, length: 10}));

        bytes memory curveConfig = abi.encode(FixedEmissionConfig({amount: 100 ether}));
        assertEq(claimed, emission.calculateTotal(curveConfig, 10));
        assertEq(claimed, 1_000 ether);
        assertLe(claimed, distributor.TOTAL_DISTRIBUTION_AMOUNT());
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
        uint256 claimed = distributor.claim(participant, Range({from: 0, length: 1}));

        assertEq(claimed, 100 ether);
        assertEq(distributionToken.balanceOf(participant), 100 ether);
        assertEq(distributor.epochUserClaimed(0, participant), true);
    }

    function testClaimRevertsUntilDelayExpires() public {
        vm.prank(participant);
        participationToken.approve(address(distributor), 10 ether);

        vm.prank(participant);
        distributor.participate(10 ether, Range({from: 0, length: 1}), participant, new bytes(0));

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds - 1);
        vm.expectRevert(bytes("Too soon to claim"));
        distributor.claim(address(this), Range({from: 0, length: 1}));
    }

    function testGetInfoReturnsClaimDelaySeconds() public view {
        GetContractInfoResult memory info = distributor.getContractInfo();

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

        EpochInfo[] memory epochs = distributor.getEpochInfo(participant, Range({from: 0, length: 2}));

        assertEq(epochs.length, 2);
        assertEq(epochs[0].userParticipationAmount, 10 ether);
        assertEq(epochs[0].totalParticipationAmount, 10 ether);
        assertEq(epochs[0].rewardAmount, 100 ether);
        assertEq(epochs[1].userParticipationAmount, 10 ether);
        assertEq(epochs[1].totalParticipationAmount, 10 ether);
        assertEq(epochs[1].rewardAmount, 100 ether);
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
        uint256 claimedA = distributor.claim(userA, Range({from: 0, length: 1}));
        assertEq(claimedA, expectedUserA);
        assertEq(distributionToken.balanceOf(userA), expectedUserA);

        vm.prank(userB);
        uint256 claimedB = distributor.claim(userB, Range({from: 0, length: 1}));
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
        Share[] memory shares = _singleShare(10000, address(0), "");

        DistributorV1 noFutureDistributor = new DistributorV1(
            address(this),
            address(0),
            DistributorConfig({
                distributionToken: address(distributionToken),
                participationToken: address(participationToken),
                epochDuration: epochDuration,
                startTimestamp: startTimestamp,
                minParticipation: 1 ether,
                claimDelaySeconds: claimDelaySeconds,
                allowFutureEpochParticipation: false,
                releasePolicy: ReleasePolicy.Anyone,
                emissionFunction: EmissionFunction({
                    emissionContract: emission, curveConfig: abi.encode(FixedEmissionConfig({amount: 100 ether}))
                }),
                shares: shares,
                allowlistSigner: address(0),
                allowlistDeadline: 0,
                numberOfEpochs: 100,
                totalDistributionAmount: 10_000 ether,
                initialMetadata: new MetadataEntry[](0),
                metadataEditable: true
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

        Share[] memory shares = _singleShare(10000, address(0), "");

        DistributorV1 allowlisted = new DistributorV1(
            address(this),
            address(0),
            DistributorConfig({
                distributionToken: address(distributionToken),
                participationToken: address(participationToken),
                epochDuration: epochDuration,
                startTimestamp: startTimestamp,
                minParticipation: 1 ether,
                claimDelaySeconds: claimDelaySeconds,
                allowFutureEpochParticipation: true,
                releasePolicy: ReleasePolicy.Anyone,
                emissionFunction: EmissionFunction({
                    emissionContract: emission, curveConfig: abi.encode(FixedEmissionConfig({amount: 100 ether}))
                }),
                shares: shares,
                allowlistSigner: signer,
                allowlistDeadline: deadline,
                numberOfEpochs: 100,
                totalDistributionAmount: 10_000 ether,
                initialMetadata: new MetadataEntry[](0),
                metadataEditable: true
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

        Share[] memory shares = _singleShare(10000, address(0), "");

        DistributorV1 allowlisted = new DistributorV1(
            address(this),
            address(0),
            DistributorConfig({
                distributionToken: address(distributionToken),
                participationToken: address(participationToken),
                epochDuration: epochDuration,
                startTimestamp: startTimestamp,
                minParticipation: 1 ether,
                claimDelaySeconds: claimDelaySeconds,
                allowFutureEpochParticipation: true,
                releasePolicy: ReleasePolicy.Anyone,
                emissionFunction: EmissionFunction({
                    emissionContract: emission, curveConfig: abi.encode(FixedEmissionConfig({amount: 100 ether}))
                }),
                shares: shares,
                allowlistSigner: signer,
                allowlistDeadline: deadline,
                numberOfEpochs: 100,
                totalDistributionAmount: 10_000 ether,
                initialMetadata: new MetadataEntry[](0),
                metadataEditable: true
            })
        );
        distributionToken.mint(address(allowlisted), 1_000 ether);
        bytes32 message = keccak256(abi.encode(address(allowlisted), participant, block.chainid));

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

        Share[] memory shares = _singleShare(10000, address(0), "");

        DistributorV1 allowlisted = new DistributorV1(
            address(this),
            address(0),
            DistributorConfig({
                distributionToken: address(distributionToken),
                participationToken: address(participationToken),
                epochDuration: epochDuration,
                startTimestamp: startTimestamp,
                minParticipation: 1 ether,
                claimDelaySeconds: claimDelaySeconds,
                allowFutureEpochParticipation: true,
                releasePolicy: ReleasePolicy.Anyone,
                emissionFunction: EmissionFunction({
                    emissionContract: emission, curveConfig: abi.encode(FixedEmissionConfig({amount: 100 ether}))
                }),
                shares: shares,
                allowlistSigner: signer,
                allowlistDeadline: deadline,
                numberOfEpochs: 100,
                totalDistributionAmount: 10_000 ether,
                initialMetadata: new MetadataEntry[](0),
                metadataEditable: true
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

    function testAllowlistSignatureCoversRecipientNotPayer() public {
        uint256 signerPk = 0xABCD;
        DistributorConfig memory config = _defaultConfig();
        config.allowlistSigner = vm.addr(signerPk);
        config.allowlistDeadline = block.timestamp + epochDuration;
        DistributorV1 allowlisted = new DistributorV1(address(this), address(0), config);
        distributionToken.mint(address(allowlisted), 1_000 ether);

        // signature over the recipient (`participant`), not over the payer
        bytes32 message = keccak256(abi.encode(address(allowlisted), participant, block.chainid));
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(message);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // a non-allowlisted third party pays with their own tokens; the allowlisted recipient is credited
        participationToken.mint(address(this), 10 ether);
        participationToken.approve(address(allowlisted), 10 ether);
        allowlisted.participate(10 ether, Range({from: 0, length: 1}), participant, signature);

        assertEq(allowlisted.epochUserParticipation(0, participant), 10 ether);
        assertEq(allowlisted.epochUserParticipation(0, address(this)), 0);
    }

    function testAllowlistRejectsSignatureForDifferentRecipient() public {
        uint256 signerPk = 0xABCD;
        DistributorConfig memory config = _defaultConfig();
        config.allowlistSigner = vm.addr(signerPk);
        config.allowlistDeadline = block.timestamp + epochDuration;
        DistributorV1 allowlisted = new DistributorV1(address(this), address(0), config);
        distributionToken.mint(address(allowlisted), 1_000 ether);

        // a signature covering the payer (address(this)) must not allow crediting another recipient
        bytes32 message = keccak256(abi.encode(address(allowlisted), address(this), block.chainid));
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(message);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        bytes memory payerSignature = abi.encodePacked(r, s, v);

        participationToken.mint(address(this), 10 ether);
        participationToken.approve(address(allowlisted), 10 ether);

        vm.expectRevert(bytes("not allowlisted"));
        allowlisted.participate(10 ether, Range({from: 0, length: 1}), participant, payerSignature);
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
        uint256 claimed = distributor.claim(participant, Range({from: 0, length: 1}));

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
        uint256 claimed = distributor.claim(participant, Range({from: 0, length: 1}));

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
        uint256 claimed = distributor.claim(participant, Range({from: 0, length: 1}));

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
        uint256 claimed = distributor.claim(participant, Range({from: 0, length: 1}));

        assertEq(claimed, 0);
        assertEq(distributionToken.balanceOf(participant), 0);
        assertEq(distributionToken.balanceOf(thirdParty), 100 ether);
    }

    function testClaimForResetsParticipation() public {
        _setupParticipant();

        assertEq(distributor.epochUserParticipation(0, participant), 10 ether);

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);

        assertEq(distributor.epochUserClaimed(0, participant), false);
        vm.prank(address(0xCAFE));
        distributor.claim(participant, Range({from: 0, length: 1}));

        assertEq(distributor.epochUserParticipation(0, participant), 10 ether);
        assertEq(distributor.epochUserClaimed(0, participant), true);
    }

    function testClaimForRevertsWhenTooSoon() public {
        _setupParticipant();

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds - 1);

        vm.prank(address(0xCAFE));
        vm.expectRevert(bytes("Too soon to claim"));
        distributor.claim(participant, Range({from: 0, length: 1}));
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
        uint256 claimedViaClaim = distributor.claim(participant, Range({from: 0, length: 1}));

        vm.prank(secondUser);
        uint256 claimedViaClaimFor = distributor.claim(secondUser, Range({from: 0, length: 1}));

        assertEq(claimedViaClaim, expected);
        assertEq(claimedViaClaimFor, expected);
        assertEq(distributionToken.balanceOf(participant), expected);
        assertEq(distributionToken.balanceOf(secondUser), expected);
    }

    function testClaimMultipleRangesViaClaimFor() public {
        _setupParticipant(2);

        vm.warp(startTimestamp + (2 * epochDuration) + claimDelaySeconds);

        vm.prank(address(0xCAFE));
        uint256 totalClaimed = distributor.claim(participant, Range({from: 0, length: 2}));

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
        uint256 claimedA = distributor.claim(userA, Range({from: 0, length: 1}));

        vm.prank(thirdParty);
        uint256 claimedB = distributor.claim(userB, Range({from: 0, length: 1}));

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
        emit DistributorV1.Claimed(participant, 0, 1, 100 ether, 0);

        vm.prank(address(0xCAFE));
        distributor.claim(participant, Range({from: 0, length: 1}));
    }

    function testClaimForFeeEmitsClaimedWithGrossAndFee() public {
        _setupParticipant();

        vm.prank(participant);
        distributor.setClaimFeeBps(500); // 5%

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);

        uint256 expectedFee = 100 ether * 500 / 10000;
        uint256 expectedUserAmount = 100 ether - expectedFee;

        vm.expectEmit(true, true, true, true);
        emit DistributorV1.Claimed(participant, 0, 1, 100 ether, expectedFee);

        vm.prank(address(0xCAFE));
        uint256 claimed = distributor.claim(participant, Range({from: 0, length: 1}));

        // return value stays net (what the user actually received)
        assertEq(claimed, expectedUserAmount);
        assertEq(expectedUserAmount, 100 ether - expectedFee);
    }

    function testClaimForIsNotReentrant() public {
        _setupParticipant();

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);

        // call claim twice — second call should get 0 since participation is zeroed
        vm.prank(address(0xCAFE));
        uint256 first = distributor.claim(participant, Range({from: 0, length: 1}));
        assertEq(first, 100 ether);

        vm.prank(address(0xCAFE));
        vm.expectRevert(bytes("nothing to claim"));
        distributor.claim(participant, Range({from: 0, length: 1}));
    }

    function testOriginalClaimStillWorks() public {
        _setupParticipant();

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);

        vm.prank(participant);
        uint256 claimed = distributor.claim(participant, Range({from: 0, length: 1}));

        assertEq(claimed, 100 ether);
        assertEq(distributionToken.balanceOf(participant), 100 ether);
    }

    // --- helpers ---

    function _defaultConfig() internal view returns (DistributorConfig memory) {
        return DistributorConfig({
            distributionToken: address(distributionToken),
            participationToken: address(participationToken),
            epochDuration: epochDuration,
            startTimestamp: startTimestamp,
            minParticipation: 1 ether,
            claimDelaySeconds: claimDelaySeconds,
            allowFutureEpochParticipation: true,
            releasePolicy: ReleasePolicy.Anyone,
            emissionFunction: EmissionFunction({
                emissionContract: emission, curveConfig: abi.encode(FixedEmissionConfig({amount: 100 ether}))
            }),
            shares: _singleShare(10000, address(0), ""),
            allowlistSigner: address(0),
            allowlistDeadline: 0,
            numberOfEpochs: 100,
            totalDistributionAmount: 10_000 ether,
            initialMetadata: new MetadataEntry[](0),
            metadataEditable: true
        });
    }

    function _singleShare(uint256 bps, address hookAddress, bytes memory callData)
        internal
        pure
        returns (Share[] memory)
    {
        Share[] memory shares = new Share[](1);
        shares[0] = Share({shareBps: bps, hook: Hook({contractAddress: hookAddress, callData: callData})});
        return shares;
    }

    function _setupParticipant() internal {
        _setupParticipant(1);
    }

    function _setupParticipant(uint256 numEpochs) internal {
        vm.startPrank(participant);
        participationToken.approve(address(distributor), 10 ether * numEpochs);
        distributor.participate(10 ether, Range({from: 0, length: numEpochs}), participant, new bytes(0));
        vm.stopPrank();
    }

    // --- releaseEpochFunds tests ---

    function _createDistributorWithReleaseHook(address hookAddress) internal returns (DistributorV1) {
        return _createDistributorWithPolicy(ReleasePolicy.Anyone, address(0), hookAddress);
    }

    function _createDistributorWithPolicy(ReleasePolicy _policy, address _factory, address _hookAddress)
        internal
        returns (DistributorV1)
    {
        Share[] memory shares = _singleShare(10000, _hookAddress, "");

        DistributorV1 d = new DistributorV1(
            address(this),
            _factory,
            DistributorConfig({
                distributionToken: address(distributionToken),
                participationToken: address(participationToken),
                epochDuration: epochDuration,
                startTimestamp: startTimestamp,
                minParticipation: 1 ether,
                claimDelaySeconds: claimDelaySeconds,
                allowFutureEpochParticipation: true,
                releasePolicy: _policy,
                emissionFunction: EmissionFunction({
                    emissionContract: emission, curveConfig: abi.encode(FixedEmissionConfig({amount: 100 ether}))
                }),
                shares: shares,
                allowlistSigner: address(0),
                allowlistDeadline: 0,
                numberOfEpochs: 100,
                totalDistributionAmount: 10_000 ether,
                initialMetadata: new MetadataEntry[](0),
                metadataEditable: true
            })
        );
        distributionToken.mint(address(d), 1_000 ether);
        return d;
    }

    function testReleaseFundsOnlyPassedEpochsReleasesOnlyPassedParticipation() public {
        PullingHook pullingHook = new PullingHook(address(participationToken));
        DistributorV1 limited = _createDistributorWithReleaseHook(address(pullingHook));
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
        limited.releaseEpochFunds();

        uint256 epochBalance = 10 ether;
        assertEq(pullingHook.pulled(), epochBalance, "hook gets full epoch 0 amount");
        assertEq(participationToken.balanceOf(address(limited)), 10 ether, "epoch 2 participation remains");
    }

    function testReleaseFundsOnlyPassedEpochsMultiplePassedEpochs() public {
        PullingHook pullingHook = new PullingHook(address(participationToken));
        DistributorV1 limited = _createDistributorWithReleaseHook(address(pullingHook));
        participationToken.mint(participant, 30 ether);

        vm.startPrank(participant);
        participationToken.approve(address(limited), 30 ether);
        limited.participate(10 ether, Range({from: 0, length: 3}), participant, new bytes(0));
        vm.stopPrank();

        vm.warp(startTimestamp + (3 * epochDuration) + claimDelaySeconds);
        assertEq(limited.currentEpoch(), 3);

        vm.prank(participant);
        limited.releaseEpochFunds();

        uint256 epochSum = 30 ether;
        assertEq(pullingHook.pulled(), epochSum, "hook gets all 3 epochs");
        assertEq(participationToken.balanceOf(address(limited)), 0, "all participation released");
    }

    function testReleaseFundsOnlyPassedEpochsNoPassedEpochsReleasesNothing() public {
        PullingHook pullingHook = new PullingHook(address(participationToken));
        DistributorV1 limited = _createDistributorWithReleaseHook(address(pullingHook));
        participationToken.mint(participant, 10 ether);

        vm.startPrank(participant);
        participationToken.approve(address(limited), 10 ether);
        limited.participate(10 ether, Range({from: 1, length: 1}), participant, new bytes(0));
        vm.stopPrank();

        // Still in epoch 0 — no epochs have passed
        assertEq(limited.currentEpoch(), 0);

        vm.expectRevert(bytes("all passed epochs already claimed"));
        limited.releaseEpochFunds();

        assertEq(pullingHook.pulled(), 0, "no epochs passed, hook gets nothing");
        assertEq(participationToken.balanceOf(address(limited)), 10 ether, "all participation remains");
    }

    function testAllowlistSignatureChainIdBindsToChain() public {
        uint256 signerPk = 0xABCD;
        address signer = vm.addr(signerPk);
        uint256 deadline = block.timestamp + epochDuration;

        Share[] memory shares = _singleShare(10000, address(0), "");

        DistributorV1 allowlisted = new DistributorV1(
            address(this),
            address(0),
            DistributorConfig({
                distributionToken: address(distributionToken),
                participationToken: address(participationToken),
                epochDuration: epochDuration,
                startTimestamp: startTimestamp,
                minParticipation: 1 ether,
                claimDelaySeconds: claimDelaySeconds,
                allowFutureEpochParticipation: true,
                releasePolicy: ReleasePolicy.Anyone,
                emissionFunction: EmissionFunction({
                    emissionContract: emission, curveConfig: abi.encode(FixedEmissionConfig({amount: 100 ether}))
                }),
                shares: shares,
                allowlistSigner: signer,
                allowlistDeadline: deadline,
                numberOfEpochs: 100,
                totalDistributionAmount: 10_000 ether,
                initialMetadata: new MetadataEntry[](0),
                metadataEditable: true
            })
        );
        distributionToken.mint(address(allowlisted), 1_000 ether);

        bytes32 message = keccak256(abi.encode(address(allowlisted), participant, block.chainid + 1));
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(message);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(participant);
        participationToken.approve(address(allowlisted), 10 ether);

        vm.prank(participant);
        vm.expectRevert(bytes("not allowlisted"));
        allowlisted.participate(10 ether, Range({from: 0, length: 1}), participant, signature);
    }

    // --- release policy tests ---

    function _participateOneEpochAndWarp(DistributorV1 _d) internal {
        participationToken.mint(participant, 10 ether);
        vm.startPrank(participant);
        participationToken.approve(address(_d), 10 ether);
        _d.participate(10 ether, Range({from: 0, length: 1}), participant, new bytes(0));
        vm.stopPrank();

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);
    }

    function testReleasePolicyAnyoneAnyoneCanRelease() public {
        PullingHook hook = new PullingHook(address(participationToken));
        DistributorV1 d = _createDistributorWithPolicy(ReleasePolicy.Anyone, address(0), address(hook));
        _participateOneEpochAndWarp(d);

        vm.prank(makeAddr("rando"));
        d.releaseEpochFunds();

        assertEq(hook.pulled(), 10 ether);
    }

    function testReleasePolicyFactoryOnlyFactoryCanRelease() public {
        PullingHook hook = new PullingHook(address(participationToken));
        MockFactory mockFactory = new MockFactory(makeAddr("factoryOwner"), makeAddr("operator"));
        DistributorV1 d = _createDistributorWithPolicy(ReleasePolicy.Factory, address(mockFactory), address(hook));
        _participateOneEpochAndWarp(d);

        vm.prank(address(this)); // creator
        vm.expectRevert(bytes("only factory"));
        d.releaseEpochFunds();

        vm.prank(makeAddr("factoryOwner")); // factory owner
        d.releaseEpochFunds();

        assertEq(hook.pulled(), 10 ether);
    }

    function testReleasePolicyFactoryReleaseOperatorCanRelease() public {
        PullingHook hook = new PullingHook(address(participationToken));
        MockFactory mockFactory = new MockFactory(makeAddr("factoryOwner"), makeAddr("operator"));
        DistributorV1 d = _createDistributorWithPolicy(ReleasePolicy.Factory, address(mockFactory), address(hook));
        _participateOneEpochAndWarp(d);

        vm.prank(makeAddr("operator")); // factory's configured release operator
        d.releaseEpochFunds();

        assertEq(hook.pulled(), 10 ether);
    }

    function testReleasePolicyCreatorOnlyCreatorCanRelease() public {
        PullingHook hook = new PullingHook(address(participationToken));
        DistributorV1 d = _createDistributorWithPolicy(ReleasePolicy.Creator, address(0), address(hook));
        _participateOneEpochAndWarp(d);

        vm.prank(makeAddr("rando"));
        vm.expectRevert(bytes("only creator"));
        d.releaseEpochFunds();

        d.releaseEpochFunds(); // creator = this test contract

        assertEq(hook.pulled(), 10 ether);
    }

    function testReleasePolicyCreatorOrFactoryBothCanRelease() public {
        MockFactory mockFactory = new MockFactory(makeAddr("factoryOwner"), makeAddr("operator"));

        PullingHook hook1 = new PullingHook(address(participationToken));
        DistributorV1 d1 =
            _createDistributorWithPolicy(ReleasePolicy.CreatorOrFactory, address(mockFactory), address(hook1));
        PullingHook hook2 = new PullingHook(address(participationToken));
        DistributorV1 d2 =
            _createDistributorWithPolicy(ReleasePolicy.CreatorOrFactory, address(mockFactory), address(hook2));

        // both participate in epoch 0 before warping (deploying after warp would violate startTimestamp >= now)
        participationToken.mint(participant, 20 ether);
        vm.startPrank(participant);
        participationToken.approve(address(d1), 10 ether);
        d1.participate(10 ether, Range({from: 0, length: 1}), participant, new bytes(0));
        participationToken.approve(address(d2), 10 ether);
        d2.participate(10 ether, Range({from: 0, length: 1}), participant, new bytes(0));
        vm.stopPrank();

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);

        vm.prank(makeAddr("rando"));
        vm.expectRevert(bytes("only creator or factory"));
        d1.releaseEpochFunds();

        vm.prank(makeAddr("operator")); // factory side
        d1.releaseEpochFunds();

        assertEq(hook1.pulled(), 10 ether);

        d2.releaseEpochFunds(); // creator = this test contract

        assertEq(hook2.pulled(), 10 ether);
    }

    function testSetReleasePolicyByCreator() public {
        DistributorV1 d = _createDistributorWithPolicy(ReleasePolicy.Creator, address(0), address(0));

        vm.prank(makeAddr("rando"));
        vm.expectRevert(bytes("only creator"));
        d.setReleasePolicy(ReleasePolicy.Anyone);

        vm.expectEmit(true, true, true, true, address(d));
        emit DistributorV1.ReleasePolicySet(address(this), ReleasePolicy.Anyone);
        d.setReleasePolicy(ReleasePolicy.Anyone); // creator = this test contract

        assertEq(uint256(d.RELEASE_POLICY()), uint256(ReleasePolicy.Anyone));
    }

    function testSetReleasePolicyWhenCurrentPolicyIsFactoryOnlyFactoryCanChange() public {
        MockFactory mockFactory = new MockFactory(makeAddr("factoryOwner"), makeAddr("operator"));
        DistributorV1 d = _createDistributorWithPolicy(ReleasePolicy.Factory, address(mockFactory), address(0));

        vm.prank(address(this)); // creator
        vm.expectRevert(bytes("only factory owner"));
        d.setReleasePolicy(ReleasePolicy.Anyone);

        vm.prank(makeAddr("operator")); // release operator cannot change the policy either
        vm.expectRevert(bytes("only factory owner"));
        d.setReleasePolicy(ReleasePolicy.Anyone);

        vm.prank(makeAddr("factoryOwner"));
        d.setReleasePolicy(ReleasePolicy.Creator);

        assertEq(uint256(d.RELEASE_POLICY()), uint256(ReleasePolicy.Creator));
    }

    function testGetContractInfoExposesReleasePolicy() public {
        GetContractInfoResult memory info = distributor.getContractInfo();
        assertEq(uint256(info.releasePolicy), uint256(ReleasePolicy.Anyone));
    }

    // --- releaseEpochFunds reentrancy guard tests (audit L-1 defense-in-depth) ---

    function testReleaseReentrantHookRevertsAndNoFundsMove() public {
        ReentrantHook hook = new ReentrantHook();
        DistributorV1 d = _createDistributorWithReleaseHook(address(hook));
        _participateOneEpochAndWarp(d); // participant holds 10 ether of epoch 0

        hook.setMode(ReentrantHook.Mode.Release);

        // the hook re-enters releaseEpochFunds while the distributor holds an approval to it;
        // the guard must revert the re-entrant call, which bubbles through the hook as
        // HookReverted(ReentrancyGuardReentrantCall) and reverts the whole release
        vm.expectRevert(
            abi.encodeWithSelector(
                HookLib.HookReverted.selector,
                abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
            )
        );
        d.releaseEpochFunds();

        // nothing moved and the release did not consume any epoch
        assertEq(d.nextEpochToRelease(), 0, "nextEpochToRelease must not advance on reverted release");
        assertEq(participationToken.balanceOf(address(d)), 10 ether, "participation tokens must not move");
        assertEq(distributionToken.balanceOf(address(d)), 1_000 ether, "distribution tokens must not move");
        assertEq(participationToken.allowance(address(d), address(hook)), 0, "no dangling allowance");
    }

    function testReleaseReentrantHookCannotReenterParticipate() public {
        ReentrantHook hook = new ReentrantHook();
        DistributorV1 d = _createDistributorWithReleaseHook(address(hook));
        _participateOneEpochAndWarp(d); // participant holds 10 ether of epoch 0

        hook.setMode(ReentrantHook.Mode.Participate);
        d.releaseEpochFunds(); // hook tries to re-enter participate mid-release and fails

        assertEq(hook.reentrantCallBlocked(), true, "re-entrant participate must be blocked");
        assertEq(
            hook.reentrantRevertData(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector),
            "blocked by the reentrancy guard, not another check"
        );

        // the release itself completed normally, exactly once
        assertEq(d.nextEpochToRelease(), 1);
        // the re-entrant participate must not have credited the hook for the current epoch
        assertEq(d.epochUserParticipation(1, address(hook)), 0, "hook must not gain participation mid-release");
        assertEq(participationToken.balanceOf(address(d)), 10 ether, "only epoch 0 participation released");
    }

    function testReleaseReentrantHookCannotReenterClaim() public {
        ReentrantHook hook = new ReentrantHook();
        DistributorV1 d = _createDistributorWithReleaseHook(address(hook));

        // the hook is the sole participant of epoch 0, so without the guard its re-entrant
        // claim mid-release would actually pay out rewards
        participationToken.mint(address(hook), 10 ether);
        vm.startPrank(address(hook));
        participationToken.approve(address(d), 10 ether);
        d.participate(10 ether, Range({from: 0, length: 1}), address(hook), new bytes(0));
        vm.stopPrank();

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);

        hook.setMode(ReentrantHook.Mode.Claim);
        d.releaseEpochFunds(); // hook tries to re-enter claim mid-release and fails

        assertEq(hook.reentrantCallBlocked(), true, "re-entrant claim must be blocked");
        assertEq(
            hook.reentrantRevertData(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector),
            "blocked by the reentrancy guard, not another check"
        );

        // the release itself completed normally, exactly once
        assertEq(d.nextEpochToRelease(), 1);
        // the re-entrant claim must not have paid out rewards mid-release
        assertEq(distributionToken.balanceOf(address(hook)), 0, "hook must not claim rewards mid-release");
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

/// @dev malicious hook that re-enters the distributor from its fallback while the distributor
///      holds an approval to it; `msg.sender` inside the fallback is always the distributor
///      invoking this hook
contract ReentrantHook {
    enum Mode {
        None,
        Release,
        Participate,
        Claim
    }

    Mode public mode;
    bool public reentrantCallBlocked;
    bytes public reentrantRevertData;

    function setMode(Mode _mode) external {
        mode = _mode;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        address d = msg.sender; // the distributor calling this hook
        if (mode == Mode.Release) {
            // let the revert of the re-entrant call propagate to the release caller
            DistributorV1(d).releaseEpochFunds();
        } else if (mode == Mode.Participate) {
            // re-enter participate for the current epoch; without the guard this would pass the
            // entry checks and only fail later on the token allowance, instead of being blocked up front
            uint256 currEpoch = DistributorV1(d).currentEpoch();
            (bool ok, bytes memory ret) = d.call(
                abi.encodeCall(
                    DistributorV1.participate,
                    (10 ether, Range({from: currEpoch, length: 1}), address(this), new bytes(0))
                )
            );
            reentrantCallBlocked = !ok;
            reentrantRevertData = ret;
        } else if (mode == Mode.Claim) {
            // re-enter claim for this hook's own participation (would pay out if unguarded)
            (bool ok, bytes memory ret) =
                d.call(abi.encodeCall(DistributorV1.claim, (address(this), Range({from: 0, length: 1}))));
            reentrantCallBlocked = !ok;
            reentrantRevertData = ret;
        }
        return "";
    }
}

/// @dev minimal factory mock exposing the surface the `Factory` release policy reads
contract MockFactory {
    address public owner;
    address public releaseOperator;

    constructor(address _owner, address _releaseOperator) {
        owner = _owner;
        releaseOperator = _releaseOperator;
    }

    function config() external view returns (uint256, address, uint256) {
        return (0, releaseOperator, 0);
    }
}
