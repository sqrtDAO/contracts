// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ExponentialEmission, ExponentialEmissionConfig} from "../src/utils/emission-function/ExponentialEmission.sol";
import {LinearEmission, LinearEmissionConfig} from "../src/utils/emission-function/LinearEmission.sol";

/// test result:
/// [PASS] testExponentialEmissionGas() (gas: 50826)
/// [PASS] testLinearEmissionGas() (gas: 17694)
/// difference = 66309 - 17694 = 33132
/// to USD -> 0.0055 USD
/// so its half a cent after 1 Million epochs
/// gas price calculated here: https://cryptoneur.xyz/en/gas-fees-calculator
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

    function testExponentialEmissionGas() public view {
        console.log(exp.calculate(expConf, 1_000_000));
    }

    function testLinearEmissionGas() public view {
        console.log(linear.calculate(linearConf, 1_000_000));
    }
}
