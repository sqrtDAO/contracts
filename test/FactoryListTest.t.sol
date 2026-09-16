// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {FactoryV1} from "../src/v1/FactoryV1.sol";
import {TokenV1Factory} from "../src/v1/TokenV1Factory.sol";
import {DistributionV1Factory, AddressAndDistributionInfo} from "../src/v1/DistributionV1Factory.sol";
import {GetContractInfoResult, DistributorConfig} from "../src/v1/DistributorV1.sol";
import {FixedEmission, FixedEmissionConfig} from "../src/utils/emission-function/FixedEmission.sol";
import {EmissionFunction} from "../src/utils/emission-function/EmissionFunction.sol";
import {Share} from "src/utils/Shares.sol";
import {Hook} from "src/utils/Hook.sol";
import {Allocation} from "../src/v1/TokenV1.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {TransferToHook} from "src/utils/hooks/TransferToHook.sol";
import {BuyAndBurnHookV3} from "src/utils/hooks/BuyAndBurnHookV3.sol";
import {INonfungiblePositionManager} from "../src/external-interfaces/INonfungiblePositionManager.sol";
import {IPermit2} from "../src/external-interfaces/IPermit2.sol";

contract FactoryListTest is Test {
    FactoryV1 public factory;
    TokenV1Factory public tokenFactory;
    DistributionV1Factory public distributorFactory;

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

        distributionToken.mint(user, 1_000 ether);

        tokenFactory = new TokenV1Factory();
        distributorFactory = new DistributionV1Factory();

        factory = new FactoryV1(
            owner,
            0,
            new TransferToHook(),
            new BuyAndBurnHookV3(address(0x0)),
            INonfungiblePositionManager(address(0x1)),
            IPermit2(address(0x2)),
            tokenFactory,
            distributorFactory
        );
    }

    function _createToken() internal returns (address) {
        Allocation[] memory allocs = new Allocation[](1);
        allocs[0] = Allocation({recipient: address(this), amount: 1 ether});
        return factory.createToken("T", "T", allocs);
    }

    function _createDistributor(uint256 totalAmount) internal returns (address) {
        return _createDistributorWithToken(address(distributionToken), totalAmount, true);
    }

    function _createDistributorWithToken(address token, uint256 totalAmount, bool pullIn) internal returns (address) {
        Share[] memory shares = new Share[](1);
        shares[0] = Share({shareBps: 10000, hook: Hook({contractAddress: address(0), callData: ""})});

        DistributorConfig memory config = DistributorConfig({
            distributionToken: token,
            participationToken: address(participationToken),
            epochDuration: epochDuration,
            startTimestamp: startTimestamp,
            minParticipation: 1 ether,
            claimDelaySeconds: claimDelaySeconds,
            allowFutureEpochParticipation: true,
            emissionFunction: EmissionFunction({
                // 100 epochs of 1 ether = 100 ether, callers pass totalAmount >= 100 ether
                emissionContract: emission,
                curveConfig: abi.encode(FixedEmissionConfig({amount: 1 ether}))
            }),
            shares: shares,
            allowlistSigner: address(0),
            allowlistDeadline: 0,
            numberOfEpochs: 100,
            totalDistributionAmount: totalAmount
        });

        vm.startPrank(user);
        if (pullIn) IERC20(token).approve(address(factory), totalAmount);
        address distributor = factory.createDistributor(config, pullIn);
        vm.stopPrank();

        return distributor;
    }

    // ---------- getTokens ----------

    function testGetTokensEmptyList() public view {
        assertEq(tokenFactory.tokenListLength(), 0);
        address[] memory tokens = tokenFactory.getTokens(0, 0);
        assertEq(tokens.length, 0);
    }

    function testGetTokensRevertsOnEmptyList() public {
        vm.expectRevert("out of scope");
        tokenFactory.getTokens(0, 1);
    }

    function testGetTokensReturnsAllInCreationOrder() public {
        address t1 = _createToken();
        address t2 = _createToken();
        address t3 = _createToken();

        assertEq(tokenFactory.tokenListLength(), 3);

        address[] memory tokens = tokenFactory.getTokens(0, 3);
        assertEq(tokens.length, 3);
        assertEq(tokens[0], t1);
        assertEq(tokens[1], t2);
        assertEq(tokens[2], t3);
    }

    function testGetTokensWithNonZeroOffset() public {
        _createToken();
        address t2 = _createToken();
        address t3 = _createToken();

        address[] memory tokens = tokenFactory.getTokens(1, 2);
        assertEq(tokens.length, 2);
        assertEq(tokens[0], t2);
        assertEq(tokens[1], t3);

        tokens = tokenFactory.getTokens(2, 1);
        assertEq(tokens.length, 1);
        assertEq(tokens[0], t3);

        tokens = tokenFactory.getTokens(1, 1);
        assertEq(tokens[0], t2);
    }

    function testGetTokensPartialRange() public {
        _createToken();
        _createToken();
        _createToken();

        // offset + size < length
        address[] memory tokens = tokenFactory.getTokens(0, 2);
        assertEq(tokens.length, 2);
    }

    function testGetTokensRevertsOutOfScope() public {
        _createToken();
        _createToken();

        // offset + size > length
        vm.expectRevert("out of scope");
        tokenFactory.getTokens(1, 2);

        // offset == length with non-zero size
        vm.expectRevert("out of scope");
        tokenFactory.getTokens(2, 1);

        // offset > length
        vm.expectRevert("out of scope");
        tokenFactory.getTokens(3, 1);
    }

    function testGetTokensRevertsOnOverflow() public {
        _createToken();

        // old implementation would panic on _offset + _size overflow instead of reverting "out of scope"
        vm.expectRevert("out of scope");
        tokenFactory.getTokens(type(uint256).max, 1);
    }

    function testGetTokensFullListAndLengthMatch() public {
        for (uint256 i = 0; i < 5; i++) {
            _createToken();
        }

        address[] memory tokens = tokenFactory.getTokens(0, 5);
        assertEq(tokens.length, tokenFactory.tokenListLength());
        assertEq(tokenFactory.tokenListLength(), 5);
    }

    // ---------- getDistributionsInfo ----------

    function testGetDistributionsInfoEmptyList() public view {
        assertEq(distributorFactory.distributionListLength(), 0);
        AddressAndDistributionInfo[] memory result = distributorFactory.getDistributionsInfo(0, 0);
        assertEq(result.length, 0);
    }

    function testGetDistributionsInfoRevertsOnEmptyList() public {
        vm.expectRevert("out of scope");
        distributorFactory.getDistributionsInfo(0, 1);
    }

    function testGetDistributionsInfoReturnsAllInCreationOrder() public {
        address d1 = _createDistributor(100 ether);
        address d2 = _createDistributor(200 ether);

        assertEq(distributorFactory.distributionListLength(), 2);

        AddressAndDistributionInfo[] memory result = distributorFactory.getDistributionsInfo(0, 2);
        assertEq(result.length, 2);
        assertEq(result[0].addr, d1);
        assertEq(result[1].addr, d2);
    }

    function testGetDistributionsInfoFields() public {
        _createDistributor(100 ether);

        AddressAndDistributionInfo[] memory result = distributorFactory.getDistributionsInfo(0, 1);
        GetContractInfoResult memory info = result[0].info;

        assertEq(info.distributionToken, address(distributionToken));
        assertEq(info.participationToken, address(participationToken));
        assertEq(info.epochDuration, epochDuration);
        assertEq(info.startingTimestamp, startTimestamp);
        assertEq(info.minParticipation, 1 ether);
        assertEq(info.claimDelaySeconds, claimDelaySeconds);
        assertEq(info.numberOfEpochs, 100);
        assertEq(info.totalDistributionAmount, 100 ether);
        assertEq(info.remainingRewards, 100 ether); // funded by the factory pull-in
        assertEq(info.creator, user);
        assertEq(info.totalUniqueParticipants, 0);
        assertEq(info.shares.length, 2); // user share + injected protocol fee share
        assertEq(info.shares[0].shareBps, 10000);
        assertEq(info.shares[1].shareBps, 0);
    }

    function testGetDistributionsInfoWithNonZeroOffset() public {
        _createDistributor(100 ether);
        address d2 = _createDistributor(200 ether);
        address d3 = _createDistributor(300 ether);

        AddressAndDistributionInfo[] memory result = distributorFactory.getDistributionsInfo(1, 2);
        assertEq(result.length, 2);
        assertEq(result[0].addr, d2);
        assertEq(result[0].info.totalDistributionAmount, 200 ether);
        assertEq(result[1].addr, d3);
        assertEq(result[1].info.totalDistributionAmount, 300 ether);

        result = distributorFactory.getDistributionsInfo(2, 1);
        assertEq(result[0].addr, d3);
    }

    function testGetDistributionsInfoRevertsOutOfScope() public {
        _createDistributor(100 ether);

        vm.expectRevert("out of scope");
        distributorFactory.getDistributionsInfo(1, 1);

        vm.expectRevert("out of scope");
        distributorFactory.getDistributionsInfo(2, 1);
    }

    function testListsTrackTokensAndDistributorsIndependently() public {
        _createToken();
        _createToken();
        _createDistributor(100 ether);

        assertEq(tokenFactory.tokenListLength(), 2);
        assertEq(distributorFactory.distributionListLength(), 1);

        address[] memory tokens = tokenFactory.getTokens(0, 2);
        assertEq(tokens.length, 2);

        AddressAndDistributionInfo[] memory dists = distributorFactory.getDistributionsInfo(0, 1);
        assertEq(dists.length, 1);
    }

    // ---------- creatorOf ----------

    function testCreatorOfTokenRecordsCaller() public {
        Allocation[] memory allocs = new Allocation[](1);
        allocs[0] = Allocation({recipient: address(this), amount: 1 ether});

        vm.prank(user);
        address token = factory.createToken("T", "T", allocs);

        assertEq(tokenFactory.creatorOf(token), user);
    }

    function testCreatorOfDistributorRecordsCaller() public {
        address distributor = _createDistributor(100 ether);
        assertEq(distributorFactory.creatorOf(distributor), user);
    }
}
