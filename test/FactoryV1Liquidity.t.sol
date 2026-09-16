// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Permit2Data, FactoryV1} from "../src/v1/FactoryV1.sol";
import {TokenV1, Allocation} from "../src/v1/TokenV1.sol";
import {TokenV1Factory} from "../src/v1/TokenV1Factory.sol";
import {DistributionV1Factory} from "../src/v1/DistributionV1Factory.sol";
import {IPermit2} from "../src/external-interfaces/IPermit2.sol";
import {INonfungiblePositionManager, MintParams} from "../src/external-interfaces/INonfungiblePositionManager.sol";
import {DistributorV1, DistributorConfig} from "../src/v1/DistributorV1.sol";
import {FixedEmission, FixedEmissionConfig} from "../src/utils/emission-function/FixedEmission.sol";
import {EmissionFunction} from "../src/utils/emission-function/EmissionFunction.sol";
import {Share} from "src/utils/Shares.sol";
import {Hook} from "src/utils/Hook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {TransferToHook} from "src/utils/hooks/TransferToHook.sol";
import {BuyAndBurnHookV3} from "src/utils/hooks/BuyAndBurnHookV3.sol";

contract FactoryV1LiquidityTest is Test {
    FactoryV1 public factory;
    MockPermit2 public mockPermit2;
    MockPositionManager public mockPositionManager;
    ERC20Mock public participationToken;
    ERC20Mock public distributionToken;
    FixedEmission public emission;

    address public owner = address(0xCAFE);
    address public user = address(0x1234);

    uint256 public epochDuration = 100;
    uint256 public claimDelaySeconds = 10;
    uint256 public startTimestamp = 1_000;
    uint160 public constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // price 1.0

    function setUp() public {
        vm.warp(startTimestamp);

        participationToken = new ERC20Mock();
        distributionToken = new ERC20Mock();
        emission = new FixedEmission();
        mockPermit2 = new MockPermit2();
        mockPositionManager = new MockPositionManager();

        factory = new FactoryV1(
            owner,
            0, // protocolFeeBps = 0 for simpler share math
            new TransferToHook(),
            new BuyAndBurnHookV3(address(0x0)),
            INonfungiblePositionManager(address(mockPositionManager)),
            IPermit2(address(mockPermit2)),
            new TokenV1Factory(),
            new DistributionV1Factory()
        );
    }

    /// @dev Builds a DistributorConfig. Caller must set shares to sum to (10000 - buyBackAndBurnShareBps)
    /// because the factory force-injects protocol fee (0 here) and optional buy&burn share.
    function _buildConfig(uint256 totalDistribution, uint256 buyBackAndBurnShareBps)
        internal
        view
        returns (DistributorConfig memory config)
    {
        Share[] memory shares = new Share[](1);
        shares[0] =
            Share({shareBps: 10000 - buyBackAndBurnShareBps, hook: Hook({contractAddress: address(0), callData: ""})});

        config = DistributorConfig({
            distributionToken: address(0), // overwritten by factory
            participationToken: address(participationToken),
            epochDuration: epochDuration,
            startTimestamp: startTimestamp,
            minParticipation: 1 ether,
            claimDelaySeconds: claimDelaySeconds,
            allowFutureEpochParticipation: true,
            emissionFunction: EmissionFunction({
                // 100 epochs of 1 ether = 100 ether, matches totalDistribution passed by callers
                emissionContract: emission,
                curveConfig: abi.encode(FixedEmissionConfig({amount: 1 ether}))
            }),
            shares: shares,
            allowlistSigner: address(0),
            allowlistDeadline: 0,
            numberOfEpochs: 100,
            totalDistributionAmount: totalDistribution
        });
    }

    function _emptyPermit2() internal pure returns (Permit2Data memory) {
        return Permit2Data({
            permit: IPermit2.PermitTransferFrom({
                permitted: IPermit2.TokenPermissions({token: address(0), amount: 0}), nonce: 0, deadline: 0
            }),
            signature: ""
        });
    }

    function _participationPermit2(uint256 amount) internal view returns (Permit2Data memory) {
        return Permit2Data({
            permit: IPermit2.PermitTransferFrom({
                permitted: IPermit2.TokenPermissions({token: address(participationToken), amount: amount}),
                nonce: 0,
                deadline: type(uint256).max
            }),
            signature: hex"01" // non-empty so factory uses the permit2 path; mock ignores the signature
        });
    }

    function _distributionPermit2(uint256 amount) internal view returns (Permit2Data memory) {
        return Permit2Data({
            permit: IPermit2.PermitTransferFrom({
                permitted: IPermit2.TokenPermissions({token: address(distributionToken), amount: amount}),
                nonce: 0,
                deadline: type(uint256).max
            }),
            signature: hex"01"
        });
    }

    /// @dev Runs createTokenAndLiquidityAndDistribution end-to-end.
    /// usePermit2 pulls the participation token via Permit2 signature instead of allowance.
    function _createTokenAndLiquidityAndDistribution(bool usePermit2, uint256 buyBackAndBurnShareBps)
        internal
        returns (address token, address distributor)
    {
        uint256 participationAmount = 100 ether;
        uint256 distributionTokenAmountDesired = 50 ether;
        uint256 totalDistribution = 100 ether;

        participationToken.mint(user, participationAmount);

        // Factory must hold (distributionTokenAmountDesired + totalDistribution) of the new token.
        Allocation[] memory allocations = new Allocation[](1);
        allocations[0] =
            Allocation({recipient: address(factory), amount: distributionTokenAmountDesired + totalDistribution});

        DistributorConfig memory config = _buildConfig(totalDistribution, buyBackAndBurnShareBps);

        Permit2Data memory participationPermit2 = _emptyPermit2();

        if (usePermit2) {
            vm.prank(user);
            participationToken.approve(address(mockPermit2), participationAmount);
            participationPermit2 = _participationPermit2(participationAmount);
        } else {
            vm.prank(user);
            participationToken.approve(address(factory), participationAmount);
        }

        vm.prank(user);
        (token, distributor) = factory.createTokenAndLiquidityAndDistribution(
            "TestToken",
            "TST",
            allocations,
            SQRT_PRICE_1_1,
            participationAmount,
            distributionTokenAmountDesired,
            config,
            buyBackAndBurnShareBps,
            participationPermit2
        );
    }

    // --- Tests ---

    function testCreateTokenAndLiquidityAndDistributionWithAllowance() public {
        (address token, address distributor) = _createTokenAndLiquidityAndDistribution(false, 0);

        // participation token fully consumed into LP (held by mock position manager)
        assertEq(participationToken.balanceOf(user), 0);
        assertEq(participationToken.balanceOf(address(factory)), 0);
        assertEq(participationToken.balanceOf(address(mockPositionManager)), 100 ether);

        // new token: 50 ether into LP, 100 ether into distributor
        assertEq(TokenV1(token).totalSupply(), 150 ether);
        assertEq(TokenV1(token).balanceOf(address(factory)), 0);
        assertEq(TokenV1(token).balanceOf(address(mockPositionManager)), 50 ether);
        assertEq(TokenV1(token).balanceOf(distributor), 100 ether);
    }

    function testCreateTokenAndLiquidityAndDistributionWithPermit2() public {
        (address token, address distributor) = _createTokenAndLiquidityAndDistribution(true, 0);

        // Same final state as the allowance path.
        assertEq(participationToken.balanceOf(user), 0);
        assertEq(participationToken.balanceOf(address(factory)), 0);
        assertEq(participationToken.balanceOf(address(mockPositionManager)), 100 ether);

        assertEq(TokenV1(token).totalSupply(), 150 ether);
        assertEq(TokenV1(token).balanceOf(address(factory)), 0);
        assertEq(TokenV1(token).balanceOf(address(mockPositionManager)), 50 ether);
        assertEq(TokenV1(token).balanceOf(distributor), 100 ether);
    }

    function testCreateTokenAndLiquidityAndDistributionWithPermit2AndBuyBurn() public {
        uint256 buyBackAndBurnShareBps = 500;
        (address token, address distributor) = _createTokenAndLiquidityAndDistribution(true, buyBackAndBurnShareBps);

        // user share 9500, injected buy&burn 500, injected protocol fee 0
        DistributorV1 d = DistributorV1(distributor);
        (uint256 userBps,) = d.shares(0);
        (uint256 bbBps, Hook memory bbHook) = d.shares(1);

        assertEq(userBps, 10000 - buyBackAndBurnShareBps);
        assertEq(bbBps, buyBackAndBurnShareBps);
        assertEq(bbHook.contractAddress, address(factory.BUY_AND_BURN_HOOK()));

        // token movement still correct
        assertEq(TokenV1(token).balanceOf(distributor), 100 ether);
    }

    function testCreateTokenAndLiquidityAndDistributionRevertsWithoutApproval() public {
        uint256 participationAmount = 100 ether;
        uint256 distributionTokenAmountDesired = 50 ether;
        uint256 totalDistribution = 100 ether;

        participationToken.mint(user, participationAmount);

        Allocation[] memory allocations = new Allocation[](1);
        allocations[0] =
            Allocation({recipient: address(factory), amount: distributionTokenAmountDesired + totalDistribution});

        DistributorConfig memory config = _buildConfig(totalDistribution, 0);

        // no approval given to factory -> allowance path must revert
        vm.prank(user);
        vm.expectRevert();
        factory.createTokenAndLiquidityAndDistribution(
            "TestToken",
            "TST",
            allocations,
            SQRT_PRICE_1_1,
            participationAmount,
            distributionTokenAmountDesired,
            config,
            0,
            _emptyPermit2()
        );
    }

    /// @dev Exercises the distribution-token permit2 path, which createTokenAndLiquidityAndDistribution
    /// does not cover because it always uses _pullIn = false.
    function testCreatePoolAndAddLiquidityWithPermit2PullsBothTokens() public {
        uint256 amount0 = 100 ether;
        uint256 amount1 = 50 ether;

        participationToken.mint(user, amount0);
        distributionToken.mint(user, amount1);

        vm.startPrank(user);
        participationToken.approve(address(mockPermit2), amount0);
        distributionToken.approve(address(mockPermit2), amount1);
        vm.stopPrank();

        vm.prank(user);
        factory.createPoolAndAddLiquidity(
            address(participationToken),
            address(distributionToken),
            SQRT_PRICE_1_1,
            amount0,
            amount1,
            true, // _pullIn: pull distribution token too
            _participationPermit2(amount0),
            _distributionPermit2(amount1)
        );

        assertEq(participationToken.balanceOf(user), 0);
        assertEq(distributionToken.balanceOf(user), 0);
        assertEq(participationToken.balanceOf(address(mockPositionManager)), amount0);
        assertEq(distributionToken.balanceOf(address(mockPositionManager)), amount1);
    }

    /// @dev Exercises the partial-pull path: the position manager consumes less than desired,
    ///      the factory refunds the leftover to the user, and the unused allowance to the
    ///      position manager is reset to zero.
    function testCreatePoolAndAddLiquidityResetsLeftoverApprovals() public {
        MockPositionManagerPartial partialManager = new MockPositionManagerPartial();
        FactoryV1 partialFactory = new FactoryV1(
            owner,
            0,
            new TransferToHook(),
            new BuyAndBurnHookV3(address(0x0)),
            INonfungiblePositionManager(address(partialManager)),
            IPermit2(address(mockPermit2)),
            new TokenV1Factory(),
            new DistributionV1Factory()
        );

        uint256 amount0 = 100 ether;
        uint256 amount1 = 50 ether;

        participationToken.mint(user, amount0);
        distributionToken.mint(user, amount1);

        vm.startPrank(user);
        participationToken.approve(address(partialFactory), amount0);
        distributionToken.approve(address(mockPermit2), amount1);
        partialFactory.createPoolAndAddLiquidity(
            address(participationToken),
            address(distributionToken),
            SQRT_PRICE_1_1,
            amount0,
            amount1,
            true, // _pullIn: pull distribution token too (permit2 path)
            _emptyPermit2(),
            _distributionPermit2(amount1)
        );
        vm.stopPrank();

        // token0 consumes desired - 10 ether, token1 consumes desired - 5 ether;
        // the factory refunds each leftover to the user
        bool participationIsToken0 = address(participationToken) < address(distributionToken);
        uint256 participationLeftover = participationIsToken0 ? 10 ether : 5 ether;
        uint256 distributionLeftover = participationIsToken0 ? 5 ether : 10 ether;
        assertEq(participationToken.balanceOf(user), participationLeftover);
        assertEq(distributionToken.balanceOf(user), distributionLeftover);

        // unused allowances to the position manager were reset to zero
        assertEq(participationToken.allowance(address(partialFactory), address(partialManager)), 0);
        assertEq(distributionToken.allowance(address(partialFactory), address(partialManager)), 0);
    }
}

