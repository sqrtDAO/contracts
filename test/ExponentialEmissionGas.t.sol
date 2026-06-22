// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ExponentialEmission, ExponentialEmissionConfig} from "../src/utils/emission-function/ExponentialEmission.sol";
import {LinearEmission, LinearEmissionConfig} from "../src/utils/emission-function/LinearEmission.sol";

/// test result:
/// [PASS] testExponentialEmissionGas() (gas: 66309)
/// [PASS] testLinearEmissionGas() (gas: 17694)
/// difference = 66309 - 17694 = 48615
/// to USD -> 0.0086 USD
/// so for 10 calculation its 0.08 cents after 1 Million epochs
contract ExponentialEmissionGasTest is Test {
    ExponentialEmission exp;
    LinearEmission linear;

    bytes expConf;
    bytes linearConf;

    function setUp() public {
        exp = new ExponentialEmission();
        linear = new LinearEmission();

        expConf = abi.encode(
            ExponentialEmissionConfig({
                initialAmount: 50 ether, numerator: 9999966993045875, denominator: 10000000000000000
            })
        );
        linearConf = abi.encode(LinearEmissionConfig({base: 50 ether, slope: 1}));
    }

    function testExponentialEmissionGas() public {
        console.log(exp.calculate(expConf, 1_000_000));
    }

    function testLinearEmissionGas() public {
        console.log(linear.calculate(linearConf, 1_000_000));
    }
}
