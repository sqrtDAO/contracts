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
    IUniswapV2Router02 public immutable router;
    address public immutable participationToken;
    address public immutable distributionToken;
    address[] public path;

    address public constant BURN_ADDRESS = address(0x000000000000000000000000000000000000dEaD);
    event BoughtAndBurned(uint256 amountIn, uint256 amountOut);

    constructor(address _router, address[] memory _path) {
        require(_path.length >= 2, "Invalid swap path");
        router = IUniswapV2Router02(_router);
        participationToken = _path[0];
        distributionToken = _path[_path.length - 1];

        path = new address[](_path.length);
        for (uint256 i = 0; i < _path.length; i++) {
            path[i] = _path[i];
        }
    }

    /**
     * @notice Pulls all participation tokens from the caller, swaps them for distribution tokens on Uniswap, and burns the result.
     * @dev The caller must have approved this contract to spend participationToken.
     */
    function execute() external returns (bytes memory) {
        address sender = msg.sender;
        uint256 amountIn = IERC20(participationToken).balanceOf(sender);
        require(amountIn > 0, "No participation tokens to swap");

        require(IERC20(participationToken).transferFrom(sender, address(this), amountIn), "transferFrom failed");

        require(IERC20(participationToken).approve(address(router), amountIn), "approve failed");

        uint256[] memory amounts = router.swapExactTokensForTokens(amountIn, 0, path, address(this), block.timestamp);

        uint256 amountOut = IERC20(distributionToken).balanceOf(address(this));
        require(amountOut > 0, "Swap returned zero output");

        require(IERC20(distributionToken).transfer(BURN_ADDRESS, amountOut), "burn transfer failed");

        emit BoughtAndBurned(amountIn, amountOut);
        return abi.encode(amounts);
    }
}
