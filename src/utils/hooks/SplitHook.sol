// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Share, SharesLib} from "src/utils/Shares.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract SplitterHook {
    using SafeERC20 for IERC20;
    using SharesLib for Share;
    using SharesLib for Share[];

    /**
     * @notice spend all the _token allowance and split funds between _shares
     * @param _token token that this contract spends
     * @param _shares split all the allowance _token between shares (make sure shares sum up to 100%)
     * @dev The caller must have approved this contract to spend _token.
     */
    function splitShares(address _token, Share[] calldata _shares) external {
        IERC20 token = IERC20(_token);

        uint256 amountIn = IERC20(_token).allowance(msg.sender, address(this));
        if (amountIn == 0) return;
        token.safeTransferFrom(msg.sender, address(this), amountIn);

        for (uint256 i = 0; i < _shares.length; i++) {
            Share calldata share = _shares[i];
            share.approveAndCall(token, amountIn);
        }
    }
}
