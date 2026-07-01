// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "lib/forge-std/src/interfaces/IERC20.sol";
import {IUniswapV2Router02} from "src/external-interfaces/IUniswapV2Router02.sol";

abstract contract UniswapV2SwapHook {
    function _swap(address _router, address[] calldata _path, address _to)
        internal
        returns (uint256 amountIn, uint256 amountOut)
    {
        address sender = msg.sender;
        IERC20 token = IERC20(_path[0]);

        amountIn = token.allowance(sender, address(this));
        require(amountIn > 0, "Allowance is zero");

        require(token.transferFrom(sender, address(this), amountIn), "transferFrom failed");

        require(token.approve(_router, amountIn), "approve failed");
        uint256[] memory amounts =
            IUniswapV2Router02(_router).swapExactTokensForTokens(amountIn, 0, _path, _to, block.timestamp);
        token.approve(_router, 0);

        amountOut = amounts[amounts.length - 1];
    }
}
