// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {BuyAndBurnHook} from "../src/utils/hooks/BuyAndBurnHook.sol";
import {BuyBackHook} from "../src/utils/hooks/BuyBackHook.sol";
import {IERC20} from "lib/forge-std/src/interfaces/IERC20.sol";

contract BuyAndBurnHookTest is Test {
    ERC20Mock public participationToken;
    ERC20Mock public distributionToken;
    MockUniswapRouter public router;
    BuyAndBurnHook public burnHook;
    BuyBackHook public buybackHook;

    address public participant = address(0x1234);
    address[] public path;

    address public constant BURN_ADDRESS = address(0x000000000000000000000000000000000000dEaD);

    function setUp() public {
        participationToken = new ERC20Mock();
        distributionToken = new ERC20Mock();
        router = new MockUniswapRouter();

        path = new address[](2);
        path[0] = address(participationToken);
        path[1] = address(distributionToken);

        burnHook = new BuyAndBurnHook();
        buybackHook = new BuyBackHook();
    }

    function testBuyAndBurnSwapsAndBurns() public {
        uint256 amountIn = 100 ether;
        uint256 amountOut = 50 ether;

        participationToken.mint(participant, amountIn);
        distributionToken.mint(address(router), amountOut);

        vm.prank(participant);
        participationToken.approve(address(burnHook), amountIn);

        vm.prank(participant);
        uint256 amountOutReturned = burnHook.buyAndBurn(address(router), path);

        assertEq(amountOutReturned, amountOut);

        assertEq(participationToken.balanceOf(participant), 0);
        assertEq(participationToken.balanceOf(address(burnHook)), 0);
        assertEq(distributionToken.balanceOf(address(burnHook)), 0);
        assertEq(distributionToken.balanceOf(address(router)), 0);
        assertEq(distributionToken.balanceOf(BURN_ADDRESS), amountOut);
    }

    function testBuyAndBurnRevertsWhenSwapReturnsZero() public {
        uint256 amountIn = 10 ether;
        participationToken.mint(participant, amountIn);

        vm.prank(participant);
        participationToken.approve(address(burnHook), amountIn);

        vm.prank(participant);
        vm.expectRevert(bytes("Swap returned zero output"));
        burnHook.buyAndBurn(address(router), path);
    }

    function testBuyBackSwapsAndSendsToCaller() public {
        uint256 amountIn = 100 ether;
        uint256 amountOut = 50 ether;

        participationToken.mint(participant, amountIn);
        distributionToken.mint(address(router), amountOut);

        vm.prank(participant);
        participationToken.approve(address(buybackHook), amountIn);

        vm.prank(participant);
        uint256 amountOutReturned = buybackHook.buyBack(address(router), path);

        assertEq(amountOutReturned, amountOut);

        assertEq(participationToken.balanceOf(participant), 0);
        assertEq(participationToken.balanceOf(address(buybackHook)), 0);
        assertEq(distributionToken.balanceOf(address(buybackHook)), 0);
        assertEq(distributionToken.balanceOf(address(router)), 0);
        assertEq(distributionToken.balanceOf(participant), amountOut);
    }

    function testBuyBackRevertsWhenSwapReturnsZero() public {
        uint256 amountIn = 10 ether;
        participationToken.mint(participant, amountIn);

        vm.prank(participant);
        participationToken.approve(address(buybackHook), amountIn);

        vm.prank(participant);
        vm.expectRevert(bytes("Swap returned zero output"));
        buybackHook.buyBack(address(router), path);
    }
}

contract MockUniswapRouter {
    function swapExactTokensForTokens(uint256 amountIn, uint256, address[] calldata path, address to, uint256)
        external
        returns (uint256[] memory amounts)
    {
        require(path.length >= 2, "Invalid swap path");

        require(IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn), "transfer failed");

        uint256 amountOut = IERC20(path[path.length - 1]).balanceOf(address(this));
        if (amountOut > 0) {
            require(IERC20(path[path.length - 1]).transfer(to, amountOut), "transfer failed");
        }

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
    }
}
