// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TokenV1, Allocation, VestingInfo} from "../src/v1/TokenV1.sol";

contract TokenV1Test is Test {
    TokenV1 token;

    uint256 constant AMOUNT = 1000 ether;
    uint256 constant START = 1000;
    uint256 constant DURATION = 1000;

    function testDeploymentAndBalances() public {
        Allocation[] memory allocs = new Allocation[](3);
        allocs[0] = Allocation({recipient: address(1), amount: 1000 ether, startTime: 0, duration: 0});
        allocs[1] = Allocation({recipient: address(2), amount: 2000 ether, startTime: 0, duration: 0});
        allocs[2] = Allocation({recipient: address(3), amount: 500 ether, startTime: 0, duration: 0});

        token = new TokenV1("My Token", "MTK", allocs);

        assertEq(token.name(), "My Token");
        assertEq(token.symbol(), "MTK");
        // immediate allocations are minted at deployment
        assertEq(token.totalSupply(), 3500 ether);
        assertEq(token.balanceOf(address(1)), 1000 ether);
        assertEq(token.balanceOf(address(2)), 2000 ether);
        assertEq(token.balanceOf(address(3)), 500 ether);
        assertEq(token.vestingInfo(address(1)).allocated, 1000 ether);
        assertEq(token.vestingInfo(address(1)).claimed, 1000 ether);
        assertEq(token.vestingInfo(address(1)).claimable, 0);
        assertEq(token.alreadyClaimed(address(1)), 1000 ether);

        vm.prank(address(1));
        vm.expectRevert("Nothing to claim");
        token.claim();
    }

    function testRevertEmptyAllocations() public {
        Allocation[] memory allocs = new Allocation[](0);
        vm.expectRevert("No allocations");
        new TokenV1("T", "S", allocs);
    }

    function testRevertZeroAddress() public {
        Allocation[] memory allocs = new Allocation[](1);
        allocs[0] = Allocation({recipient: address(0), amount: 100, startTime: 0, duration: 0});
        vm.expectRevert("Invalid recipient");
        new TokenV1("T", "S", allocs);
    }

    function testRevertDuplicateRecipient() public {
        Allocation[] memory allocs = new Allocation[](2);
        allocs[0] = Allocation({recipient: address(1), amount: 100, startTime: 0, duration: 0});
        allocs[1] = Allocation({recipient: address(1), amount: 200, startTime: 0, duration: 0});
        vm.expectRevert("Duplicate recipient");
        new TokenV1("T", "S", allocs);
    }

    function testZeroAmountsAllowed() public {
        Allocation[] memory allocs = new Allocation[](2);
        allocs[0] = Allocation({recipient: address(1), amount: 0, startTime: 0, duration: 0});
        allocs[1] = Allocation({recipient: address(2), amount: 500, startTime: 0, duration: 0});
        token = new TokenV1("T", "S", allocs);
        assertEq(token.vestingInfo(address(1)).allocated, 0);
        assertEq(token.balanceOf(address(2)), 500);
        assertEq(token.totalSupply(), 500);
    }

    function _vestingToken(uint256 _amount, uint256 _startTime, uint256 _duration) internal returns (TokenV1) {
        Allocation[] memory allocs = new Allocation[](1);
        allocs[0] = Allocation({recipient: address(this), amount: _amount, startTime: _startTime, duration: _duration});
        return new TokenV1("T", "S", allocs);
    }

    function testFullyVestedAtDeploymentMints() public {
        vm.warp(5000);
        token = _vestingToken(AMOUNT, 4000, 1000);
        // vesting window fully passed before deployment -> minted in constructor
        assertEq(token.totalSupply(), AMOUNT);
        assertEq(token.balanceOf(address(this)), AMOUNT);
        assertEq(token.alreadyClaimed(address(this)), AMOUNT);
        assertEq(token.vestingInfo(address(this)).claimable, 0);
        vm.expectRevert("Nothing to claim");
        token.claim();
    }

    function testPartialVestedAtDeploymentMintsAccrued() public {
        vm.warp(4500);
        token = _vestingToken(AMOUNT, 4000, 1000);
        // half the vesting window passed before deployment -> accrued half is minted at deployment
        assertEq(token.totalSupply(), AMOUNT / 2);
        assertEq(token.balanceOf(address(this)), AMOUNT / 2);
        assertEq(token.alreadyClaimed(address(this)), AMOUNT / 2);
        assertEq(token.claimableOf(address(this)), 0);

        // rest is claimable when the window ends
        vm.warp(5000);
        assertEq(token.claimableOf(address(this)), AMOUNT / 2);
        token.claim();
        assertEq(token.balanceOf(address(this)), AMOUNT);
        assertEq(token.totalSupply(), AMOUNT);
    }

    function testRevertClaimBeforeCliff() public {
        token = _vestingToken(AMOUNT, START, DURATION);
        vm.warp(START - 1);
        assertEq(token.claimableOf(address(this)), 0);
        vm.expectRevert("Nothing to claim");
        token.claim();
    }

    function testClaimAtCliffIsZero() public {
        token = _vestingToken(AMOUNT, START, DURATION);
        vm.warp(START);
        assertEq(token.claimableOf(address(this)), 0);
        vm.expectRevert("Nothing to claim");
        token.claim();
    }

    function testClaimLinearVesting() public {
        token = _vestingToken(AMOUNT, START, DURATION);
        vm.warp(START + DURATION / 2);
        assertEq(token.claimableOf(address(this)), AMOUNT / 2);
        token.claim();
        assertEq(token.balanceOf(address(this)), AMOUNT / 2);
        assertEq(token.alreadyClaimed(address(this)), AMOUNT / 2);
        assertEq(token.totalSupply(), AMOUNT / 2);

        vm.warp(START + DURATION);
        assertEq(token.claimableOf(address(this)), AMOUNT - AMOUNT / 2);
        token.claim();
        assertEq(token.balanceOf(address(this)), AMOUNT);
        assertEq(token.totalSupply(), AMOUNT);
        vm.expectRevert("Nothing to claim");
        token.claim();
    }

    function testClaimAfterFullVesting() public {
        token = _vestingToken(AMOUNT, START, DURATION);
        vm.warp(START + DURATION + 100);
        assertEq(token.claimableOf(address(this)), AMOUNT);
        token.claim();
        assertEq(token.balanceOf(address(this)), AMOUNT);
    }

    function testClaimDurationZeroImmediate() public {
        token = _vestingToken(AMOUNT, START, 0);
        vm.warp(START);
        assertEq(token.claimableOf(address(this)), AMOUNT);
        VestingInfo memory info = token.vestingInfo(address(this));
        assertEq(info.fullyVestedAt, START);
        token.claim();
        assertEq(token.balanceOf(address(this)), AMOUNT);
    }

    function testClaimNoAllocation() public {
        token = _vestingToken(AMOUNT, START, DURATION);
        vm.prank(address(0xBEEF));
        vm.expectRevert("Nothing to claim");
        token.claim();
    }

    function testVestingRoundsDown() public {
        token = _vestingToken(1000, START, 3);
        vm.warp(START + 1);
        assertEq(token.claimableOf(address(this)), 333);
        vm.warp(START + 2);
        assertEq(token.claimableOf(address(this)), 666);
    }

    function testVestingInfo() public {
        token = _vestingToken(AMOUNT, START, DURATION);
        vm.warp(START + DURATION / 2);
        VestingInfo memory info = token.vestingInfo(address(this));
        assertEq(info.allocated, AMOUNT);
        assertEq(info.claimed, 0);
        assertEq(info.claimable, AMOUNT / 2);
        assertEq(info.startTime, START);
        assertEq(info.duration, DURATION);
        assertEq(info.fullyVestedAt, START + DURATION);

        token.claim();

        info = token.vestingInfo(address(this));
        assertEq(info.claimed, AMOUNT / 2);
        assertEq(info.claimable, 0);

        vm.warp(START + DURATION);
        info = token.vestingInfo(address(this));
        assertEq(info.claimable, AMOUNT - AMOUNT / 2);
    }

    function testVestingInfoUnknownAddress() public {
        token = _vestingToken(AMOUNT, START, DURATION);
        VestingInfo memory info = token.vestingInfo(address(0xBEEF));
        assertEq(info.allocated, 0);
        assertEq(info.claimed, 0);
        assertEq(info.claimable, 0);
        assertEq(info.startTime, 0);
        assertEq(info.duration, 0);
        assertEq(info.fullyVestedAt, 0);
    }

    function testInstancesShareIdenticalDeployedBytecode() public {
        Allocation[] memory allocsA = new Allocation[](1);
        allocsA[0] = Allocation({recipient: address(1), amount: 1000 ether, startTime: 0, duration: 0});

        Allocation[] memory allocsB = new Allocation[](2);
        allocsB[0] = Allocation({recipient: address(2), amount: 1, startTime: 999, duration: 12345});
        allocsB[1] = Allocation({recipient: address(3), amount: 500 ether, startTime: 1, duration: 999});

        TokenV1 a = new TokenV1("AAA", "AAA", allocsA);
        TokenV1 b = new TokenV1("Some Really Long Token Name", "LONGSYMBOL", allocsB);

        assertEq(address(a).codehash, address(b).codehash);
    }
}
