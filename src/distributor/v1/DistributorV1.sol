// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Hook, HookFailure} from "src/utils/Hook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EmissionFunction} from "src/utils/emission-function/EmissionFunction.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title Distributor
/// @notice Base template for distributor contracts that perform token transfers to recipients.
/// @dev Extend this contract for versioned implementations like `DistributorV1`.
contract DistributorV1 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    event Participated(
        address indexed participant, address recipient, uint256 fromEpoch, uint256 numEpochs, uint256 amountPerEpoch
    );
    event Claimed(address indexed claimant, uint256 fromEpoch, uint256 numEpochs, uint256 totalClaimed);
    event DrainHookCall(bytes result, uint256 amount, uint256 nextDrainHookToCall);
    event ClaimFeeBpsSet(address indexed user, uint256 bps);

    IERC20 public immutable DISTRIBUTION_TOKEN;
    IERC20 public immutable PARTICIPATION_TOKEN;
    uint256 public immutable EPOCH_DURATION;
    uint256 public immutable STARTING_TIMESTAMP;
    uint256 public immutable PROTOCOL_FEE_BPS;
    address public immutable PROTOCOL_FEE_RECEIVER;
    uint256 public immutable MIN_PARTICIPATION;
    uint256 public immutable CLAIM_DELAY_SECONDS;
    bool public immutable ALLOW_FUTURE_EPOCH_PARTICIPATION;
    bool public immutable DRAIN_HOOK_ONLY_PASSED_EPOCHS;
    address public immutable ALLOWLIST_SIGNER;
    uint256 public immutable ALLOWLIST_DEADLINE;
    uint256 public immutable NUMBER_OF_EPOCHS;
    uint256 public immutable TOTAL_DISTRIBUTION_AMOUNT;
    address public immutable CREATOR;

    EmissionFunction public emissionFunction;
    Hook public drainHook;

    // total amount users participated to an epoch
    mapping(uint256 => uint256) public epochTotalParticipation;

    // amount user participated to an epoch (sets to zero on claim)
    mapping(uint256 => mapping(address => uint256)) public epochUserParticipation;

    // tracks which epochs have had their drain hook called
    uint256 public nextDrainHookToCall = 0;

    mapping(address => uint256) public claimFeeBps;

    constructor(
        address _creator,
        uint256 _protocolFeeBps,
        address _protocolFeeReceiver,
        DistributorConfig memory _config
    ) {
        DISTRIBUTION_TOKEN = IERC20(_config.distributionToken);
        PARTICIPATION_TOKEN = IERC20(_config.participationToken);
        EPOCH_DURATION = _config.epochDuration;
        STARTING_TIMESTAMP = _config.startTimestamp;
        PROTOCOL_FEE_BPS = _protocolFeeBps;
        PROTOCOL_FEE_RECEIVER = _protocolFeeReceiver;
        MIN_PARTICIPATION = _config.minParticipation;
        CLAIM_DELAY_SECONDS = _config.claimDelaySeconds;
        ALLOW_FUTURE_EPOCH_PARTICIPATION = _config.allowFutureEpochParticipation;
        DRAIN_HOOK_ONLY_PASSED_EPOCHS = _config.drainHookOnlyPassedEpochs;
        ALLOWLIST_SIGNER = _config.allowlistSigner;
        ALLOWLIST_DEADLINE = _config.allowlistDeadline;
        NUMBER_OF_EPOCHS = _config.numberOfEpochs;
        TOTAL_DISTRIBUTION_AMOUNT = _config.totalDistributionAmount;
        CREATOR = _creator;
        drainHook = _config.drainHook;
        emissionFunction = _config.emissionFunction;
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
     * @notice used to read epochs information
     * @dev pass 0,0 as range if you only want to read general emission information
     * @param user The epoch to calculate reward for.
     * @param range of epochs to get info
     * @return result information of epochs in an specified range
     */
    function getInfo(address user, Range calldata range) external view returns (GetInfoResult memory result) {
        EpochInfo[] memory epochs = new EpochInfo[](range.length);

        for (uint256 i = 0; i < range.length; i++) {
            uint256 epoch = range.from + i;
            epochs[i] = EpochInfo({
                userParticipationAmount: epochUserParticipation[epoch][user],
                totalParticipationAmount: epochTotalParticipation[epoch],
                rewardAmount: rewardOf(epoch)
            });
        }

        return GetInfoResult({
            distributionToken: address(DISTRIBUTION_TOKEN),
            participationToken: address(PARTICIPATION_TOKEN),
            epochDuration: EPOCH_DURATION,
            startingTimestamp: STARTING_TIMESTAMP,
            minParticipation: MIN_PARTICIPATION,
            claimDelaySeconds: CLAIM_DELAY_SECONDS,
            remainingRewards: DISTRIBUTION_TOKEN.balanceOf(address(this)),
            numberOfEpochs: NUMBER_OF_EPOCHS,
            totalDistributionAmount: TOTAL_DISTRIBUTION_AMOUNT,
            creator: CREATOR,
            epochs: epochs
        });
    }

    /**
     * @notice this function finds non zero rewards epochs for specific user
     * @dev used to show what is claimable to the user
     * @param _fromEpoch starts search from this epoch
     * @param _numEpochs keeps searching for this number of epochs (not infinite because of gas limits)
     * @param _user search for this address participation
     * @param _maxFound this function will stop searching when it found _maxFound number of epochs
     * @return nextEpochToSearch is curser of search (send it as _fromEpoch in next call), epochs is array of founded epochs
     */
    function discoverRewards(uint256 _fromEpoch, uint256 _numEpochs, address _user, uint256 _maxFound)
        external
        view
        returns (uint256 nextEpochToSearch, uint256[] memory epochs)
    {
        // Initialize epochs array with maxFound capacity
        epochs = new uint256[](_maxFound);
        uint256 foundCount = 0;

        uint256 maxEpoch = _fromEpoch + _numEpochs;
        uint256 i = _fromEpoch;
        while (i < maxEpoch) {
            // Check if user has claimable reward
            if (epochUserParticipation[i][_user] > 0) {
                epochs[foundCount] = i;
                foundCount++;
                if (foundCount >= _maxFound) {
                    i++;
                    break;
                }
            }
            i++;
        }

        // Resize the array to actual found count
        assembly {
            mstore(epochs, foundCount)
        }

        nextEpochToSearch = i;
    }

    /**
     * @notice Allows a user to participate in the reward program by locking tokens for multiple epochs.
     * @dev Verifies allowlist signature if allowlist is enabled and deadline has not passed.
     * @param _allowlistSignature ECDSA signature signed by ALLOWLIST_SIGNER over keccak256(abi.encode(msg.sender, chainId)) (pass empty if allowlist is disabled)
     */
    function participate(
        uint256 _amountPerEpoch,
        Range calldata _range,
        address _recipient,
        bytes calldata _allowlistSignature
    ) external nonReentrant {
        _verifyAllowlist(_allowlistSignature);
        _participate(_amountPerEpoch, _range, _recipient);
    }

    function _participate(uint256 _amountPerEpoch, Range calldata _range, address _recipient) internal {
        uint256 currEpoch = currentEpoch();
        require(_range.from >= currEpoch, "Passed epoch participation not allowed");
        require(_range.length != 0, "Range length is zero");
        require(_range.from + _range.length <= NUMBER_OF_EPOCHS, "Out of range");
        require(ALLOW_FUTURE_EPOCH_PARTICIPATION || _range.from == currEpoch, "Future epoch participation not allowed");

        require(_amountPerEpoch >= MIN_PARTICIPATION, "Amount below minimum");

        PARTICIPATION_TOKEN.safeTransferFrom(msg.sender, address(this), _range.length * _amountPerEpoch);

        if (_recipient == address(0)) {
            _recipient = msg.sender;
        }

        for (uint256 i = 0; i < _range.length; i++) {
            epochTotalParticipation[_range.from + i] += _amountPerEpoch;
            epochUserParticipation[_range.from + i][_recipient] += _amountPerEpoch;
        }
        emit Participated(msg.sender, _recipient, _range.from, _range.length, _amountPerEpoch);
    }

    /**
     * @notice Verifies that the caller is allowlisted (via ECDSA signature).
     * @dev Skips check if allowlist is disabled (signer == address(0)) or deadline has passed.
     */
    function _verifyAllowlist(bytes calldata _signature) internal view {
        if (ALLOWLIST_SIGNER == address(0)) return;
        if (block.timestamp >= ALLOWLIST_DEADLINE) return;
        bytes32 message = keccak256(abi.encode(msg.sender, block.chainid));
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(message);
        (address recovered, ECDSA.RecoverError error,) = ECDSA.tryRecover(digest, _signature);
        if (error != ECDSA.RecoverError.NoError || recovered != ALLOWLIST_SIGNER) {
            revert("not allowlisted");
        }
    }

    /**
     * @notice Allows a user to claim their rewards for participation in past epochs.
     * @dev Calculates pro-rata reward share using (userAmount / epochTotal) * rewardOf(epoch).
     * Calls drain hook on first claim after each epoch finishes.
     * @param _range from and length.
     */
    function claim(Range calldata _range) public returns (uint256) {
        return claimFor(msg.sender, _range);
    }

    function claimFor(address _user, Range calldata _range) public nonReentrant returns (uint256 claimAmount) {
        uint256 currEpoch = currentEpoch();

        uint256 lastEpochEndTime = STARTING_TIMESTAMP + ((_range.from + _range.length) * EPOCH_DURATION);

        require(block.timestamp >= lastEpochEndTime + CLAIM_DELAY_SECONDS, "Too soon to claim");

        if (nextDrainHookToCall < currEpoch) callDrainHook();

        claimAmount = 0;
        for (uint256 i = 0; i < _range.length; i++) {
            uint256 epoch = _range.from + i;

            if (epochTotalParticipation[epoch] > 0) {
                claimAmount += (epochUserParticipation[epoch][_user] * rewardOf(epoch)) / epochTotalParticipation[epoch];
                epochUserParticipation[epoch][_user] = 0;
            }
        }

        require(claimAmount > 0, "nothing to claim");

        // third party claim fee
        if (msg.sender != _user && claimFeeBps[_user] != 0) {
            uint256 fee = (claimAmount * claimFeeBps[_user]) / 10000;
            DISTRIBUTION_TOKEN.safeTransfer(msg.sender, fee);
            claimAmount -= fee;
        }

        DISTRIBUTION_TOKEN.safeTransfer(_user, claimAmount);

        emit Claimed(_user, _range.from, _range.length, claimAmount);
    }

    function setClaimFeeBps(uint256 _bps) external {
        require(_bps <= 10000, "max 10000 bps");
        claimFeeBps[msg.sender] = _bps;
        emit ClaimFeeBpsSet(msg.sender, _bps);
    }

    /**
     * @notice Allows a user to claim their rewards for participation in multiple claim ranges.
     * @dev Internally calls claim() for each range and returns the total claimed amount.
     * @param ranges Array of ClaimRange structs containing startingEpoch and numEpochs.
     * @return totalClaimed Total amount claimed across all ranges.
     */
    function claimMany(Range[] calldata ranges) external returns (uint256 totalClaimed) {
        for (uint256 i = 0; i < ranges.length; i++) {
            totalClaimed += claim(ranges[i]);
        }
        return totalClaimed;
    }

    /**
     * @notice this function not necessary called for each epoch it get called when someone call claim and will drain everything that is not already drained!
     */
    function callDrainHook() public returns (bytes memory) {
        uint256 fund;
        uint256 currEpoch = currentEpoch();

        if (DRAIN_HOOK_ONLY_PASSED_EPOCHS) {
            for (uint256 i = nextDrainHookToCall; i < currEpoch; i++) {
                fund += epochTotalParticipation[i];
            }
            uint256 balance = PARTICIPATION_TOKEN.balanceOf(address(this));
            if (fund > balance) fund = balance;
        } else {
            fund = PARTICIPATION_TOKEN.balanceOf(address(this));
        }

        uint256 fee = (fund * PROTOCOL_FEE_BPS) / 10000;
        PARTICIPATION_TOKEN.safeTransfer(PROTOCOL_FEE_RECEIVER, fee);

        if (DRAIN_HOOK_ONLY_PASSED_EPOCHS) {
            fund -= fee;
            uint256 balance = PARTICIPATION_TOKEN.balanceOf(address(this));
            if (fund > balance) fund = balance;
        } else {
            fund = PARTICIPATION_TOKEN.balanceOf(address(this));
        }

        PARTICIPATION_TOKEN.forceApprove(drainHook.contractAddress, fund);

        (bool success, bytes memory result) = drainHook.contractAddress.call(drainHook.callData);

        if (!success) {
            emit HookFailure(result);
        }

        PARTICIPATION_TOKEN.forceApprove(drainHook.contractAddress, 0);

        nextDrainHookToCall = currEpoch;

        emit DrainHookCall(result, fund, nextDrainHookToCall);

        return result;
    }
}

