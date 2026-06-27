// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {BuyAndBurnHook} from "../src/hooks/BuyAndBurnHook.sol";
import {IERC20} from "lib/forge-std/src/interfaces/IERC20.sol";

contract BuyAndBurnHookTest is Test {
    ERC20Mock public participationToken;
    ERC20Mock public distributionToken;
    MockUniswapRouter public router;
    BuyAndBurnHook public hook;

    address public participant = address(0x1234);

    function setUp() public {
        participationToken = new ERC20Mock();
        distributionToken = new ERC20Mock();
        router = new MockUniswapRouter();

        address[] memory path = new address[](2);
        path[0] = address(participationToken);
        path[1] = address(distributionToken);

        hook = new BuyAndBurnHook(address(router), path);
    }

    function testExecuteSwapsAndBurnsDistributionToken() public {
        uint256 amountIn = 100 ether;
        uint256 amountOut = 50 ether;

        participationToken.mint(participant, amountIn);
        distributionToken.mint(address(router), amountOut);

        vm.prank(participant);
        participationToken.approve(address(hook), amountIn);

        vm.prank(participant);
        bytes memory result = hook.execute();

        uint256[] memory amounts = abi.decode(result, (uint256[]));
        assertEq(amounts.length, 2);
        assertEq(amounts[0], amountIn);
        assertEq(amounts[1], amountOut);

        assertEq(participationToken.balanceOf(participant), 0);
        assertEq(participationToken.balanceOf(address(hook)), 0);
        assertEq(distributionToken.balanceOf(address(hook)), 0);
        assertEq(distributionToken.balanceOf(address(router)), 0);
        assertEq(distributionToken.balanceOf(address(0x000000000000000000000000000000000000dEaD)), amountOut);
    }

    function testExecuteRevertsWhenSwapReturnsZero() public {
        uint256 amountIn = 10 ether;
        participationToken.mint(participant, amountIn);

        vm.prank(participant);
        participationToken.approve(address(hook), amountIn);

        vm.prank(participant);
        vm.expectRevert(bytes("Swap returned zero output"));
        hook.execute();
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
