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
    event BoughtAndBurned(uint256 amountIn, uint256 amountOut);

    address public constant BURN_ADDRESS = address(0x000000000000000000000000000000000000dEaD);

    /**
     * @notice Pulls all sells _sellToken and buys _burnToken then sends all _burnToken to BURN_ADDRESS
     * @param _sellToken is input token contract take out of sender address
     * @param _burnToken token that will send to burnAddress after swap
     * @param _router UniswapV2Router02 address
     * @param _path uniswap route to swap _sellToken to _burnToken
     * @dev The caller must have approved this contract to spend _sellToken.
     */
    function buyAndBurn(address _sellToken, address _burnToken, address _router, address[] calldata _path)
        external
        returns (bytes memory)
    {
        address sender = msg.sender;
        IERC20 sellToken = IERC20(_sellToken);
        IERC20 burnToken = IERC20(_burnToken);

        uint256 amountIn = sellToken.allowance(sender, address(this)); // might allow only part of all balance so I used allowance and not balance
        require(amountIn > 0, "Allowance is zero");

        require(sellToken.transferFrom(sender, address(this), amountIn), "transferFrom failed");

        require(sellToken.approve(_router, amountIn), "approve failed");

        IUniswapV2Router02 router = IUniswapV2Router02(_router);

        uint256[] memory amounts = router.swapExactTokensForTokens(amountIn, 0, _path, address(this), block.timestamp);

        uint256 amountOut = amounts[amounts.length - 1];
        require(amountOut > 0, "Swap returned zero output");

        require(burnToken.transfer(BURN_ADDRESS, amountOut), "burn transfer failed");

        emit BoughtAndBurned(amountIn, amountOut);
        return abi.encode(amounts);
    }
}
