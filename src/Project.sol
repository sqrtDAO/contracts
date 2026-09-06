// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Project is ERC721, ReentrancyGuard {
    uint256 private _tokenIds;

    struct ProjectMetadata {
        string title;
        string description;
        string logo;
    }

    mapping(uint256 => ProjectMetadata) private _projectMetadata;

    event ProjectCreated(uint256 indexed tokenId, address indexed admin, string title);

    event ProjectMetadataUpdated(uint256 indexed tokenId, string title, string description, string logo);

    constructor() ERC721("sqrtDAO project", "sqrtPRJ") {}

    function createProject(string memory title, string memory description, string memory logo)
        external
        nonReentrant
        returns (uint256)
    {
        uint256 tokenId = _tokenIds;

        _safeMint(msg.sender, tokenId);

        _projectMetadata[tokenId] = ProjectMetadata({title: title, description: description, logo: logo});

        emit ProjectCreated(tokenId, msg.sender, title);

        _tokenIds += 1;
        return tokenId;
    }

    modifier onlyProjectAdmin(uint256 tokenId) {
        _onlyProjectAdmin(tokenId);
        _;
    }

    function _onlyProjectAdmin(uint256 tokenId) internal view {
        require(ownerOf(tokenId) == msg.sender, "Not project admin");
    }

    // ---------------------------
    // Update project metadata
    // ---------------------------
    function updateProjectMetadata(uint256 tokenId, string memory title, string memory description, string memory logo)
        external
        onlyProjectAdmin(tokenId)
    {
        require(tokenId < _tokenIds, "Project does not exist");

        _projectMetadata[tokenId] = ProjectMetadata({title: title, description: description, logo: logo});

        emit ProjectMetadataUpdated(tokenId, title, description, logo);
    }

    // ---------------------------
    // Get project metadata
    // ---------------------------
    function getProjectMetadata(uint256 tokenId) external view returns (ProjectMetadata memory) {
        require(tokenId < _tokenIds, "Project does not exist");
        return _projectMetadata[tokenId];
    }
}
