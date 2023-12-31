// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/**
 *  forge inspect Counter storage
 * */ 
contract Counter {
    /// variables saved at slot
    uint256 public number;
    uint256 public number2;
    /// constant saved at bytecode
    uint256 public constant number3 = 1;

    function setNumber(uint256 newNumber) public {
        number = newNumber;
    }

    function increment() public {
        number++;
    }
    /**
     * fallback() works when can't find same function selector that transaction(msg.data) sends
     */
    fallback() external payable {}
    
    /**
     * receive() works when msg.data is empty & transaction includes ether
     */ 
    receive() external payable {}
}
