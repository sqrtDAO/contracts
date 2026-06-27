// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "lib/forge-std/src/interfaces/IERC20.sol";

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract BuyAndBurnHook {
    IUniswapV2Router02 public immutable ROUTER;
    address public immutable PARTICIPATION_TOKEN;
    address public immutable DISTRBUTION_TOKEN;
    address[] public path;

    address public constant BURN_ADDRESS = address(0x000000000000000000000000000000000000dEaD);
    event BoughtAndBurned(uint256 amountIn, uint256 amountOut);

    constructor(address _router, address[] memory _path) {
        require(_path.length >= 2, "Invalid swap path");
        ROUTER = IUniswapV2Router02(_router);
        PARTICIPATION_TOKEN = _path[0];
        DISTRBUTION_TOKEN = _path[_path.length - 1];

        path = new address[](_path.length);
        for (uint256 i = 0; i < _path.length; i++) {
            path[i] = _path[i];
        }
    }

    /**
     * @notice Pulls all participation tokens from the caller, swaps them for distribution tokens on Uniswap, and burns the result.
     * @dev The caller must have approved this contract to spend PARTICIPATION_TOKEN.
     */
    function execute() external returns (bytes memory) {
        address sender = msg.sender;
        uint256 amountIn = IERC20(PARTICIPATION_TOKEN).balanceOf(sender);
        require(amountIn > 0, "No participation tokens to swap");

        require(IERC20(PARTICIPATION_TOKEN).transferFrom(sender, address(this), amountIn), "transferFrom failed");

        require(IERC20(PARTICIPATION_TOKEN).approve(address(ROUTER), amountIn), "approve failed");

        uint256[] memory amounts = ROUTER.swapExactTokensForTokens(amountIn, 0, path, address(this), block.timestamp);

        uint256 amountOut = IERC20(DISTRBUTION_TOKEN).balanceOf(address(this));
        require(amountOut > 0, "Swap returned zero output");

        require(IERC20(DISTRBUTION_TOKEN).transfer(BURN_ADDRESS, amountOut), "burn transfer failed");

        emit BoughtAndBurned(amountIn, amountOut);
        return abi.encode(amounts);
    }
}
