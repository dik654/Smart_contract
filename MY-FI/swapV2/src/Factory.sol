// SPDX-License-Identifier: GLP v3.0
pragma solidity ^0.8.19;

import './interfaces/IFactory.sol';
import './CPMM.sol';

contract Factory is IFactory {
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    function createPair(address _tokenA, address _tokenB) external returns (address pair) {
        require(_tokenA != _tokenB, 'CREATE_PAIR:IDENTICAL_ADDRESSES');
        (address token0, address token1) = _tokenA < _tokenB ? (_tokenA, _tokenB) : (_tokenB, _tokenA);
        require(token0 != address(0), 'CREATE_PAIR:ZERO_ADDRESS');
        require(getPair[token0][token1] == address(0), 'CREATE_PAIR:PAIR_EXISTS');
        bytes memory bytecode = type(CPMM).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        ICPMM(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }
}