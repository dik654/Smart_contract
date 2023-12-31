// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

contract Encoding {

    // it works same as string.concat(stringA, stringB);
    function combineStrings() public pure returns (string memory) {
        return string(abi.encodePacked("Hi Mom! ", "Miss you."));
    }

    function encodeNumber() public pure returns (bytes memory) {
        bytes memory number = abi.encode(1);
        // number variable is machine readable version 32bytes length abi
        return number;
    }

    // You'd use this to make calls to contracts
    function encodeString() public pure returns (bytes memory) {
        bytes memory someString = abi.encode("some string");
        // someString return dynamic array type string abi
        return someString;
    }

    function encodeStringPacked() public pure returns (bytes memory) {
        bytes memory someString = abi.encodePacked("some string");
        // someString return without dynamic array type
        // just return binary type string data
        return someString;
    }

    function encodeStringBytes() public pure returns (bytes memory) {
        bytes memory someString = bytes("some string");
        // if abi.encodePacked() has only one argument
        // bytes & abi.encodePacked() returns same result
        return someString;
    }
    
    function decodeString() public pure returns (string memory) {
        // abi.decode interprets abi.encode type data(1st argument)
        // with multiple types(2nd ~ nth arguments)
        string memory someString = abi.decode(encodeString(), (string));
        return someString;
    }

    function multiEncode() public pure returns (bytes memory) {
        // abi.encode with multiple arguments encodes data to abi type
        bytes memory someString = abi.encode("some string", "it's bigger!");
        return someString;
    }

    // Gas: 24612
    function multiDecode() public pure returns (string memory, string memory) {
        // decoding multiple argument abi data
        (string memory someString, string memory someOtherString) = abi.decode(multiEncode(), (string, string));
        return (someString, someOtherString);
    }

    function multiEncodePacked() public pure returns (bytes memory) {
        // abi.encodePacked doesn't encodes data to abi type
        // it's just concated bytes data
        bytes memory someString = abi.encodePacked("some string", "it's bigger!");
        return someString;
    }

    function multiDecodePacked() public pure returns (string memory) {
    // so this doesn't work!
        string memory someString = abi.decode(multiEncodePacked(), (string));
        return someString;
    }

    // Gas: 22313
    function multiStringCastPacked() public pure returns (string memory) {
        // but this does!
        // because abi.encodePacked returns concated bytes data
        // type conversion to string is just interprets bytes to ascii
        string memory someString = string(multiEncodePacked());
        return someString;
    }

    function withdraw(address recentWinner) public {
        // send transaction without msg.data
        // it sends msg.value(address(this).balance) to recentWinner
        (bool success,) = recentWinner.call{value: address(this).balance}("");
        require(success, "Transfer Failed");
    }
}