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

contract FactoryV1 is Ownable {
    using SafeERC20 for IERC20;
    using SharesLib for Share[];
    using SharesLib for Share;

    event NewDistributor(address indexed distributor);
    event NewToken(address indexed tokenAddress);

    uint256 public protocolFeeBps;
    address public protocolFeeReceiver;

    TransferToHook public immutable TRANSFER_TO_HOOK;
    BuyAndBurnHookV3 public immutable BUY_AND_BURN_HOOK;
    INonfungiblePositionManager public immutable POSITION_MANAGER;

    uint24 public constant LIQUIDITY_POOL_FEE = 3000; // 0.3%

    /// (contract => creator)
    /// @dev this can be used to check if contract address is a valid contract created by this factory and not somewhere else
    /// but it saves creator address instead of bool "just in case"
    mapping(address => address) creatorOf; // for tokens
    mapping(address => address) distributorOf; // for distributions

    constructor(
        address _initialOwner,
        uint256 _protocolFeeBps,
        address _protocolFeeReceiver,
        address _uniswapSwapRouter,
        INonfungiblePositionManager _positionManager
    ) Ownable(_initialOwner) {
        protocolFeeBps = _protocolFeeBps;
        protocolFeeReceiver = _protocolFeeReceiver;
        POSITION_MANAGER = _positionManager;
        TRANSFER_TO_HOOK = new TransferToHook();
        BUY_AND_BURN_HOOK = new BuyAndBurnHookV3(_uniswapSwapRouter);
    }

    // --- sqrt governance ---

    function setProtocolFeeBps(uint256 _protocolFeeBps) public onlyOwner {
        protocolFeeBps = _protocolFeeBps;
    }

    function setProtocolFeeReceiver(address _protocolFeeReceiver) public onlyOwner {
        protocolFeeReceiver = _protocolFeeReceiver;
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

    /// @dev caller must approve this contract to spend both tokens
    /// @dev LP tokens are sent to a dead address (burned)
    function createPoolAndAddLiquidity(
        address token0,
        address token1,
        uint160 sqrtPriceX96,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) public returns (address pool, uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0Desired);
        IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1Desired);

        IERC20(token0).approve(address(POSITION_MANAGER), amount0Desired);
        IERC20(token1).approve(address(POSITION_MANAGER), amount1Desired);

        pool = POSITION_MANAGER.createAndInitializePoolIfNecessary(token0, token1, LIQUIDITY_POOL_FEE, sqrtPriceX96);

        MintParams memory params = MintParams({
            token0: token0,
            token1: token1,
            fee: LIQUIDITY_POOL_FEE,
            tickLower: -887272, // we don't care we are burning LP tokens
            tickUpper: 887272, // we don't care we are burning LP tokens
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0, // we don't care we are burning LP tokens
            amount1Min: 0, // we don't care we are burning LP tokens
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
    /// @notice allocate token for Factory contract (this contract) as much as "totalDistributionAmount"
    function createTokenAndLiquidityAndDistribution(
        string memory _tokenName,
        string memory _tokenSymbol,
        Allocation[] memory _tokenAllocations,
        uint160 _sqrtPriceX96,
        uint256 _participationTokenAmountDesired,
        uint256 _distributionTokenAmountDesired,
        DistributorConfig memory _config,
        uint256 _buyBackAndBurnShareBps
    ) public returns (address tokenAddress, address distributorAddress) {
        tokenAddress = createToken(_tokenName, _tokenSymbol, _tokenAllocations);
        _config.distributionToken = tokenAddress;

        createPoolAndAddLiquidity(
            _config.participationToken,
            tokenAddress,
            _sqrtPriceX96,
            _participationTokenAmountDesired,
            _distributionTokenAmountDesired
        );

        // we need to do this here because caller doesn't know address of token
        if (_buyBackAndBurnShareBps != 0) _injectBuyAndBurnShare(_config, _buyBackAndBurnShareBps);

        // we don't need to pull-in tokens from user because factory contract has allocation as much as totalDistributionAmount
        distributorAddress = createDistributor(_config, false);
    }

    // --- Utility functions ---

    function _injectProtocolFeeShare(DistributorConfig memory _config) internal view {
        Share[] memory newShares = new Share[](_config.shares.length + 1);

        for (uint256 i; i < _config.shares.length; i++) {
            newShares[i] = _config.shares[i];
        }

        newShares[_config.shares.length] = Share({
            shareBps: protocolFeeBps,
            hook: Hook({
                contractAddress: address(TRANSFER_TO_HOOK),
                callData: abi.encodeCall(TransferToHook.transferTo, (_config.distributionToken, protocolFeeReceiver))
            })
        });
        _config.shares = newShares;
    }

    function _injectBuyAndBurnShare(DistributorConfig memory _config, uint256 _shareBps) internal view {
        Share[] memory newShares = new Share[](_config.shares.length + 1);

        bytes memory path = abi.encodePacked(_config.participationToken, LIQUIDITY_POOL_FEE, _config.distributionToken);

        for (uint256 i; i < _config.shares.length; i++) {
            newShares[i] = _config.shares[i];
        }

        newShares[_config.shares.length] = Share({
            shareBps: _shareBps,
            hook: Hook({
                contractAddress: address(BUY_AND_BURN_HOOK),
                callData: abi.encodeCall(BuyAndBurnHookV3.buyAndBurn, (path))
            })
        });
        _config.shares = newShares;
    }
}
