// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TokenV1 is ERC20 {
    /// @notice (recipient => amount already minted through claim)
    mapping(address => uint256) public alreadyClaimed;

    /// @notice (recipient => vesting allocation)
    mapping(address => Allocation) public share;

    /**
     * @param _name          Token name
     * @param _symbol        Token symbol
     * @param _allocations    Array of initial allocation structs (recipient + amount + vesting)
     */
    constructor(string memory _name, string memory _symbol, Allocation[] memory _allocations) ERC20(_name, _symbol) {
        require(_allocations.length > 0, "No allocations");
        for (uint256 i = 0; i < _allocations.length; i++) {
            require(_allocations[i].recipient != address(0), "Invalid recipient");
            require(share[_allocations[i].recipient].recipient == address(0), "Duplicate recipient");
            share[_allocations[i].recipient] = _allocations[i];
            // whatever is already vested at deployment is minted right away
            uint256 vested = _vestedAt(_allocations[i], block.timestamp);
            if (vested > 0) {
                alreadyClaimed[_allocations[i].recipient] = vested;
                _mint(_allocations[i].recipient, vested);
            }
        }
    }

    /// @notice mints everything the caller has vested but not claimed yet
    function claim() external {
        uint256 amount = claimableOf(msg.sender);
        require(amount > 0, "Nothing to claim");
        alreadyClaimed[msg.sender] += amount;
        _mint(msg.sender, amount);
    }

    /// @notice amount `_recipient` can claim right now
    function claimableOf(address _recipient) public view returns (uint256) {
        Allocation memory alloc = share[_recipient];
        return _vestedAt(alloc, block.timestamp) - alreadyClaimed[_recipient];
    }

    /// @notice all the info a front-end needs to show for one recipient
    function vestingInfo(address _recipient) external view returns (VestingInfo memory info) {
        Allocation memory alloc = share[_recipient];
        uint256 claimed = alreadyClaimed[_recipient];
        info = VestingInfo({
            allocated: alloc.amount,
            claimed: claimed,
            claimable: _vestedAt(alloc, block.timestamp) - claimed,
            startTime: alloc.startTime,
            duration: alloc.duration,
            fullyVestedAt: alloc.duration == 0 ? alloc.startTime : alloc.startTime + alloc.duration
        });
    }

    /// @notice amount of `_alloc` vested at `_timestamp`
    /// @dev nothing before `startTime`, then linear until `startTime + duration`;
    ///      `duration == 0` means fully vested at `startTime`
    function _vestedAt(Allocation memory _alloc, uint256 _timestamp) internal pure returns (uint256) {
        if (_alloc.amount == 0 || _timestamp < _alloc.startTime) {
            return 0;
        }
        uint256 elapsed = _timestamp - _alloc.startTime;
        if (_alloc.duration == 0 || elapsed >= _alloc.duration) {
            return _alloc.amount;
        }
        return (_alloc.amount * elapsed) / _alloc.duration;
    }
}

struct Allocation {
    address recipient;
    uint256 amount;
    uint256 startTime;
    uint256 duration;
}

struct VestingInfo {
    uint256 allocated;
    uint256 claimed;
    uint256 claimable;
    uint256 startTime;
    uint256 duration;
    uint256 fullyVestedAt;
}
