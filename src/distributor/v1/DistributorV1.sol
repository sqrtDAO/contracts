// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Hook, HookFailure} from "src/utils/Hook.sol";
import {IERC20} from "lib/forge-std/src/interfaces/IERC20.sol";
import {EmissionFunction} from "src/utils/emission-function/EmissionFunction.sol";

/// @title Distributor
/// @notice Base template for distributor contracts that perform token transfers to recipients.
/// @dev Extend this contract for versioned implementations like `DistributorV1`.
contract DistributorV1 {
    event Participated(address indexed participant, uint256 fromEpoch, uint256 numEpochs, uint256 amountPerEpoch);
    event Claimed(address indexed claimant, uint256 fromEpoch, uint256 numEpochs, uint256 totalClaimed);

    IERC20 public immutable DISTRIBUTION_TOKEN;
    IERC20 public immutable PARTICIPATION_TOKEN;
    uint256 public immutable EPOCH_DURATION;
    uint256 public immutable STARTING_TIMESTAMP;
    uint256 public immutable PROTOCOL_FEE_INV;
    address public immutable PROTOCOL_FEE_RECEIVER;
    uint256 public immutable MIN_PARTICIPATION;
    uint256 public immutable CLAIM_DELAY_EPOCHS;

    EmissionFunction public emissionFunction;
    Hook public drainHook;

    // total amount users participated to an epoch
    mapping(uint256 => uint256) public epochTotalParticipation;

    // amount user participated to an epoch (sets to zero on claim)
    mapping(uint256 => mapping(address => uint256)) public epochUserParticipation;

    // tracks which epochs have had their drain hook called
    uint256 public nextDrainHookToCall = 0;

    /**
     * @param _distributionToken address of token you want to distribute
     * @param _participationToken address of token contract receive in epochs when user participate
     * @param _epochDuration duration of each epoch (in seconds)
     * @param _startTimestamp time of first epoch starts
     * @param _protocolFeeInv drainAmount/_protocolFeeInv = protocol fee amount e.g. 200 means 0.5%
     * @param _protocolFeeReceiver address that receives protocol fee
     * @param _minParticipation minimum amount per-epoch a participant must provide
     * @param _claimDelayEpochs number of epochs a user must wait after an epoch ends before claiming
     * @param _drainHook contract calls this hook after epoch ends (on first claim)
     * @param _emissionFunction calculates reward of an epoch can be a curve or linear function
     */
    constructor(
        address _distributionToken,
        address _participationToken,
        uint256 _epochDuration,
        uint256 _startTimestamp,
        uint256 _protocolFeeInv,
        address _protocolFeeReceiver,
        uint256 _minParticipation,
        uint256 _claimDelayEpochs,
        Hook memory _drainHook,
        EmissionFunction memory _emissionFunction
    ) {
        DISTRIBUTION_TOKEN = IERC20(_distributionToken);
        PARTICIPATION_TOKEN = IERC20(_participationToken);
        EPOCH_DURATION = _epochDuration;
        STARTING_TIMESTAMP = _startTimestamp;
        PROTOCOL_FEE_INV = _protocolFeeInv;
        PROTOCOL_FEE_RECEIVER = _protocolFeeReceiver;
        MIN_PARTICIPATION = _minParticipation;
        CLAIM_DELAY_EPOCHS = _claimDelayEpochs;
        drainHook = _drainHook;
        emissionFunction = _emissionFunction;
    }

    /**
     * @notice Returns the current epoch number based on the starting block and block timestamp
     * @return The current epoch number.
     */
    function currentEpoch() public view returns (uint256) {
        require(block.timestamp >= STARTING_TIMESTAMP, "Mining has not started yet!");
        return (block.timestamp - STARTING_TIMESTAMP) / EPOCH_DURATION;
    }

    /**
     * @notice Computes reward of an specific epoch.
     * @param epoch The epoch to calculate reward for.
     * @return reward amount
     */
    function rewardOf(uint256 epoch) public view returns (uint256) {
        return emissionFunction.emissionContract.calculate(emissionFunction.curveConfig, epoch);
    }

    /**
     * @notice Allows a user to participate in the reward program by locking tokens for multiple epochs.
     * @dev This function updates the user's participation in the specified number of epochs and transfers the required amount of PARTICIPATION_TOKEN tokens to the contract.
     * @param _amountPerEpoch The amount of tokens to lock per epoch.
     * @param _numEpochs The number of epochs to participate in.
     */
    function participate(uint256 _amountPerEpoch, uint256 _numEpochs) external {
        require(_numEpochs != 0, "Invalid epoch number.");
        require(_amountPerEpoch >= MIN_PARTICIPATION, "Amount below minimum");
        uint256 currEpoch = currentEpoch();
        require(rewardOf(currEpoch) < DISTRIBUTION_TOKEN.balanceOf(address(this)), "No more token to distribute");
        require(
            PARTICIPATION_TOKEN.transferFrom(msg.sender, address(this), _numEpochs * _amountPerEpoch),
            "transferFrom failed"
        );

        for (uint256 i = 0; i < _numEpochs; i++) {
            epochTotalParticipation[currEpoch + i] += _amountPerEpoch;
            epochUserParticipation[currEpoch + i][msg.sender] += _amountPerEpoch;
        }
        emit Participated(msg.sender, currEpoch, _numEpochs, _amountPerEpoch);
    }

    /**
     * @notice Allows a user to claim their rewards for participation in past epochs.
     * @dev Calculates pro-rata reward share using (userAmount / epochTotal) * rewardOf(epoch).
     * Calls drain hook on first claim after each epoch finishes.
     * @param _startingEpoch The starting epoch number from which to claim rewards.
     * @param _numEpochs The number of epochs to claim rewards for.
     */
    function claim(uint256 _startingEpoch, uint256 _numEpochs) public returns (uint256 claimAmount) {
        uint256 currEpoch = currentEpoch();
        require(_startingEpoch + _numEpochs + CLAIM_DELAY_EPOCHS - 1 < currEpoch, "Too soon to claim");

        if (nextDrainHookToCall < currEpoch) {
            callDrainHook();
            nextDrainHookToCall = currEpoch;
        }

        claimAmount = 0;
        for (uint256 i = 0; i < _numEpochs; i++) {
            uint256 epoch = _startingEpoch + i;

            claimAmount += (epochUserParticipation[epoch][msg.sender] * rewardOf(epoch))
                / epochTotalParticipation[epoch];
            epochUserParticipation[epoch][msg.sender] = 0; // prevents double claim
        }

        if (claimAmount > 0) {
            require(DISTRIBUTION_TOKEN.transfer(msg.sender, claimAmount), "transfer failed");
        }
        emit Claimed(msg.sender, _startingEpoch, _numEpochs, claimAmount);
    }

    /**
     * @notice this function not necessary called for each epoch it get called when someone call claim and will drain everything that is not already drained!
     */
    function callDrainHook() public returns (bytes memory) {
        require(
            PARTICIPATION_TOKEN.transfer(
                PROTOCOL_FEE_RECEIVER, PARTICIPATION_TOKEN.balanceOf(address(this)) / PROTOCOL_FEE_INV
            ),
            "transfer failed"
        );

        // approve so drainHook contract can control distributor contract tokens
        PARTICIPATION_TOKEN.approve(drainHook.contractAddress, PARTICIPATION_TOKEN.balanceOf(address(this)));

        (bool success, bytes memory result) = drainHook.contractAddress.call(drainHook.callData);

        if (!success) {
            emit HookFailure(result);
        }

        return result;
    }
}
