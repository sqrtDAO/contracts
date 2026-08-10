// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Hook, HookLib} from "src/utils/Hook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

struct Share {
    /// formula: (amountIn * share.shareBps) / 10000
    /// protocol fee in basis points e.g. 50 means 0.5%
    uint256 shareBps;
    Hook hook;
}

library SharesLib {
    error SharesNot100Percent();

    function validateShares(Share[] memory shares) internal pure {
        uint256 totalBps;
        for (uint256 i; i < shares.length; ++i) {
            totalBps += shares[i].shareBps;
        }
        if (totalBps != 10000) revert SharesNot100Percent();
    }

    function shareOf(Share memory share, uint256 amount) internal pure returns (uint256) {
        return (amount * share.shareBps) / 10000;
    }

    function approveAndCall(Share memory share, IERC20 asset, uint256 totalAmount)
        internal
        returns (bytes memory returnData)
    {
        uint256 amount = shareOf(share, totalAmount);
        asset.approve(share.hook.contractAddress, amount);
        returnData = HookLib.call(share.hook);
        asset.approve(share.hook.contractAddress, 0);
    }

    function append(Share[] memory shares, Share memory toAdd) internal pure returns (Share[] memory) {
        Share[] memory newShares = new Share[](shares.length + 1);
        for (uint256 i; i < shares.length; ++i) {
            newShares[i] = shares[i];
        }
        newShares[shares.length] = toAdd;
        return newShares;
    }

    function approveAndTryCall(Share memory share, IERC20 asset, uint256 totalAmount) internal {
        uint256 amount = shareOf(share, totalAmount);
        asset.approve(share.hook.contractAddress, amount);
        HookLib.tryCall(share.hook);
        asset.approve(share.hook.contractAddress, 0);
    }
}