/// @param distributionToken address of token you want to distribute
/// @param participationToken address of token contract receive in epochs when user participate
/// @param epochDuration duration of each epoch (in seconds)
/// @param startTimestamp time of first epoch starts
/// @param protocolFeeBps protocol fee in basis points e.g. 50 means 0.5%
/// @param protocolFeeReceiver address that receives protocol fee
/// @param minParticipation minimum amount per-epoch a participant must provide
/// @param claimDelaySeconds number of seconds a user must wait after an epoch ends before claiming
/// @param allowFutureEpochParticipation whether users can participate in future epochs
/// @param drainHook contract called after epoch ends (on first claim)
/// @param emissionFunction calculates reward of an epoch (e.g. curve or linear function)
/// @param drainHookOnlyPassedEpochs if true, drain hook only receives participation tokens for passed epochs instead of all balance
/// @param allowlistSigner address that signs participation permits (address(0) = allowlist disabled)
/// @param allowlistDeadline timestamp after which anyone can participate without a signature
struct DistributorConfig {
    address distributionToken;
    address participationToken;
    uint256 epochDuration;
    uint256 startTimestamp;
    uint256 minParticipation;
    uint256 claimDelaySeconds;
    bool allowFutureEpochParticipation;
    bool drainHookOnlyPassedEpochs;
    Hook drainHook;
    EmissionFunction emissionFunction;
    address allowlistSigner;
    uint256 allowlistDeadline;
    uint256 numberOfEpochs;
    uint256 totalDistributionAmount;
}

struct Range {
    uint256 from;
    uint256 length;
}

struct GetInfoResult {
    address distributionToken;
    address participationToken;

    uint256 epochDuration;
    uint256 startingTimestamp;
    // currentEpoch can be calculated => (NOW - STARTING_TIMESTAMP) / EPOCH_DURATION

    uint256 minParticipation;
    uint256 claimDelaySeconds;

    uint256 remainingRewards;
    uint256 numberOfEpochs;
    uint256 totalDistributionAmount;
    address creator;

    EpochInfo[] epochs;
}

struct EpochInfo {
    // epochNumber can be calculated => RANGE.from + INDEX

    uint256 userParticipationAmount;
    uint256 totalParticipationAmount;

    uint256 rewardAmount;
    // epochPassedTime can be calculated => (NOW - STARTING_TIMESTAMP) % EPOCH_DURATION
    // epochRemainingTime can be calculated => EPOCH_DURATION - epochPassedTime
}
