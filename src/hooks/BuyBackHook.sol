// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "lib/forge-std/src/interfaces/IERC20.sol";
import {IUniswapV2Router02} from "src/external-interfaces/IUniswapV2Router02.sol";

contract BuyAndBurnHook {
    event BuyBacked(uint256 amountIn, uint256 amountOut);

    /**
     * @notice Pulls all sells _sellToken and buys _buyToken then sends it all to msg.sender
     * @param _sellToken is input token contract take out of sender address
     * @param _router UniswapV2Router02 address
     * @param _path uniswap route to swap _sellToken to _buyToken
     * @dev The caller must have approved this contract to spend _sellToken.
     */
    function buyAndBurn(address _sellToken, address _router, address[] calldata _path)
        external
        returns (uint256 amountOut)
    {
        address sender = msg.sender;
        IERC20 sellToken = IERC20(_sellToken);
        IUniswapV2Router02 router = IUniswapV2Router02(_router);

        uint256 amountIn = sellToken.allowance(sender, address(this)); // might allow only part of all balance so I used allowance and not balance
        require(amountIn > 0, "Allowance is zero");

        require(sellToken.transferFrom(sender, address(this), amountIn), "transferFrom failed");

        require(sellToken.approve(_router, amountIn), "approve failed");
        uint256[] memory amounts = router.swapExactTokensForTokens(amountIn, 0, _path, sender, block.timestamp);
        sellToken.approve(_router, 0);

        amountOut = amounts[amounts.length - 1];
        emit BuyBacked(amountIn, amountOut);
    }
}
