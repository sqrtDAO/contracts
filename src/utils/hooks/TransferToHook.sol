// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract TransferToHook {
    using SafeERC20 for IERC20;

    event Transferred(address to, uint256 amount);

    /**
     * @notice transfers all msg.sender allowance to specified address
     * @param _token token that operation
     * @param _to the receiver address
     * @dev The caller must have approved this contract to spend _token.
     */
    function transferTo(address _token, address _to) external {
        address sender = msg.sender;
        IERC20 token = IERC20(_token);

        uint256 amount = token.allowance(sender, address(this));
        if (amount == 0) return;

        require(token.transferFrom(sender, _to, amount), "transferFrom failed");

        emit Transferred(_to, amount);
    }
}
