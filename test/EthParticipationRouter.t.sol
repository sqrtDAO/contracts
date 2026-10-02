// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {DistributorV1, DistributorConfig, Range, ReleasePolicy, ParticipateParams} from "../src/v1/DistributorV1.sol";
import {EthParticipationRouter} from "../src/v1/EthParticipationRouter.sol";
import {FixedEmission, FixedEmissionConfig} from "../src/utils/emission-function/FixedEmission.sol";
import {EmissionFunction} from "../src/utils/emission-function/EmissionFunction.sol";
import {Share} from "src/utils/Shares.sol";
import {Hook} from "src/utils/Hook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {MetadataEntry} from "../src/utils/Metadata.sol";
import {WETH9} from "./mocks/WETH9.sol";

contract EthParticipationRouterTest is Test {
    uint256 constant ALLOWLIST_SIGNER_PK = 0xBEEF2;
    EthParticipationRouter public router;
    DistributorV1 public distributor;
    DistributorV1 public allowlistedDistributor;
    ERC20Mock public distributionToken;
    WETH9 public weth;
    FixedEmission public emission;

    uint256 public epochDuration = 100;
    uint256 public claimDelaySeconds = 10;
    uint256 public startTimestamp = 1_000;

    address public user = address(0xAAAA);
    address public userB = address(0xBBBB);

    function setUp() public {
        vm.warp(startTimestamp);

        distributionToken = new ERC20Mock();
        weth = new WETH9();
        emission = new FixedEmission();

        distributionToken.mint(address(this), 2_000 ether);

        router = new EthParticipationRouter(address(weth));

        distributor = new DistributorV1(address(this), address(0), _defaultConfig(address(weth)));

        // allowlisted distributor: signatures cover the recipient (see DistributorV1._verifyAllowlist)
        DistributorConfig memory config = _defaultConfig(address(weth));
        config.allowlistSigner = vm.addr(ALLOWLIST_SIGNER_PK);
        config.allowlistDeadline = block.timestamp + 1_000;
        allowlistedDistributor = new DistributorV1(address(this), address(0), config);

        distributionToken.transfer(address(distributor), 1_000 ether);
        distributionToken.transfer(address(allowlistedDistributor), 1_000 ether);
    }

    // --- participateWithETH ---

    function testParticipateWithETHHappyPath() public {
        uint256 amountPerEpoch = 2 ether;
        Range memory range = Range({from: 0, length: 5});
        uint256 total = 10 ether;
        uint256 testContractEthBefore = address(this).balance;

        router.participateWithETH{value: total}(address(distributor), amountPerEpoch, range, user, "");

        assertEq(weth.balanceOf(address(distributor)), total, "distributor weth");
        assertEq(weth.balanceOf(address(router)), 0, "router weth drained");
        assertEq(address(router).balance, 0, "router eth drained");
        assertEq(weth.allowance(address(router), address(distributor)), 0, "allowance reset");
        assertEq(address(this).balance, testContractEthBefore - total, "eth spent");

        for (uint256 i = 0; i < range.length; i++) {
            assertEq(distributor.epochUserParticipation(range.from + i, user), amountPerEpoch);
            assertEq(distributor.epochTotalParticipation(range.from + i), amountPerEpoch);
            assertEq(distributor.epochUniqueParticipants(range.from + i), 1);
        }
        assertEq(distributor.totalParticipation(), total);
        assertEq(distributor.totalUniqueParticipants(), 1);
    }

    function testParticipateWithETHCreditsRecipientNotSender() public {
        router.participateWithETH{value: 2 ether}(address(distributor), 2 ether, Range({from: 0, length: 1}), user, "");

        assertEq(distributor.epochUserParticipation(0, user), 2 ether);
        assertEq(distributor.epochUserParticipation(0, address(this)), 0);
        assertEq(distributor.totalUniqueParticipants(), 1);
    }

    function testParticipateWithETHEmitsEvent() public {
        vm.deal(userB, 10 ether);
        vm.recordLogs();
        vm.prank(userB);
        router.participateWithETH{value: 2 ether}(address(distributor), 1 ether, Range({from: 3, length: 2}), user, "");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(router)) {
                assertEq(logs[i].topics.length, 4, "3 indexed topics + selector");
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(userB))), "sender");
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(distributor)))), "distributor");
                assertEq(logs[i].topics[3], bytes32(uint256(uint160(user))), "recipient");
                (uint256 fromEpoch, uint256 numEpochs, uint256 amountPerEpoch) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(fromEpoch, 3, "fromEpoch");
                assertEq(numEpochs, 2, "numEpochs");
                assertEq(amountPerEpoch, 1 ether, "amountPerEpoch");
                return;
            }
        }
        revert("ParticipatedWithETH event not emitted");
    }

    function testParticipateWithETHRevertsOnOverpayment() public {
        vm.expectRevert(abi.encodeWithSelector(EthParticipationRouter.IncorrectMsgValue.selector, 2 ether, 2 ether + 1));
        router.participateWithETH{value: 2 ether + 1}(
            address(distributor), 2 ether, Range({from: 0, length: 1}), user, ""
        );
    }

    function testParticipateWithETHRevertsOnUnderpayment() public {
        vm.expectRevert(abi.encodeWithSelector(EthParticipationRouter.IncorrectMsgValue.selector, 5 ether, 4 ether));
        router.participateWithETH{value: 4 ether}(address(distributor), 1 ether, Range({from: 0, length: 5}), user, "");
    }

    function testParticipateWithETHRevertsOnZeroRecipient() public {
        vm.expectRevert(EthParticipationRouter.ZeroRecipient.selector);
        router.participateWithETH{value: 2 ether}(
            address(distributor), 2 ether, Range({from: 0, length: 1}), address(0), ""
        );
    }

    function testParticipateWithETHRevertsOnAllowlistedDistributorWithoutSignature() public {
        // the allowlist is verified over the recipient; without a signature the distributor
        // reverts — even though the router already wrapped and approved, the revert is atomic
        // and nothing is stranded
        (bool success,) = address(router).call{value: 2 ether}(
            abi.encodeCall(
                EthParticipationRouter.participateWithETH,
                (address(allowlistedDistributor), 2 ether, Range({from: 0, length: 1}), user, "")
            )
        );
        assertFalse(success, "router participation must revert without an allowlist signature");
        assertEq(weth.balanceOf(address(router)), 0, "no weth stranded");
        assertEq(weth.allowance(address(router), address(allowlistedDistributor)), 0, "no allowance left");
    }

    function testParticipateWithETHOnAllowlistedDistributorWithSignature() public {
        bytes memory signature = _allowlistSignatureFor(address(allowlistedDistributor), user);
        router.participateWithETH{value: 2 ether}(
            address(allowlistedDistributor), 2 ether, Range({from: 0, length: 1}), user, signature
        );
        assertEq(allowlistedDistributor.epochUserParticipation(0, user), 2 ether);
    }

    function testParticipateWithETHWorksAfterAllowlistDeadline() public {
        vm.warp(startTimestamp + 1_000); // allowlist deadline passed; current epoch is 10
        router.participateWithETH{value: 2 ether}(
            address(allowlistedDistributor), 2 ether, Range({from: 10, length: 1}), user, ""
        );
        assertEq(allowlistedDistributor.epochUserParticipation(10, user), 2 ether);
    }

    function testParticipateWithETHRevertsAtomicallyOnWrongParticipationToken() public {
        // distributor expects a different token: inner transferFrom reverts, whole tx reverts,
        // so the already-wrapped WETH is not stranded in the router
        ERC20Mock otherToken = new ERC20Mock();
        DistributorV1 otherDistributor =
            new DistributorV1(address(this), address(0), _defaultConfig(address(otherToken)));
        distributionToken.mint(address(this), 1_000 ether);
        distributionToken.transfer(address(otherDistributor), 1_000 ether);

        vm.expectRevert();
        router.participateWithETH{value: 2 ether}(
            address(otherDistributor), 2 ether, Range({from: 0, length: 1}), user, ""
        );
        assertEq(weth.balanceOf(address(router)), 0, "no weth stranded");
    }

    function testParticipateWithETHRefundsLeftoverFromPartialPull() public {
        PartialPullDistributorMock partialDistributor = new PartialPullDistributorMock(IERC20(address(weth)));

        router.participateWithETH{value: 10 ether}(
            address(partialDistributor), 2 ether, Range({from: 0, length: 5}), user, ""
        );

        // mock pulled only half of the approved amount, the rest is refunded to the payer
        assertEq(weth.balanceOf(address(partialDistributor)), 5 ether, "mock kept half");
        assertEq(weth.balanceOf(address(router)), 0, "router drained");
        assertEq(weth.balanceOf(address(this)), 5 ether, "leftover refunded to payer");
    }

    function testParticipateWithETHRevertsOnDistributorRevert() public {
        vm.expectRevert(bytes("Amount below minimum"));
        router.participateWithETH{value: 0.5 ether}(
            address(distributor), 0.5 ether, Range({from: 0, length: 1}), user, ""
        );
    }

    // --- participateManyWithETH ---

    function testParticipateManyWithETHHappyPath() public {
        ParticipateParams[] memory params = new ParticipateParams[](2);
        params[0] = ParticipateParams({
            amountPerEpoch: 2 ether, range: Range({from: 0, length: 3}), recipient: user, allowlistSignature: ""
        });
        params[1] = ParticipateParams({
            amountPerEpoch: 1 ether, range: Range({from: 5, length: 2}), recipient: userB, allowlistSignature: ""
        });
        uint256 total = 8 ether; // 2*3 + 1*2

        router.participateManyWithETH{value: total}(address(distributor), params);

        assertEq(weth.balanceOf(address(distributor)), total);
        assertEq(weth.balanceOf(address(router)), 0);
        assertEq(weth.allowance(address(router), address(distributor)), 0);

        assertEq(distributor.epochUserParticipation(0, user), 2 ether);
        assertEq(distributor.epochUserParticipation(2, user), 2 ether);
        assertEq(distributor.epochUserParticipation(5, userB), 1 ether);
        assertEq(distributor.epochUserParticipation(6, userB), 1 ether);
        assertEq(distributor.epochUserParticipation(3, user), 0);
        assertEq(distributor.totalParticipation(), total);
        assertEq(distributor.totalUniqueParticipants(), 2);
    }

    function testParticipateManyWithETHRevertsOnEmptyParams() public {
        ParticipateParams[] memory params = new ParticipateParams[](0);
        vm.expectRevert(EthParticipationRouter.EmptyParams.selector);
        router.participateManyWithETH{value: 0}(address(distributor), params);
    }

    function testParticipateManyWithETHRevertsOnZeroRecipientParam() public {
        ParticipateParams[] memory params = new ParticipateParams[](1);
        params[0] = ParticipateParams({
            amountPerEpoch: 2 ether, range: Range({from: 0, length: 1}), recipient: address(0), allowlistSignature: ""
        });
        vm.expectRevert(EthParticipationRouter.ZeroRecipient.selector);
        router.participateManyWithETH{value: 2 ether}(address(distributor), params);
    }

    function testParticipateManyWithETHRevertsOnIncorrectValue() public {
        ParticipateParams[] memory params = new ParticipateParams[](2);
        params[0] = ParticipateParams({
            amountPerEpoch: 2 ether, range: Range({from: 0, length: 3}), recipient: user, allowlistSignature: ""
        });
        params[1] = ParticipateParams({
            amountPerEpoch: 1 ether, range: Range({from: 5, length: 2}), recipient: userB, allowlistSignature: ""
        });
        vm.expectRevert(abi.encodeWithSelector(EthParticipationRouter.IncorrectMsgValue.selector, 8 ether, 7 ether));
        router.participateManyWithETH{value: 7 ether}(address(distributor), params);
    }

    function testParticipateManyWithETHRevertsOnAllowlistedDistributorWithoutSignature() public {
        ParticipateParams[] memory params = new ParticipateParams[](1);
        params[0] = ParticipateParams({
            amountPerEpoch: 2 ether, range: Range({from: 0, length: 1}), recipient: user, allowlistSignature: ""
        });
        vm.expectRevert(bytes("not allowlisted"));
        router.participateManyWithETH{value: 2 ether}(address(allowlistedDistributor), params);
    }

    function testParticipateManyWithETHOnAllowlistedDistributorWithSignature() public {
        ParticipateParams[] memory params = new ParticipateParams[](2);
        params[0] = ParticipateParams({
            amountPerEpoch: 2 ether,
            range: Range({from: 0, length: 1}),
            recipient: user,
            allowlistSignature: _allowlistSignatureFor(address(allowlistedDistributor), user)
        });
        params[1] = ParticipateParams({
            amountPerEpoch: 1 ether,
            range: Range({from: 1, length: 1}),
            recipient: userB,
            allowlistSignature: _allowlistSignatureFor(address(allowlistedDistributor), userB)
        });
        router.participateManyWithETH{value: 3 ether}(address(allowlistedDistributor), params);

        assertEq(allowlistedDistributor.epochUserParticipation(0, user), 2 ether);
        assertEq(allowlistedDistributor.epochUserParticipation(1, userB), 1 ether);
        assertEq(allowlistedDistributor.totalUniqueParticipants(), 2);
    }

    // --- misc ---

    function testDirectETHTransferToRouterReverts() public {
        (bool success,) = address(router).call{value: 1 ether}("");
        assertFalse(success, "plain ETH send should revert (no receive/fallback)");
        assertEq(address(router).balance, 0);
    }

    function testSweepETH() public {
        vm.deal(address(router), 1 ether); // simulates ETH forced in (e.g. via selfdestruct)
        router.sweepETH(payable(user));
        assertEq(address(router).balance, 0);
        assertEq(user.balance, 1 ether);
    }

    function testConstructorRevertsOnZeroWeth() public {
        vm.expectRevert(EthParticipationRouter.ZeroWeth.selector);
        new EthParticipationRouter(address(0));
    }

    // --- end to end: participate -> release -> claim ---

    function testEndToEndParticipateReleaseClaim() public {
        PullingHook hook = new PullingHook(address(weth));
        DistributorConfig memory config = _defaultConfig(address(weth));
        config.shares = _singleShare(10000, address(hook), "");
        DistributorV1 hookDistributor = new DistributorV1(address(this), address(0), config);
        distributionToken.mint(address(this), 1_000 ether);
        distributionToken.transfer(address(hookDistributor), 1_000 ether);

        uint256 amountPerEpoch = 10 ether;
        router.participateWithETH{value: 10 ether}(
            address(hookDistributor), amountPerEpoch, Range({from: 0, length: 1}), user, ""
        );

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);
        hookDistributor.releaseEpochFunds();

        // single 100% share: the epoch's participation funds are pulled by the hook
        assertEq(weth.balanceOf(address(hook)), 10 ether, "participation funds released to hook");
        assertEq(weth.balanceOf(address(hookDistributor)), 0);

        hookDistributor.claim(user, Range({from: 0, length: 1}));
        // single participant of epoch 0 with a fixed 100 ether reward per epoch
        assertEq(distributionToken.balanceOf(user), 100 ether);
    }

    function testEndToEndParticipateManyReleaseClaim() public {
        ParticipateParams[] memory params = new ParticipateParams[](2);
        params[0] = ParticipateParams({
            amountPerEpoch: 3 ether, range: Range({from: 0, length: 1}), recipient: user, allowlistSignature: ""
        });
        params[1] = ParticipateParams({
            amountPerEpoch: 1 ether, range: Range({from: 0, length: 1}), recipient: userB, allowlistSignature: ""
        });
        router.participateManyWithETH{value: 4 ether}(address(distributor), params);

        vm.warp(startTimestamp + epochDuration + claimDelaySeconds);
        distributor.releaseEpochFunds();

        distributor.claim(user, Range({from: 0, length: 1}));
        distributor.claim(userB, Range({from: 0, length: 1}));

        // pro-rata: 3/4 and 1/4 of the 100 ether epoch reward
        assertEq(distributionToken.balanceOf(user), 75 ether);
        assertEq(distributionToken.balanceOf(userB), 25 ether);
    }

    // --- helpers ---

    function _defaultConfig(address _participationToken) internal view returns (DistributorConfig memory) {
        return DistributorConfig({
            distributionToken: address(distributionToken),
            participationToken: _participationToken,
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

    /// @dev signature signed by the allowlisted distributor's signer over the recipient
    function _allowlistSignatureFor(address _distributor, address _recipient) internal view returns (bytes memory) {
        bytes32 message = keccak256(abi.encode(_distributor, _recipient, block.chainid));
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(message);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ALLOWLIST_SIGNER_PK, digest);
        return abi.encodePacked(r, s, v);
    }
}

/// @notice mock distributor that only pulls half of its allowance — used to exercise the
///         leftover-refund path of the router
contract PartialPullDistributorMock {
    IERC20 public immutable TOKEN;

    constructor(IERC20 _token) {
        TOKEN = _token;
    }

    function participate(uint256, Range calldata, address, bytes calldata) external {
        uint256 amount = TOKEN.allowance(msg.sender, address(this));
        TOKEN.transferFrom(msg.sender, address(this), amount / 2);
    }

    function participateMany(ParticipateParams[] calldata) external {}
}

/// @dev hook that pulls its whole allowance from the caller (mirrors `PullingHook` in
///      `DistributorV1.t.sol`) — used to verify released participation funds actually move
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
