// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DistributorV1, DistributorConfig} from "./DistributorV1.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TokenV1, Allocation} from "./TokenV1.sol";
import {TransferToHook} from "src/utils/hooks/TransferToHook.sol";
import {BuyAndBurnHookV3} from "src/utils/hooks/BuyAndBurnHookV3.sol";
import {MintParams} from "../external-interfaces/INonfungiblePositionManager.sol";
import {INonfungiblePositionManager} from "../external-interfaces/INonfungiblePositionManager.sol";
import {SharesLib, Share} from "src/utils/Shares.sol";
import {Hook} from "src/utils/Hook.sol";
import {IPermit2} from "../external-interfaces/IPermit2.sol";

contract FactoryV1 is Ownable {
    using SafeERC20 for IERC20;
    using SharesLib for Share[];
    using SharesLib for Share;

    event NewDistributor(address indexed distributor);
    event NewToken(address indexed tokenAddress);

    uint256 public protocolFeeBps;

    TransferToHook public immutable TRANSFER_TO_HOOK;
    BuyAndBurnHookV3 public immutable BUY_AND_BURN_HOOK;
    INonfungiblePositionManager public immutable POSITION_MANAGER;
    IPermit2 public immutable PERMIT2;

    uint24 public constant LIQUIDITY_POOL_FEE = 3000; // 0.3%

    /// (contract => creator)
    /// @dev this can be used to check if contract address is a valid contract created by this factory and not somewhere else
    /// but it saves creator address instead of bool "just in case"
    mapping(address => address) creatorOf; // for tokens
    mapping(address => address) distributorOf; // for distributions

    constructor(
        address _initialOwner,
        uint256 _protocolFeeBps,
        TransferToHook _transferToHook,
        BuyAndBurnHookV3 _buyAndBurnHookV3,
        INonfungiblePositionManager _positionManager,
        IPermit2 _permit2
    ) Ownable(_initialOwner) {
        protocolFeeBps = _protocolFeeBps;
        POSITION_MANAGER = _positionManager;
        PERMIT2 = _permit2;
        TRANSFER_TO_HOOK = _transferToHook;
        BUY_AND_BURN_HOOK = _buyAndBurnHookV3;
    }

    // --- sqrt governance ---

    function setProtocolFeeBps(uint256 _protocolFeeBps) public onlyOwner {
        protocolFeeBps = _protocolFeeBps;
    }

    function drain(address _token, address _to) public onlyOwner {
        uint256 balance = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(_to, balance);
    }

    // --- factory functions ---

    function createToken(string memory _name, string memory _symbol, Allocation[] memory _allocations)
        public
        returns (address tokenAddress)
    {
        tokenAddress = address(new TokenV1(_name, _symbol, _allocations));
        creatorOf[tokenAddress] = msg.sender;
        emit NewToken(tokenAddress);
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
        distributorAddress = address(new DistributorV1(msg.sender, _config));

        if (_pullIn) {
            // sender pays the distribution token
            IERC20(_config.distributionToken)
                .safeTransferFrom(msg.sender, distributorAddress, _config.totalDistributionAmount);
        } else {
            // contract pays the distribution token
            IERC20(_config.distributionToken).safeTransfer(distributorAddress, _config.totalDistributionAmount);
        }

        distributorOf[distributorAddress] = msg.sender;
        emit NewDistributor(distributorAddress);
    }

    /// @dev LP tokens are sent to a dead address (burned)
    /// @param _pullIn if false, distribution token is not pulled (factory already has it)
    /// @param _participationPermit2 empty signature (= no permit2) falls back to allowance-based safeTransferFrom
    /// @param _distributionPermit2 empty signature (= no permit2) falls back to allowance-based safeTransferFrom
    function createPoolAndAddLiquidity(
        address _participationToken,
        address _distributionToken,
        uint160 _sqrtPriceX96,
        uint256 _participationTokenAmountDesired,
        uint256 _distributionTokenAmountDesired,
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

        MintParams memory params = MintParams({
            token0: token0,
            token1: token1,
            fee: LIQUIDITY_POOL_FEE,
            tickLower: -887220,
            tickUpper: 887220,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0,
            amount1Min: 0,
            recipient: 0x000000000000000000000000000000000000dEaD, // burning LP tokens
            deadline: type(uint256).max
        });

        (tokenId, liquidity, amount0, amount1) = POSITION_MANAGER.mint(params);

        uint256 refund0 = amount0Desired - amount0;
        if (refund0 > 0) IERC20(token0).safeTransfer(msg.sender, refund0);
        uint256 refund1 = amount1Desired - amount1;
        if (refund1 > 0) IERC20(token1).safeTransfer(msg.sender, refund1);
    }

    /// @dev this function does three things 1.token creating - 2.liquidity pool creation - 3.distribution creation
    /// @notice _config.distributionToken will be overwrite by new created token just set it to address(0) or something
    /// @param _buyBackAndBurnShareBps (amountIn * share.shareBps) / 10000 set zero if you don't want to inject buyAndBurn make sure shares sum up to 100% after buyAndBurn injection
    /// @notice allocate token for Factory contract (this contract) as much as totalDistributionAmount + _distributionTokenAmountDesired
    function createTokenAndLiquidityAndDistribution(
        string memory _tokenName,
        string memory _tokenSymbol,
        Allocation[] memory _tokenAllocations,
        uint160 _sqrtPriceX96,
        uint256 _participationTokenAmountDesired,
        uint256 _distributionTokenAmountDesired,
        DistributorConfig memory _config,
        uint256 _buyBackAndBurnShareBps,
        Permit2Data calldata _participationPermit2
    ) public returns (address tokenAddress, address distributorAddress) {
        tokenAddress = createToken(_tokenName, _tokenSymbol, _tokenAllocations);
        _config.distributionToken = tokenAddress;

        createPoolAndAddLiquidity(
            _config.participationToken,
            tokenAddress,
            _sqrtPriceX96,
            _participationTokenAmountDesired,
            _distributionTokenAmountDesired,
            false,
            _participationPermit2,
            _emptyPermit2()
        );

        // we need to do this here because caller doesn't know address of token
        if (_buyBackAndBurnShareBps != 0) _injectBuyAndBurnShare(_config, _buyBackAndBurnShareBps);

        // we don't need to pull-in tokens from user because factory contract has allocation as much as totalDistributionAmount
        distributorAddress = createDistributor(_config, false);
    }

    // --- Utility functions ---

    function _injectProtocolFeeShare(DistributorConfig memory _config) internal view {
        _config.shares = SharesLib.append(
            _config.shares,
            Share({
                shareBps: protocolFeeBps,
                hook: Hook({
                    contractAddress: address(TRANSFER_TO_HOOK),
                    callData: abi.encodeCall(TransferToHook.transferTo, (_config.participationToken, address(this)))
                })
            })
        );
    }

    function _injectBuyAndBurnShare(DistributorConfig memory _config, uint256 _shareBps) internal view {
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
