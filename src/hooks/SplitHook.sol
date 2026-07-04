// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Hook, HookFailure} from "src/utils/Hook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract SplitterHook {
    using SafeERC20 for IERC20;

    event Split(uint256 amount, bytes[] results);

    /**
     * @notice spend all the _token allowance and split funds between _shares
     * @param _token token that this contract spends
     * @param _shares split all the allowance _token between shares (make sure shares sum up to 100%)
     * @dev The caller must have approved this contract to spend _token.
     */
    function splitShares(address _token, Share[] calldata _shares) external {
        IERC20 token = IERC20(_token);

        uint256 amountIn = IERC20(_token).allowance(msg.sender, address(this));
        token.safeTransferFrom(msg.sender, address(this), amountIn);

        bytes[] memory results = new bytes[](_shares.length);

        for (uint256 i = 0; i < _shares.length; i++) {
            Share calldata share = _shares[i];
            token.forceApprove(share.hook.contractAddress, (amountIn * share.shareBps) / 10000);

            (bool success, bytes memory result) = share.hook.contractAddress.call(share.hook.callData);
            if (!success) emit HookFailure(result);
            results[i] = result;

            token.forceApprove(share.hook.contractAddress, 0);
        }

        emit Split(amountIn, results);
    }
}

struct Share {
    uint256 shareBps; // protocol fee in basis points e.g. 50 means 0.5%
    Hook hook;
}
