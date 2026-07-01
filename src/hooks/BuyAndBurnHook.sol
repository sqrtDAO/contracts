// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "lib/forge-std/src/interfaces/IERC20.sol";
import {UniswapV2SwapHook} from "./UniswapV2SwapHook.sol";

contract BuyAndBurnHook is UniswapV2SwapHook {
    event BoughtAndBurned(uint256 amountIn, uint256 amountOut);

    address public constant BURN_ADDRESS = address(0x000000000000000000000000000000000000dEaD);

    function buyAndBurn(address _router, address[] calldata _path) external returns (uint256 amountOut) {
        (uint256 amountIn, uint256 result) = _swap(_router, _path, address(this));
        require(result > 0, "Swap returned zero output");
        require(IERC20(_path[_path.length - 1]).transfer(BURN_ADDRESS, result), "burn transfer failed");
        amountOut = result;
        emit BoughtAndBurned(amountIn, amountOut);
    }
}