/// @notice Minimal Permit2 mock: ignores signature, just moves tokens like the real one would.
contract MockPermit2 is IPermit2 {
    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata
    ) external override {
        IERC20(permit.permitted.token).transferFrom(owner, transferDetails.to, transferDetails.requestedAmount);
    }
}

/// @notice Minimal NonfungiblePositionManager mock: pulls the desired amounts and returns them.
contract MockPositionManager {
    function createAndInitializePoolIfNecessary(address, address, uint24, uint160) external view returns (address) {
        return address(this);
    }

    function mint(MintParams calldata params)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        IERC20(params.token0).transferFrom(msg.sender, address(this), params.amount0Desired);
        IERC20(params.token1).transferFrom(msg.sender, address(this), params.amount1Desired);
        return (1, 1, params.amount0Desired, params.amount1Desired);
    }
}

/// @dev Like MockPositionManager but consumes less than desired, leaving unused
///      allowance on the factory (what the real NFPM can do when pool liquidity limits the mint).
contract MockPositionManagerPartial {
    function createAndInitializePoolIfNecessary(address, address, uint24, uint160) external view returns (address) {
        return address(this);
    }

    function mint(MintParams calldata params)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        uint256 pull0 = params.amount0Desired - 10 ether;
        uint256 pull1 = params.amount1Desired - 5 ether;
        IERC20(params.token0).transferFrom(msg.sender, address(this), pull0);
        IERC20(params.token1).transferFrom(msg.sender, address(this), pull1);
        return (1, 1, uint128(pull0), pull1);
    }
}
