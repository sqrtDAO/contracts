// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DistributorV1, DistributorConfig} from "./DistributorV1.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TokenV1, Allocation} from "./TokenV1.sol";
import {MintParams} from "../external-interfaces/INonfungiblePositionManager.sol";
import {INonfungiblePositionManager} from "../external-interfaces/INonfungiblePositionManager.sol";

contract FactoryV1 is Ownable {
    using SafeERC20 for IERC20;

    event NewDistributor(address indexed distributor);
    event NewToken(address indexed tokenAddress);

    uint256 public protocolFeeBps;
    address public protocolFeeReceiver;
    INonfungiblePositionManager public immutable POSITION_MANAGER;

    uint24 public constant LIQUIDITY_POOL_FEE = 3000; // 0.3%

    /// (contract => creator)
    /// @dev this can be used to check if contract address is a valid contract created by this factory and not somewhere else
    /// but it saves creator address instead of bool "just in case"
    mapping(address => address) creatorOf;

    constructor(
        address _initialOwner,
        uint256 _protocolFeeBps,
        address _protocolFeeReceiver,
        INonfungiblePositionManager _positionManager
    ) Ownable(_initialOwner) {
        protocolFeeBps = _protocolFeeBps;
        protocolFeeReceiver = _protocolFeeReceiver;
        POSITION_MANAGER = _positionManager;
    }

    function checkContractDeployedByThis(address _contractAddress) public view returns (bool) {
        return creatorOf[_contractAddress] != address(0);
    }

    function setProtocolFeeBps(uint256 _protocolFeeBps) public onlyOwner {
        protocolFeeBps = _protocolFeeBps;
    }

    function setProtocolFeeReceiver(address _protocolFeeReceiver) public onlyOwner {
        protocolFeeReceiver = _protocolFeeReceiver;
    }

    /// @dev Make sure you give allowance to Factory contract before call this
    /// allowance to both participation token (for initial participation) and distribution token to transfer totalDistributionAmount to distribution contract
    function createDistributor(DistributorConfig memory _config) external returns (address distributorAddress) {
        DistributorV1 distributor = new DistributorV1(msg.sender, protocolFeeBps, protocolFeeReceiver, _config);

        IERC20(_config.distributionToken)
            .safeTransferFrom(msg.sender, address(distributor), _config.totalDistributionAmount);

        distributorAddress = address(distributor);
        creatorOf[distributorAddress] = msg.sender;
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

    function createToken(string memory _name, string memory _symbol, Allocation[] memory _allocations)
        public
        returns (address tokenAddress)
    {
        // Deploy new token – the total supply goes straight to the creator (msg.sender)
        TokenV1 newToken = new TokenV1(_name, _symbol, _allocations);
        tokenAddress = address(newToken);
        emit NewToken(tokenAddress);
    }
}
