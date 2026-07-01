// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {UniswapV2SwapHook} from "./UniswapV2SwapHook.sol";

contract BuyBackHook is UniswapV2SwapHook {
    event BuyBacked(uint256 amountIn, uint256 amountOut);

    function buyBack(address _router, address[] calldata _path) external returns (uint256 amountOut) {
        (uint256 amountIn, uint256 result) = _swap(_router, _path, msg.sender);
        require(result > 0, "Swap returned zero output");
        amountOut = result;
        emit BuyBacked(amountIn, amountOut);
    }
}
