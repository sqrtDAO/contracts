// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {TokenV1, Allocation} from "../src/launchpad/v1/TokenV1.sol";

contract TokenV1Test is Test {
    TokenV1 token;

    function testDeploymentAndBalances() public {
        Allocation[] memory allocs = new Allocation[](3);
        allocs[0] = Allocation({recipient: address(1), amount: 1000 ether});
        allocs[1] = Allocation({recipient: address(2), amount: 2000 ether});
        allocs[2] = Allocation({recipient: address(3), amount: 500 ether});

        token = new TokenV1("My Token", "MTK", allocs);

        assertEq(token.name(), "My Token");
        assertEq(token.symbol(), "MTK");
        assertEq(token.totalSupply(), 3500 ether);
        assertEq(token.balanceOf(address(1)), 1000 ether);
        assertEq(token.balanceOf(address(2)), 2000 ether);
        assertEq(token.balanceOf(address(3)), 500 ether);
    }

    function testRevertEmptyAllocations() public {
        Allocation[] memory allocs = new Allocation[](0);
        vm.expectRevert("Total supply must be > 0");
        new TokenV1("T", "S", allocs);
    }

    function testRevertZeroAddress() public {
        Allocation[] memory allocs = new Allocation[](1);
        allocs[0] = Allocation({recipient: address(0), amount: 100});
        vm.expectRevert("Invalid recipient");
        new TokenV1("T", "S", allocs);
    }

    function testZeroAmountsAllowed() public {
        Allocation[] memory allocs = new Allocation[](2);
        allocs[0] = Allocation({recipient: address(1), amount: 0});
        allocs[1] = Allocation({recipient: address(2), amount: 500});
        token = new TokenV1("T", "S", allocs);
        assertEq(token.balanceOf(address(1)), 0);
        assertEq(token.totalSupply(), 500);
    }
}
