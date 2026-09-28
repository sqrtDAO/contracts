// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {FactoryConfig, FactoryV1} from "../src/v1/FactoryV1.sol";
import {TokenV1Factory} from "../src/v1/TokenV1Factory.sol";
import {DistributionV1Factory} from "../src/v1/DistributionV1Factory.sol";
import {INonfungiblePositionManager} from "../src/external-interfaces/INonfungiblePositionManager.sol";
import {IPermit2} from "../src/external-interfaces/IPermit2.sol";
import {DistributorV1, DistributorConfig, Range, ReleasePolicy} from "../src/v1/DistributorV1.sol";
import {FixedEmission, FixedEmissionConfig} from "../src/utils/emission-function/FixedEmission.sol";
import {EmissionFunction} from "../src/utils/emission-function/EmissionFunction.sol";
import {Share} from "src/utils/Shares.sol";
import {Hook} from "src/utils/Hook.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
        return _createDistributor(feeBps, participationAmount, ReleasePolicy.Anyone, address(0));
    }

    function _createDistributor(
        uint256 feeBps,
        uint256 participationAmount,
        ReleasePolicy _releasePolicy,
        address _hookAddress
    ) internal returns (address) {
        // preserve the current release operator — setConfig replaces the whole config
        (, address currentOperator) = factory.config();
        vm.prank(owner);
        factory.setConfig(FactoryConfig({protocolFeeBps: feeBps, releaseOperator: currentOperator}));

        // user shares must sum to (10000 - feeBps) — factory injects the protocol fee share
        Share[] memory shares = new Share[](1);
        shares[0] = Share({shareBps: 10000 - feeBps, hook: Hook({contractAddress: _hookAddress, callData: ""})});

        DistributorConfig memory config = DistributorConfig({
            distributionToken: address(distributionToken),
            participationToken: address(participationToken),
            epochDuration: epochDuration,
            startTimestamp: startTimestamp,
            minParticipation: 1 ether,
            claimDelaySeconds: claimDelaySeconds,
            allowFutureEpochParticipation: true,
            releasePolicy: _releasePolicy,
            emissionFunction: EmissionFunction({
                emissionContract: emission, curveConfig: abi.encode(FixedEmissionConfig({amount: 100 ether}))
            }),
            shares: shares,
            allowlistSigner: address(0),
            allowlistDeadline: 0,
            numberOfEpochs: 100,
            totalDistributionAmount: 10_000 ether
        });

        vm.prank(user);
        participationToken.approve(address(factory), participationAmount);

        // factory pulls totalDistributionAmount from the user
        distributionToken.mint(user, 10_000 ether);
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

    function testRevertNonOwnerSetConfig() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        factory.setConfig(FactoryConfig({protocolFeeBps: 99, releaseOperator: address(0)}));
    }

    function testSweepTokens() public {
        // mint some tokens to factory
        ERC20Mock token = new ERC20Mock();
        token.mint(address(factory), 500 ether);

        address recipient = address(0xFACE);
        vm.prank(owner);
        factory.sweepToken(address(token), recipient);

        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(recipient), 500 ether);
    }

    function testRevertSweepNonOwner() public {
        ERC20Mock token = new ERC20Mock();
        token.mint(address(factory), 500 ether);

        vm.prank(address(0xDEAD));
        vm.expectRevert();
        factory.sweepToken(address(token), address(0xDEAD));
    }

    // --- distributor release tests ---

    function _participateOneEpochAndWarp(address _distributorAddr) internal {
        DistributorV1 distributor = DistributorV1(_distributorAddr);

        vm.startPrank(user);
        participationToken.approve(_distributorAddr, 10 ether);
        distributor.participate(10 ether, Range({from: 0, length: 1}), user, new bytes(0));
        vm.stopPrank();

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);
    }

    function testReleaseEpochFundsByOwner() public {
        PullingHook hook = new PullingHook(address(participationToken));
        address distributorAddr = _createDistributor(0, 10 ether, ReleasePolicy.Factory, address(hook));
        _participateOneEpochAndWarp(distributorAddr);

        // factory owner calls the distributor directly — the distributor resolves the factory's owner itself
        vm.prank(owner);
        DistributorV1(distributorAddr).releaseEpochFunds();

        assertEq(DistributorV1(distributorAddr).nextEpochToRelease(), 1);
        assertEq(hook.pulled(), 10 ether);
    }

    function testReleaseEpochFundsByOperator() public {
        PullingHook hook = new PullingHook(address(participationToken));
        address distributorAddr = _createDistributor(0, 10 ether, ReleasePolicy.Factory, address(hook));
        _participateOneEpochAndWarp(distributorAddr);

        address releaseOperator = makeAddr("operator");
        // preserve the current fee — setConfig replaces the whole config
        (uint256 currentFeeBps,) = factory.config();
        vm.prank(owner);
        factory.setConfig(FactoryConfig({protocolFeeBps: currentFeeBps, releaseOperator: releaseOperator}));

        // operator calls the distributor directly — the distributor reads config().releaseOperator itself
        vm.prank(releaseOperator);
        DistributorV1(distributorAddr).releaseEpochFunds();

        assertEq(DistributorV1(distributorAddr).nextEpochToRelease(), 1);
        assertEq(hook.pulled(), 10 ether);
    }

    function testRevertReleaseEpochFundsForOthers() public {
        address distributorAddr = _createDistributor(0, 10 ether, ReleasePolicy.Factory, address(0));
        _participateOneEpochAndWarp(distributorAddr);

        vm.prank(address(0xDEAD));
        vm.expectRevert(bytes("only factory"));
        DistributorV1(distributorAddr).releaseEpochFunds();
    }

    function testSetConfigOnlyOwner() public {
        FactoryConfig memory newConfig = FactoryConfig({protocolFeeBps: 100, releaseOperator: makeAddr("operator")});

        vm.prank(address(0xDEAD));
        vm.expectRevert();
        factory.setConfig(newConfig);

        vm.prank(owner);
        factory.setConfig(newConfig);

        (uint256 feeBps, address releaseOperator) = factory.config();
        assertEq(feeBps, 100);
        assertEq(releaseOperator, newConfig.releaseOperator);
    }

    function testSetReleasePolicyByFactoryOwner() public {
        address distributorAddr = _createDistributor(0, 10 ether, ReleasePolicy.Factory, address(0));

        // while the policy is `Factory` only the factory owner can change it — not even the release operator
        vm.prank(address(0xDEAD));
        vm.expectRevert(bytes("only factory owner"));
        DistributorV1(distributorAddr).setReleasePolicy(ReleasePolicy.Anyone);

        vm.prank(owner);
        DistributorV1(distributorAddr).setReleasePolicy(ReleasePolicy.Anyone);

        assertEq(uint256(DistributorV1(distributorAddr).RELEASE_POLICY()), uint256(ReleasePolicy.Anyone));
    }
}

/// @dev pulls its whole allowance when called by the distributor (mimics DistributorV1.t.sol PullingHook)
contract PullingHook {
    uint256 public pulled;
    address public token;

    constructor(address _token) {
        token = _token;
    }

    fallback() external {
        uint256 allowance = IERC20(token).allowance(msg.sender, address(this));
        IERC20(token).transferFrom(msg.sender, address(this), allowance);
        pulled += allowance;
    }
}
