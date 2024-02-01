// SPDX-License-Identifier: GLP v3.0
pragma solidity ^0.8.19;

interface IFactory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint) external view returns (address pair);
    function allPairsLength() external view returns (uint);

    function createPair(address, address) external returns (address pair);
}