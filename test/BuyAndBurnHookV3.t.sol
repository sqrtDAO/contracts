// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {BuyAndBurnHookV3} from "../src/utils/hooks/BuyAndBurnHookV3.sol";
import {ExactInputParams} from "../src/external-interfaces/IUniswapV3SwapRouter.sol";
import {IERC20} from "lib/forge-std/src/interfaces/IERC20.sol";

contract BuyAndBurnHookV3Test is Test {
    ERC20Mock public participationToken;
    ERC20Mock public distributionToken;
    MockSwapRouterV3 public router;
    BuyAndBurnHookV3 public burnHook;

    address public user = address(0x1234);
    uint24 public constant FEE = 3000;
    address public constant BURN_ADDRESS = address(0x000000000000000000000000000000000000dEaD);

    function setUp() public {
        participationToken = new ERC20Mock();
        distributionToken = new ERC20Mock();
        router = new MockSwapRouterV3();
        burnHook = new BuyAndBurnHookV3(address(router));
    }

    function testBuyAndBurnDecodesFirstTokenFromPathAndBurns() public {
        bytes memory path = abi.encodePacked(address(participationToken), FEE, address(distributionToken));

        uint256 amountIn = 100 ether;
        uint256 amountOut = 50 ether;

        participationToken.mint(user, amountIn);
        distributionToken.mint(address(router), amountOut);

        vm.prank(user);
        participationToken.approve(address(burnHook), amountIn);

        vm.prank(user);
        uint256 amountOutReturned = burnHook.buyAndBurn(path);

        assertEq(amountOutReturned, amountOut);
        assertEq(participationToken.balanceOf(user), 0);
        assertEq(participationToken.balanceOf(address(burnHook)), 0);
        assertEq(distributionToken.balanceOf(address(router)), 0);
        assertEq(distributionToken.balanceOf(BURN_ADDRESS), amountOut);
    }
}

contract MockSwapRouterV3 {
    function exactInput(ExactInputParams calldata params) external returns (uint256 amountOut) {
        address tokenIn = address(bytes20(params.path[0:20]));
        address tokenOut = address(bytes20(params.path[23:43]));

        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), params.amountIn), "transfer failed");

        uint256 out = IERC20(tokenOut).balanceOf(address(this));
        if (out > 0) {
            require(IERC20(tokenOut).transfer(params.recipient, out), "transfer failed");
        }
        return out;
    }
}