// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MetadataStore
/// @notice Reusable owner-gated on-chain key/value metadata with a one-time irreversible lock.
/// @dev Inherits OpenZeppelin `Ownable`: the launch caller becomes the initial owner and may transfer
///      or renounce it with the standard `transferOwnership()`/`renounceOwnership()`.
///      Metadata is a simple list of key/value pairs — lookups are linear scans, which is fine for
///      the handful of keys these contracts hold.
///      The reserved key `"metadata"` holds the metadata URI (or a `data:application/json;utf8,{...}`
///      blob) returned by the standard getters: `metadata()` (ERC-7729), `contractURI()` (ERC-7572)
///      and — on tokens — `tokenURI()` (EIP-1046). All other keys are free-form for frontends.
///      Launching with `_metadataEditable == false` is equivalent to launching pre-locked:
///      the launch-time pairs are written and metadata is frozen forever.
abstract contract MetadataStore is Ownable {
    /// @notice all currently set metadata pairs (removals swap the last entry into the freed slot)
    MetadataEntry[] private _entries;

    /// @notice true = frozen forever: either the owner locked it, or the contract launched non-editable
    bool public metadataLocked;

    event MetadataSet(string key, string value);
    event MetadataLocked(address indexed caller);
    /// @notice ERC-7572 event, emitted whenever contract-level metadata changes
    event ContractURIUpdated();

    /// @param _initialOwner launch caller, becomes the owner and may edit metadata until it is locked
    /// @param _initialMetadata key/value pairs written at deployment
    /// @param _metadataEditable false = metadata is frozen forever after deployment
    constructor(address _initialOwner, MetadataEntry[] memory _initialMetadata, bool _metadataEditable)
        Ownable(_initialOwner)
    {
        metadataLocked = !_metadataEditable;
        for (uint256 i = 0; i < _initialMetadata.length; i++) {
            _setMetadata(_initialMetadata[i]);
        }
    }

    /// @notice metadata URI/JSON stored under the reserved `"metadata"` key (ERC-7729 getter)
    /// @return the reserved key value (empty string when unset)
    function metadata() public view returns (string memory) {
        return _get("metadata");
    }

    /// @notice contract-level metadata (ERC-7572 getter) — same value as `metadata()`
    function contractURI() external view returns (string memory) {
        return _get("metadata");
    }

    /// @notice value stored for one key (linear scan over the entries)
    /// @param _key metadata key
    /// @return the stored value (empty string when the key is not set)
    function getMetadata(string memory _key) external view returns (string memory) {
        return _get(_key);
    }

    /// @notice all key/value pairs in a single call
    function getAllMetadata() external view returns (MetadataEntry[] memory) {
        return _entries;
    }

    /// @notice sets/updates one metadata key; an empty value clears the key
    /// @param _key metadata key (must be non-empty)
    /// @param _value new value (empty = clear the key)
    function setMetadata(string memory _key, string memory _value) public onlyOwner {
        require(!metadataLocked, "metadata frozen");
        _setMetadata(MetadataEntry(_key, _value));
    }

    /// @notice sets/updates multiple metadata keys in one transaction; an empty value clears the key
    /// @param params key/value pairs applied in order (atomic — one invalid entry reverts everything)
    function setMetadataMany(MetadataEntry[] calldata params) external onlyOwner {
        require(!metadataLocked, "metadata frozen");
        for (uint256 i = 0; i < params.length; i++) {
            setMetadata(params[i].key, params[i].value);
        }
    }

    /// @notice one-time irreversible lock; afterwards no metadata can ever change
    function lockMetadata() external onlyOwner {
        require(!metadataLocked, "metadata locked");
        metadataLocked = true;
        emit MetadataLocked(msg.sender);
    }

    function _get(string memory _key) private view returns (string memory) {
        bytes32 keyHash = keccak256(bytes(_key));
        for (uint256 i = 0; i < _entries.length; i++) {
            if (keccak256(bytes(_entries[i].key)) == keyHash) {
                return _entries[i].value;
            }
        }
        return "";
    }

    function _setMetadata(MetadataEntry memory _entry) private {
        require(bytes(_entry.key).length > 0, "empty metadata key");
        bytes32 keyHash = keccak256(bytes(_entry.key));

        for (uint256 i = 0; i < _entries.length; i++) {
            if (keccak256(bytes(_entries[i].key)) == keyHash) {
                if (bytes(_entry.value).length == 0) {
                    // empty value clears the key (swap-and-pop)
                    _entries[i] = _entries[_entries.length - 1];
                    _entries.pop();
                } else {
                    _entries[i].value = _entry.value;
                }
                emit MetadataSet(_entry.key, _entry.value);
                if (keyHash == keccak256("metadata")) emit ContractURIUpdated();
                return;
            }
        }

        // key not set: only non-empty values add a new entry
        if (bytes(_entry.value).length > 0) {
            _entries.push(_entry);
        }
        emit MetadataSet(_entry.key, _entry.value);
        if (keyHash == keccak256("metadata")) emit ContractURIUpdated();
    }
}

/// @notice ERC-7729 "Token with Metadata" interface (needed for the ERC-165 interface id)
interface IERC7729 {
    function metadata() external view returns (string memory);
}

/// @notice one key/value pair of on-chain metadata
struct MetadataEntry {
    string key;
    string value;
}