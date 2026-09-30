// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TokenV1, Allocation} from "../src/v1/TokenV1.sol";
import {DistributorV1, DistributorConfig, GetContractInfoResult, ReleasePolicy} from "../src/v1/DistributorV1.sol";
import {IERC7729, MetadataEntry, MetadataStore} from "../src/utils/Metadata.sol";
import {FixedEmission, FixedEmissionConfig} from "../src/utils/emission-function/FixedEmission.sol";
import {EmissionFunction} from "../src/utils/emission-function/EmissionFunction.sol";
import {Share} from "src/utils/Shares.sol";
import {Hook} from "src/utils/Hook.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FactoryV1} from "../src/v1/FactoryV1.sol";
import {TokenV1Factory} from "../src/v1/TokenV1Factory.sol";
import {DistributionV1Factory} from "../src/v1/DistributionV1Factory.sol";
import {TransferToHook} from "src/utils/hooks/TransferToHook.sol";
import {BuyAndBurnHookV3} from "src/utils/hooks/BuyAndBurnHookV3.sol";
import {INonfungiblePositionManager} from "../src/external-interfaces/INonfungiblePositionManager.sol";
import {IPermit2} from "../src/external-interfaces/IPermit2.sol";

contract MetadataTest is Test {
    // mirrored from MetadataStore for `vm.expectEmit`
    event MetadataSet(string key, string value);
    event MetadataLocked(address indexed caller);
    event ContractURIUpdated();
    ERC20Mock distributionToken;
    ERC20Mock participationToken;
    FixedEmission emission;

    address user = address(0x1234);

    function setUp() public {
        vm.warp(1_000);
        distributionToken = new ERC20Mock();
        participationToken = new ERC20Mock();
        emission = new FixedEmission();
    }

    // --- helpers ---

    function _entries(string[] memory keys, string[] memory values) internal pure returns (MetadataEntry[] memory) {
        MetadataEntry[] memory entries = new MetadataEntry[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            entries[i] = MetadataEntry({key: keys[i], value: values[i]});
        }
        return entries;
    }

    function _emptyEntries() internal pure returns (MetadataEntry[] memory) {
        return new MetadataEntry[](0);
    }

    function _token() internal returns (TokenV1) {
        return _token(_emptyEntries(), true, address(this));
    }

    function _token(MetadataEntry[] memory _initialMetadata, bool _editable, address _creator) internal returns (TokenV1) {
        Allocation[] memory allocs = new Allocation[](1);
        allocs[0] = Allocation({recipient: address(this), amount: 1, startTime: 0, duration: 0});
        return new TokenV1("T", "S", allocs, _creator, _initialMetadata, _editable);
    }

    function _distributor(address _creator, MetadataEntry[] memory _initialMetadata, bool _editable)
        internal
        returns (DistributorV1)
    {
        return new DistributorV1(_creator, address(0), _distributorConfig(_initialMetadata, _editable));
    }

    function _distributorConfig(MetadataEntry[] memory _initialMetadata, bool _editable)
        internal
        view
        returns (DistributorConfig memory)
    {
        Share[] memory shares = new Share[](1);
        shares[0] = Share({shareBps: 10000, hook: Hook({contractAddress: address(0), callData: ""})});

        return DistributorConfig({
            distributionToken: address(distributionToken),
            participationToken: address(participationToken),
            epochDuration: 100,
            startTimestamp: 1_000,
            minParticipation: 1 ether,
            claimDelaySeconds: 10,
            allowFutureEpochParticipation: true,
            releasePolicy: ReleasePolicy.Anyone,
            emissionFunction: EmissionFunction({
                emissionContract: emission, curveConfig: abi.encode(FixedEmissionConfig({amount: 1 ether}))
            }),
            shares: shares,
            allowlistSigner: address(0),
            allowlistDeadline: 0,
            numberOfEpochs: 100,
            totalDistributionAmount: 100 ether,
            initialMetadata: _initialMetadata,
            metadataEditable: _editable
        });
    }

    // --- token: initial metadata & standard getters ---

    function testInitialMetadataWrittenAtDeployment() public {
        string[] memory keys = new string[](2);
        keys[0] = "metadata";
        keys[1] = "website";
        string[] memory values = new string[](2);
        values[0] = "ipfs://QmHash";
        values[1] = "https://sqrt.dao";

        TokenV1 token = _token(_entries(keys, values), true, user);

        assertEq(token.owner(), user);
        assertEq(token.metadata(), "ipfs://QmHash");
        assertEq(token.contractURI(), "ipfs://QmHash");
        assertEq(token.tokenURI(), "ipfs://QmHash");
        assertEq(token.getMetadata("website"), "https://sqrt.dao");
        MetadataEntry[] memory entries = token.getAllMetadata();
        assertEq(entries.length, 2);
        assertEq(entries[0].key, "metadata");
        assertEq(entries[0].value, "ipfs://QmHash");
        assertEq(entries[1].key, "website");
        assertEq(entries[1].value, "https://sqrt.dao");
        assertFalse(token.metadataLocked());
    }

    function testNoMetadataByDefault() public {
        TokenV1 token = _token();
        assertEq(token.metadata(), "");
        MetadataEntry[] memory entries = token.getAllMetadata();
        assertEq(entries.length, 0);
    }

    function testSetMetadataAddsAndUpdatesKeys() public {
        TokenV1 token = _token();
        token.setMetadata("website", "https://a.xyz");
        token.setMetadata("website", "https://b.xyz"); // update, no duplicate key
        token.setMetadata("twitter", "@sqrt");

        assertEq(token.getMetadata("website"), "https://b.xyz");
        assertEq(token.getMetadata("twitter"), "@sqrt");
        MetadataEntry[] memory entries = token.getAllMetadata();
        assertEq(entries.length, 2);
    }

    function testSetMetadataEmptyValueClearsKey() public {
        TokenV1 token = _token();
        token.setMetadata("website", "https://a.xyz");
        token.setMetadata("website", ""); // clears

        assertEq(token.getMetadata("website"), "");
        MetadataEntry[] memory entries = token.getAllMetadata();
        assertEq(entries.length, 0);

        // re-setting after clearing works
        token.setMetadata("website", "https://b.xyz");
        assertEq(token.getMetadata("website"), "https://b.xyz");
        entries = token.getAllMetadata();
        assertEq(entries.length, 1);
    }

    function testSetMetadataManySetsUpdatesAndClears() public {
        TokenV1 token = _token();

        string[] memory keys = new string[](2);
        keys[0] = "website";
        keys[1] = "twitter";
        string[] memory values = new string[](2);
        values[0] = "https://sqrt.dao";
        values[1] = "@sqrt";
        token.setMetadataMany(_entries(keys, values));

        assertEq(token.getMetadata("website"), "https://sqrt.dao");
        assertEq(token.getMetadata("twitter"), "@sqrt");
        MetadataEntry[] memory all = token.getAllMetadata();
        assertEq(all.length, 2);

        // one tx: update website, add docs, clear twitter
        string[] memory keys2 = new string[](3);
        keys2[0] = "website";
        keys2[1] = "docs";
        keys2[2] = "twitter";
        string[] memory values2 = new string[](3);
        values2[0] = "https://new.xyz";
        values2[1] = "https://docs.sqrt.dao";
        values2[2] = "";
        token.setMetadataMany(_entries(keys2, values2));

        assertEq(token.getMetadata("website"), "https://new.xyz");
        assertEq(token.getMetadata("docs"), "https://docs.sqrt.dao");
        assertEq(token.getMetadata("twitter"), "");
        all = token.getAllMetadata();
        assertEq(all.length, 2);
    }

    function testSetMetadataManyRevertsAtomicallyOnEmptyKey() public {
        TokenV1 token = _token();
        string[] memory keys = new string[](2);
        keys[0] = "website";
        keys[1] = "";
        string[] memory values = new string[](2);
        values[0] = "https://sqrt.dao";
        values[1] = "x";

        vm.expectRevert("empty metadata key");
        token.setMetadataMany(_entries(keys, values));

        // atomic: the valid first entry rolled back too
        assertEq(token.getMetadata("website"), "");
    }

    function testRevertSetMetadataManyNotOwner() public {
        TokenV1 token = _token(_emptyEntries(), true, user);
        string[] memory keys = new string[](1);
        keys[0] = "website";
        string[] memory values = new string[](1);
        values[0] = "https://sqrt.dao";
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        token.setMetadataMany(_entries(keys, values));
    }

    function testDistributorSetMetadataMany() public {
        DistributorV1 distributor = _distributor(user, _emptyEntries(), true);
        string[] memory keys = new string[](1);
        keys[0] = "metadata";
        string[] memory values = new string[](1);
        values[0] = "ipfs://QmHash";

        vm.prank(user);
        distributor.setMetadataMany(_entries(keys, values));

        assertEq(distributor.metadata(), "ipfs://QmHash");
        assertEq(distributor.contractURI(), "ipfs://QmHash");
    }

    function testRevertEmptyKey() public {
        TokenV1 token = _token();
        vm.expectRevert("empty metadata key");
        token.setMetadata("", "value");
    }

    function testAliasesFollowReservedKey() public {
        TokenV1 token = _token();
        token.setMetadata("metadata", "ipfs://QmHash");
        assertEq(token.metadata(), "ipfs://QmHash");
        assertEq(token.contractURI(), "ipfs://QmHash");
        assertEq(token.tokenURI(), "ipfs://QmHash");

        token.setMetadata("metadata", "");
        assertEq(token.metadata(), "");
        assertEq(token.contractURI(), "");
        assertEq(token.tokenURI(), "");
    }

    function testEventsOnReservedKeyChange() public {
        TokenV1 token = _token();
        vm.expectEmit(address(token));
        emit MetadataSet("metadata", "ipfs://QmHash");
        vm.expectEmit(address(token));
        emit ContractURIUpdated();
        token.setMetadata("metadata", "ipfs://QmHash");
    }

    function testSupportsInterface() public {
        TokenV1 token = _token();
        assertTrue(token.supportsInterface(type(IERC165).interfaceId));
        assertTrue(token.supportsInterface(type(IERC7729).interfaceId));
        assertFalse(token.supportsInterface(0xdeadbeef));
    }

    // --- token: authorization & lock ---

    function testRevertSetMetadataNotOwner() public {
        TokenV1 token = _token(_emptyEntries(), true, user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        token.setMetadata("website", "https://sqrt.dao");
    }

    function testRevertLockNotOwner() public {
        TokenV1 token = _token(_emptyEntries(), true, user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        token.lockMetadata();
    }

    function testLockMakesMetadataImmutableForever() public {
        TokenV1 token = _token();
        token.setMetadata("metadata", "ipfs://QmHash");

        vm.expectEmit(address(token));
        emit MetadataLocked(address(this));
        token.lockMetadata();

        assertTrue(token.metadataLocked());
        assertTrue(token.metadataLocked());
        vm.expectRevert("metadata frozen");
        token.setMetadata("metadata", "https://evil.xyz");
        vm.expectRevert("metadata frozen");
        token.setMetadata("website", "https://evil.xyz");
        vm.expectRevert("metadata locked");
        token.lockMetadata();
        // data is untouched
        assertEq(token.metadata(), "ipfs://QmHash");
    }

    function testNonEditableTokenFrozenFromLaunch() public {
        string[] memory keys = new string[](1);
        keys[0] = "metadata";
        string[] memory values = new string[](1);
        values[0] = "ipfs://QmHash";
        TokenV1 token = _token(_entries(keys, values), false, user);

        // launch-time pairs are written, but the contract is born pre-locked: everything is frozen forever
        assertEq(token.metadata(), "ipfs://QmHash");
        assertTrue(token.metadataLocked());

        vm.prank(user);
        vm.expectRevert("metadata frozen");
        token.setMetadata("metadata", "https://other.xyz");
        vm.prank(user);
        vm.expectRevert("metadata locked");
        token.lockMetadata();
    }

    function testInstancesShareIdenticalDeployedBytecodeWithDifferentMetadata() public {
        // storage (not immutable) metadata fields keep runtime bytecode identical across instances,
        // which the etherscan auto-verification flow relies on
        string[] memory keys = new string[](1);
        keys[0] = "metadata";
        string[] memory values = new string[](1);
        values[0] = "ipfs://QmHash";

        TokenV1 a = _token(_emptyEntries(), true, address(1));
        TokenV1 b = _token(_entries(keys, values), false, address(2));
        assertEq(address(a).codehash, address(b).codehash);
    }

    // --- distributor metadata ---

    function testDistributorInitialMetadataAndCreatorAccess() public {
        string[] memory keys = new string[](2);
        keys[0] = "metadata";
        keys[1] = "website";
        string[] memory values = new string[](2);
        values[0] = "ipfs://QmHash";
        values[1] = "https://sqrt.dao";

        DistributorV1 distributor = _distributor(user, _entries(keys, values), true);

        assertEq(distributor.owner(), user);
        assertEq(distributor.metadata(), "ipfs://QmHash");
        assertEq(distributor.contractURI(), "ipfs://QmHash");

        vm.prank(user);
        distributor.setMetadata("docs", "https://docs.sqrt.dao");
        assertEq(distributor.getMetadata("docs"), "https://docs.sqrt.dao");

        GetContractInfoResult memory info = distributor.getContractInfo();
        assertFalse(info.metadataLocked);
    }

    function testDistributorRevertSetMetadataNotOwner() public {
        DistributorV1 distributor = _distributor(user, _emptyEntries(), true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        distributor.setMetadata("website", "https://sqrt.dao");
    }

    // --- ownership transfer (Ownable authority) ---

    function testOwnershipTransferMovesMetadataAuthority() public {
        TokenV1 token = _token(_emptyEntries(), true, user);

        vm.prank(user);
        token.transferOwnership(address(0xBEEF));

        // new owner can edit, old owner cannot
        vm.prank(address(0xBEEF));
        token.setMetadata("metadata", "ipfs://QmHash");
        assertEq(token.metadata(), "ipfs://QmHash");
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        token.setMetadata("metadata", "https://old.xyz");
    }

    function testTransferAfterLockDoesNotUnfreeze() public {
        TokenV1 token = _token();
        token.setMetadata("metadata", "ipfs://QmHash");
        token.lockMetadata();

        token.transferOwnership(address(0xBEEF));

        vm.prank(address(0xBEEF));
        vm.expectRevert("metadata frozen");
        token.setMetadata("metadata", "https://new.xyz");
        vm.prank(address(0xBEEF));
        vm.expectRevert("metadata locked");
        token.lockMetadata();
        assertEq(token.metadata(), "ipfs://QmHash");
    }

    function testDistributorOwnershipTransferMovesReleaseAuthority() public {
        DistributorV1 distributor = _distributor(user, _emptyEntries(), true);

        vm.prank(user);
        distributor.transferOwnership(address(0xBEEF));

        // new owner can change the release policy, old owner cannot
        vm.prank(address(0xBEEF));
        distributor.setReleasePolicy(ReleasePolicy.Anyone);
        assertEq(uint8(distributor.RELEASE_POLICY()), uint8(ReleasePolicy.Anyone));
        vm.prank(user);
        vm.expectRevert(bytes("only creator"));
        distributor.setReleasePolicy(ReleasePolicy.Creator);
    }

    function testRenouncedOwnershipBricksCreatorReleasePolicy() public {
        // documented footgun: renouncing makes the `Creator` policy unable to release forever
        DistributorConfig memory config = _distributorConfig(_emptyEntries(), true);
        config.releasePolicy = ReleasePolicy.Creator;
        DistributorV1 distributor = new DistributorV1(user, address(0), config);

        vm.prank(user);
        distributor.renounceOwnership();
        assertEq(distributor.owner(), address(0));

        vm.expectRevert(bytes("only creator"));
        distributor.releaseEpochFunds();
    }

    function testDistributorLockAndFreeze() public {
        DistributorV1 distributor = _distributor(user, _emptyEntries(), true);

        vm.prank(user);
        distributor.lockMetadata();
        assertTrue(distributor.metadataLocked());

        vm.prank(user);
        vm.expectRevert("metadata frozen");
        distributor.setMetadata("metadata", "ipfs://QmHash");
    }

    function testDistributorNonEditableFrozenFromLaunch() public {
        string[] memory keys = new string[](1);
        keys[0] = "metadata";
        string[] memory values = new string[](1);
        values[0] = "ipfs://QmHash";

        DistributorV1 distributor = _distributor(user, _entries(keys, values), false);

        assertEq(distributor.metadata(), "ipfs://QmHash");
        assertTrue(distributor.metadataLocked());
        vm.prank(user);
        vm.expectRevert("metadata frozen");
        distributor.setMetadata("metadata", "https://other.xyz");
    }

    // --- factory threading ---

    function testFactoryCreateTokenThreadsMetadata() public {
        TokenV1Factory tokenFactory = new TokenV1Factory();
        FactoryV1 factory = new FactoryV1(
            address(0xCAFE),
            0,
            new TransferToHook(),
            new BuyAndBurnHookV3(address(0x0)),
            INonfungiblePositionManager(address(0x1)),
            IPermit2(address(0x2)),
            tokenFactory,
            new DistributionV1Factory()
        );

        string[] memory keys = new string[](1);
        keys[0] = "metadata";
        string[] memory values = new string[](1);
        values[0] = "ipfs://QmHash";

        Allocation[] memory allocs = new Allocation[](1);
        allocs[0] = Allocation({recipient: user, amount: 1 ether, startTime: 0, duration: 0});

        vm.prank(user);
        address tokenAddress = factory.createToken("T", "S", allocs, _entries(keys, values), true);

        TokenV1 token = TokenV1(tokenAddress);
        assertEq(token.owner(), user);
        assertEq(token.metadata(), "ipfs://QmHash");

        vm.prank(user);
        token.setMetadata("website", "https://sqrt.dao");
        assertEq(token.getMetadata("website"), "https://sqrt.dao");
    }

    function testFactoryCreateDistributorThreadsMetadata() public {
        distributionToken.mint(user, 100 ether);
        TokenV1Factory tokenFactory = new TokenV1Factory();
        FactoryV1 factory = new FactoryV1(
            address(0xCAFE),
            0,
            new TransferToHook(),
            new BuyAndBurnHookV3(address(0x0)),
            INonfungiblePositionManager(address(0x1)),
            IPermit2(address(0x2)),
            tokenFactory,
            new DistributionV1Factory()
        );

        string[] memory keys = new string[](1);
        keys[0] = "metadata";
        string[] memory values = new string[](1);
        values[0] = "ipfs://QmHash";

        DistributorConfig memory config = _distributorConfig(_entries(keys, values), true);

        vm.startPrank(user);
        distributionToken.approve(address(factory), 100 ether);
        address distributorAddress = factory.createDistributor(config, true);
        vm.stopPrank();

        assertEq(DistributorV1(distributorAddress).owner(), user);
        assertEq(DistributorV1(distributorAddress).contractURI(), "ipfs://QmHash");
    }
}