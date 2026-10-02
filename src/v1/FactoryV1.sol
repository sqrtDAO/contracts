// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {DistributorConfig} from "./DistributorV1.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TokenConfig} from "./TokenV1.sol";
import {TokenV1Factory} from "./TokenV1Factory.sol";
import {DistributionV1Factory} from "./DistributionV1Factory.sol";
import {TransferToHook} from "src/utils/hooks/TransferToHook.sol";
import {BuyAndBurnHookV3} from "src/utils/hooks/BuyAndBurnHookV3.sol";
import {FeeVault} from "src/utils/FeeVault.sol";
import {MintParams} from "../external-interfaces/INonfungiblePositionManager.sol";
import {INonfungiblePositionManager} from "../external-interfaces/INonfungiblePositionManager.sol";
import {IUniswapV3Pool} from "../external-interfaces/IUniswapV3Pool.sol";
import {SharesLib, Share} from "src/utils/Shares.sol";
import {Hook} from "src/utils/Hook.sol";
import {IPermit2} from "../external-interfaces/IPermit2.sol";

contract FactoryV1 is Ownable {
    using SafeERC20 for IERC20;
    using SharesLib for Share[];
    using SharesLib for Share;

    /// @notice owner-configurable settings (see `FactoryConfig`)
    FactoryConfig public config;

    TransferToHook public immutable TRANSFER_TO_HOOK;
    BuyAndBurnHookV3 public immutable BUY_AND_BURN_HOOK;
    INonfungiblePositionManager public immutable POSITION_MANAGER;
    IPermit2 public immutable PERMIT2;
    TokenV1Factory public immutable TOKEN_FACTORY;
    DistributionV1Factory public immutable DISTRIBUTOR_FACTORY;
    FeeVault public immutable FEE_VAULT;

    uint24 public constant LIQUIDITY_POOL_FEE = 3000; // 0.3%

    error InvalidConfigBps(uint256 protocolFeeBps, uint256 buyBackAndBurnMinBps);
    error BuyBackAndBurnShareBelowMinBps(uint256 providedBps, uint256 minBps);

    event FactoryConfigSet(
        address indexed user, uint256 protocolFeeBps, address releaseOperator, uint256 buyBackAndBurnMinBps
    );

    constructor(
        address _initialOwner,
        uint256 _protocolFeeBps,
        TransferToHook _transferToHook,
        BuyAndBurnHookV3 _buyAndBurnHookV3,
        INonfungiblePositionManager _positionManager,
        IPermit2 _permit2,
        TokenV1Factory _tokenFactory,
        DistributionV1Factory _distributorFactory,
        FeeVault _feeVault
    ) Ownable(_initialOwner) {
        config.protocolFeeBps = _protocolFeeBps;
        POSITION_MANAGER = _positionManager;
        PERMIT2 = _permit2;
        TRANSFER_TO_HOOK = _transferToHook;
        BUY_AND_BURN_HOOK = _buyAndBurnHookV3;
        TOKEN_FACTORY = _tokenFactory;
        DISTRIBUTOR_FACTORY = _distributorFactory;
        FEE_VAULT = _feeVault;
        _tokenFactory.setFactory(address(this));
        _distributorFactory.setFactory(address(this));
    }

    // --- sqrt governance ---

    /// @notice sets all owner-configurable settings at once (replaces the whole config)
    /// @dev reverts if the settings cannot produce a valid launch: both values are capped at 100% and the
    ///      protocol fee plus the mandatory buy&burn minimum must not exceed 100% together
    function setConfig(FactoryConfig calldata _config) external onlyOwner {
        if (
            _config.protocolFeeBps > 10_000 || _config.buyBackAndBurnMinBps > 10_000
                || _config.protocolFeeBps + _config.buyBackAndBurnMinBps > 10_000
        ) {
            revert InvalidConfigBps(_config.protocolFeeBps, _config.buyBackAndBurnMinBps);
        }
        config = _config;
        emit FactoryConfigSet(msg.sender, _config.protocolFeeBps, _config.releaseOperator, _config.buyBackAndBurnMinBps);
    }

    function sweepToken(address _token, address _to) public onlyOwner {
        uint256 balance = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(_to, balance);
    }

    // --- factory functions ---

    /// @notice deploys a new TokenV1 with `msg.sender` as its owner
    /// @param _config token configuration (see `TokenConfig`)
    function createToken(TokenConfig memory _config) public returns (address tokenAddress) {
        tokenAddress = TOKEN_FACTORY.createToken(_config, msg.sender);
    }

    /// @dev Make sure you give allowance to Factory contract before call this
    /// allowance to distribution token to transfer totalDistributionAmount to distribution contract
    /// @notice for _config.shares, make sure it sums up to (100% - protocolFeeBps) because this function force injects protocol fee to _config.shares
    /// @param _pullIn somehow contract has distribution token and don't need to pull it from sender in this case set this flag to false
    function createDistributor(DistributorConfig memory _config, bool _pullIn)
        public
        returns (address distributorAddress)
    {
        _injectProtocolFeeShare(_config);
        _requireBuyAndBurnSharesAboveMin(_config.shares);
        distributorAddress = DISTRIBUTOR_FACTORY.createDistributor(msg.sender, _config);

        if (_pullIn) {
            // sender pays the distribution token
            IERC20(_config.distributionToken)
                .safeTransferFrom(msg.sender, distributorAddress, _config.totalDistributionAmount);
        } else {
            // contract pays the distribution token
            IERC20(_config.distributionToken).safeTransfer(distributorAddress, _config.totalDistributionAmount);
        }
    }

    /// @dev LP tokens are sent to a dead address (burned). After pool initialization the on-chain pool price is
    ///      verified to be exactly `_sqrtPriceX96`, so a pre-created pool with a different price can never be
    ///      adopted by this launch (front-run protection)
    /// @param _participationToken token participants pay with
    /// @param _distributionToken token being distributed
    /// @param _sqrtPriceX96 initial pool price; the launch also reverts if the pool already exists with any other price
    /// @param _participationTokenAmountDesired maximum amount of the participation token to deposit into the pool
    /// @param _distributionTokenAmountDesired maximum amount of the distribution token to deposit into the pool
    /// @param _amount0Min minimum amount of token0 (tokens sorted) that must be deposited — slippage protection
    /// @param _amount1Min minimum amount of token1 (tokens sorted) that must be deposited — slippage protection
    /// @param _pullIn if false, distribution token is not pulled (factory already has it)
    /// @param _participationPermit2 empty signature (= no permit2) falls back to allowance-based safeTransferFrom
    /// @param _distributionPermit2 empty signature (= no permit2) falls back to allowance-based safeTransferFrom
    function createPoolAndAddLiquidity(
        address _participationToken,
        address _distributionToken,
        uint160 _sqrtPriceX96,
        uint256 _participationTokenAmountDesired,
        uint256 _distributionTokenAmountDesired,
        uint256 _amount0Min,
        uint256 _amount1Min,
        bool _pullIn,
        Permit2Data memory _participationPermit2,
        Permit2Data memory _distributionPermit2
    ) public returns (address pool, uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        IERC20 participationToken = IERC20(_participationToken);
        IERC20 distributionToken = IERC20(_distributionToken);

        if (_participationPermit2.signature.length > 0) {
            PERMIT2.permitTransferFrom(
                _participationPermit2.permit,
                IPermit2.SignatureTransferDetails({
                    to: address(this), requestedAmount: _participationTokenAmountDesired
                }),
                msg.sender,
                _participationPermit2.signature
            );
        } else {
            participationToken.safeTransferFrom(msg.sender, address(this), _participationTokenAmountDesired);
        }

        if (_pullIn) {
            if (_distributionPermit2.signature.length > 0) {
                PERMIT2.permitTransferFrom(
                    _distributionPermit2.permit,
                    IPermit2.SignatureTransferDetails({
                        to: address(this), requestedAmount: _distributionTokenAmountDesired
                    }),
                    msg.sender,
                    _distributionPermit2.signature
                );
            } else {
                distributionToken.safeTransferFrom(msg.sender, address(this), _distributionTokenAmountDesired);
            }
        }

        (address token0, address token1, uint256 amount0Desired, uint256 amount1Desired) = _participationToken
            < _distributionToken
            ? (
                _participationToken,
                _distributionToken,
                _participationTokenAmountDesired,
                _distributionTokenAmountDesired
            )
            : (
                _distributionToken,
                _participationToken,
                _distributionTokenAmountDesired,
                _participationTokenAmountDesired
            );

        IERC20(token0).approve(address(POSITION_MANAGER), amount0Desired);
        IERC20(token1).approve(address(POSITION_MANAGER), amount1Desired);

        pool = POSITION_MANAGER.createAndInitializePoolIfNecessary(token0, token1, LIQUIDITY_POOL_FEE, _sqrtPriceX96);

        // front-run protection: `createAndInitializePoolIfNecessary` no-ops when the pool already exists,
        // so make sure the on-chain price is exactly the one the caller asked for
        (uint160 poolSqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        require(poolSqrtPriceX96 == _sqrtPriceX96, "pool already initialized with a different price");

        MintParams memory params = MintParams({
            token0: token0,
            token1: token1,
            fee: LIQUIDITY_POOL_FEE,
            tickLower: -887220,
            tickUpper: 887220,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: _amount0Min,
            amount1Min: _amount1Min,
            recipient: 0x000000000000000000000000000000000000dEaD, // burning LP tokens
            deadline: type(uint256).max
        });

        (tokenId, liquidity, amount0, amount1) = POSITION_MANAGER.mint(params);

        if (IERC20(token0).allowance(address(this), address(POSITION_MANAGER)) != 0) {
            IERC20(token0).approve(address(POSITION_MANAGER), 0);
        }
        if (IERC20(token1).allowance(address(this), address(POSITION_MANAGER)) != 0) {
            IERC20(token1).approve(address(POSITION_MANAGER), 0);
        }

        uint256 refund0 = amount0Desired - amount0;
        if (refund0 > 0) IERC20(token0).safeTransfer(msg.sender, refund0);
        uint256 refund1 = amount1Desired - amount1;
        if (refund1 > 0) IERC20(token1).safeTransfer(msg.sender, refund1);
    }

    /// @dev this function does three things 1.token creating - 2.liquidity pool creation - 3.distribution creation
    /// @notice _config.distributionToken will be overwrite by new created token just set it to address(0) or something
    /// @param _buyBackAndBurnShareBps (amountIn * share.shareBps) / 10000 share routed to the buy&burn hook; reverts if below the owner-configured minimum (config().buyBackAndBurnMinBps) — zero is only allowed while that minimum is zero (then nothing is injected). Make sure shares sum up to 100% after buyAndBurn injection
    /// @notice allocate token for Factory contract (this contract) as much as totalDistributionAmount + _distributionTokenAmountDesired
    ///         with startTime = 0 and duration = 0 so tokens are minted to this contract at deployment
    /// @param _tokenConfig token configuration for the new token (see `TokenConfig`)
    /// @param _sqrtPriceX96 initial pool price; the launch reverts if the pool already exists with a different price
    /// @param _participationTokenAmountDesired maximum amount of the participation token to deposit into the pool
    /// @param _distributionTokenAmountDesired maximum amount of the new token to deposit into the pool
    /// @param _participationTokenAmountMin minimum amount of the participation token to deposit — slippage protection
    /// @param _distributionTokenAmountMin minimum amount of the new token to deposit — slippage protection
    /// @param _config distributor configuration (see `DistributorConfig`)
    /// @param _buyBackAndBurnShareBps (amountIn * share.shareBps) / 10000 share routed to the buy&burn hook; reverts if below the owner-configured minimum (config().buyBackAndBurnMinBps) — zero is only allowed while that minimum is zero (then nothing is injected). Make sure shares sum up to 100% after buyAndBurn injection
    /// @param _participationPermit2 empty signature (= no permit2) falls back to allowance-based safeTransferFrom
    function createTokenAndLiquidityAndDistribution(
        TokenConfig memory _tokenConfig,
        uint160 _sqrtPriceX96,
        uint256 _participationTokenAmountDesired,
        uint256 _distributionTokenAmountDesired,
        uint256 _participationTokenAmountMin,
        uint256 _distributionTokenAmountMin,
        DistributorConfig memory _config,
        uint256 _buyBackAndBurnShareBps,
        Permit2Data calldata _participationPermit2
    ) public returns (address tokenAddress, address distributorAddress) {
        tokenAddress = createToken(_tokenConfig);
        _config.distributionToken = tokenAddress;

        // the caller cannot know the new token's address up front, so the mins are given per role
        // and mapped onto the sorted (token0, token1) order here
        (uint256 amount0Min, uint256 amount1Min) = _config.participationToken < tokenAddress
            ? (_participationTokenAmountMin, _distributionTokenAmountMin)
            : (_distributionTokenAmountMin, _participationTokenAmountMin);

        createPoolAndAddLiquidity(
            _config.participationToken,
            tokenAddress,
            _sqrtPriceX96,
            _participationTokenAmountDesired,
            _distributionTokenAmountDesired,
            amount0Min,
            amount1Min,
            false,
            _participationPermit2,
            _emptyPermit2()
        );

        // we need to do this here because caller doesn't know address of token
        _injectBuyAndBurnShare(_config, _buyBackAndBurnShareBps);

        // we don't need to pull-in tokens from user because factory contract has allocation as much as totalDistributionAmount
        distributorAddress = createDistributor(_config, false);
    }

    /// @dev this function does two things 1.liquidity pool creation - 2.distribution creation for an already existing distribution token
    /// @notice for _config.shares, make sure it sums up to (100% - protocolFeeBps) because createDistributor force injects protocol fee to _config.shares
    /// @param _buyBackAndBurnShareBps (amountIn * share.shareBps) / 10000 share routed to the buy&burn hook; reverts if below the owner-configured minimum (config().buyBackAndBurnMinBps) — zero is only allowed while that minimum is zero (then nothing is injected). Make sure shares sum up to 100% after buyAndBurn injection
    /// @notice unlike createTokenAndLiquidityAndDistribution factory contract doesn't hold any allocation of the distribution token
    ///         so sender pays both liquidity distribution tokens and totalDistributionAmount
    /// @param _sqrtPriceX96 initial pool price; the launch reverts if the pool already exists with a different price
    /// @param _participationTokenAmountDesired maximum amount of the participation token to deposit into the pool
    /// @param _distributionTokenAmountDesired maximum amount of the distribution token to deposit into the pool
    /// @param _participationTokenAmountMin minimum amount of the participation token to deposit — slippage protection
    /// @param _distributionTokenAmountMin minimum amount of the distribution token to deposit — slippage protection
    /// @param _config distributor configuration (see `DistributorConfig`)
    /// @param _buyBackAndBurnShareBps (amountIn * share.shareBps) / 10000 share routed to the buy&burn hook; reverts if below the owner-configured minimum (config().buyBackAndBurnMinBps) — zero is only allowed while that minimum is zero (then nothing is injected). Make sure shares sum up to 100% after buyAndBurn injection
    /// @param _participationPermit2 empty signature (= no permit2) falls back to allowance-based safeTransferFrom
    /// @param _distributionPermit2 empty signature (= no permit2) falls back to allowance-based safeTransferFrom
    function createLiquidityAndDistribution(
        uint160 _sqrtPriceX96,
        uint256 _participationTokenAmountDesired,
        uint256 _distributionTokenAmountDesired,
        uint256 _participationTokenAmountMin,
        uint256 _distributionTokenAmountMin,
        DistributorConfig memory _config,
        uint256 _buyBackAndBurnShareBps,
        Permit2Data calldata _participationPermit2,
        Permit2Data calldata _distributionPermit2
    ) public returns (address pool, address distributorAddress) {
        // mins are given per role (like the desired amounts) and mapped onto the sorted (token0, token1) order
        (uint256 amount0Min, uint256 amount1Min) = _config.participationToken < _config.distributionToken
            ? (_participationTokenAmountMin, _distributionTokenAmountMin)
            : (_distributionTokenAmountMin, _participationTokenAmountMin);

        (pool,,,,) = createPoolAndAddLiquidity(
            _config.participationToken,
            _config.distributionToken,
            _sqrtPriceX96,
            _participationTokenAmountDesired,
            _distributionTokenAmountDesired,
            amount0Min,
            amount1Min,
            true,
            _participationPermit2,
            _distributionPermit2
        );

        _injectBuyAndBurnShare(_config, _buyBackAndBurnShareBps);

        // sender pays the distribution token because factory contract doesn't hold any allocation of it
        distributorAddress = createDistributor(_config, true);
    }

    // --- Utility functions ---

    function _injectProtocolFeeShare(DistributorConfig memory _config) internal view {
        _config.shares = SharesLib.append(
            _config.shares,
            Share({
                shareBps: config.protocolFeeBps,
                hook: Hook({
                    contractAddress: address(TRANSFER_TO_HOOK),
                    callData: abi.encodeCall(
                        TransferToHook.transferTo, (_config.participationToken, address(FEE_VAULT))
                    )
                })
            })
        );
    }

    /// @dev mandatory minimum: reverts when the requested share is below `config.buyBackAndBurnMinBps`
    ///      (zero included, so opting out is only possible while the configured minimum is zero)
    function _injectBuyAndBurnShare(DistributorConfig memory _config, uint256 _shareBps) internal view {
        uint256 minBps = config.buyBackAndBurnMinBps;
        if (_shareBps < minBps) revert BuyBackAndBurnShareBelowMinBps(_shareBps, minBps);
        if (_shareBps == 0) return; // no buy&burn share injected — only reachable when minBps is zero

        bytes memory path = abi.encodePacked(_config.participationToken, LIQUIDITY_POOL_FEE, _config.distributionToken);

        _config.shares = SharesLib.append(
            _config.shares,
            Share({
                shareBps: _shareBps,
                hook: Hook({
                    contractAddress: address(BUY_AND_BURN_HOOK),
                    callData: abi.encodeCall(BuyAndBurnHookV3.buyAndBurn, (path))
                })
            })
        );
    }

    /// @dev distributors can be created directly (not through the launch helpers), where callers hand-craft
    ///      their own shares — any share routed to the buy&burn hook must still respect the configured minimum
    function _requireBuyAndBurnSharesAboveMin(Share[] memory _shares) internal view {
        uint256 minBps = config.buyBackAndBurnMinBps;
        for (uint256 i; i < _shares.length; ++i) {
            if (_shares[i].hook.contractAddress == address(BUY_AND_BURN_HOOK) && _shares[i].shareBps < minBps) {
                revert BuyBackAndBurnShareBelowMinBps(_shares[i].shareBps, minBps);
            }
        }
    }

    function _emptyPermit2() internal pure returns (Permit2Data memory) {
        return Permit2Data({
            permit: IPermit2.PermitTransferFrom({
                permitted: IPermit2.TokenPermissions({token: address(0), amount: 0}), nonce: 0, deadline: 0
            }),
            signature: ""
        });
    }
}

struct Permit2Data {
    IPermit2.PermitTransferFrom permit;
    bytes signature;
}

/// @param protocolFeeBps protocol fee in basis points e.g. 50 means 0.5%
/// @param releaseOperator operator (besides the owner) allowed to trigger releases on distributors whose release
///        policy is `Factory` — read by the distributors directly via the `config()` getter
/// @param buyBackAndBurnMinBps minimum buy&burn share in basis points every launch must allocate to the buy&burn
///        hook (zero disables the minimum and also allows launching without any buy&burn share)
struct FactoryConfig {
    uint256 protocolFeeBps;
    address releaseOperator;
    uint256 buyBackAndBurnMinBps;
}
