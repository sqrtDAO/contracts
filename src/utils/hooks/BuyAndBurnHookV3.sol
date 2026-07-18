// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3SwapRouter, ExactInputParams} from "src/external-interfaces/IUniswapV3SwapRouter.sol";

contract BuyAndBurnHookV3 {
    using SafeERC20 for IERC20;
    event BoughtAndBurnedV3(uint256 amountIn, uint256 amountOut);

    address public constant BURN_ADDRESS = address(0x000000000000000000000000000000000000dEaD);
    address public immutable UNISWAP_SWAP_ROUTER_ADDRESS;

    constructor(address _uniswapSwapRouterAddress) {
        UNISWAP_SWAP_ROUTER_ADDRESS = _uniswapSwapRouterAddress;
    }

    function buyAndBurn(bytes calldata _path) external returns (uint256 amountOut) {
        IERC20 token = IERC20(_decodeFirstToken(_path));

        uint256 amountIn = token.allowance(msg.sender, address(this));
        require(amountIn > 0, "Allowance is zero");

        token.safeTransferFrom(msg.sender, address(this), amountIn);

        token.forceApprove(UNISWAP_SWAP_ROUTER_ADDRESS, amountIn);
        amountOut = IUniswapV3SwapRouter(UNISWAP_SWAP_ROUTER_ADDRESS)
            .exactInput(
                ExactInputParams({path: _path, recipient: BURN_ADDRESS, amountIn: amountIn, amountOutMinimum: 0})
            );
        token.forceApprove(UNISWAP_SWAP_ROUTER_ADDRESS, 0);

        emit BoughtAndBurnedV3(amountIn, amountOut);
    }

    function _decodeFirstToken(bytes calldata _path) private pure returns (address tokenIn) {
        assembly {
            tokenIn := calldataload(_path.offset)
        }
    }
}
