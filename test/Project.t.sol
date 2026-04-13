// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Project} from "../src/Project.sol";

contract CounterTest is Test {
    Project public project;

    function setUp() public {
        project = new Project();
    }
}
