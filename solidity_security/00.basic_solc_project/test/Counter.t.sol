// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {Counter} from "../src/Counter.sol";

/**
 * @dev Fuzz Test: Random data to one function
 * @dev Invariant Test: Random data & random function calls to many functions
 * 
 * @dev Stateless fuzzing: fuzz test one time and reset state 
 * @dev Stateful fuzzing: fuzz testing without reset state
 * 
 * @dev Foundry fuzzing: stateless fuzzing
 * @dev Foundry Invariant: stateful fuzzing
 */ 
    
// @dev forge test
contract CounterTest is Test {
    Counter public counter;

    function setUp() public {
        counter = new Counter();
        counter.setNumber(0);
    } 

    function test_Increment() public {
        counter.increment();
        assertEq(counter.number(), 1);
    }
    
    /**
     * @dev fuzz testing. testing function 
     * @dev forge test --mt testFuzz_SetNumber 
     */
    function testFuzz_SetNumber(uint256 x) public {
        counter.setNumber(x);
        assertEq(counter.number(), x);
    }
}
