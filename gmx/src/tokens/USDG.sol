// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./interfaces/IUSDG.sol";
import "./YieldToken.sol";

contract USDG is YieldToken, IUSDG {

    mapping (address => bool) public vaults;

    modifier onlyVault() {
        require(vaults[msg.sender], "USDG: forbidden");
        _;
    }
    
    // forge create --rpc-url localhost:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 src/tokens/USDG.sol:USDG --constructor-args 0x5FbDB2315678afecb367f032d93F642f64180aa3
    constructor(address _vault) public YieldToken("USD Gambit", "USDG", 0) {
        vaults[_vault] = true;
    }

    function addVault(address _vault) external override onlyGov {
        vaults[_vault] = true;
    }

    function removeVault(address _vault) external override onlyGov {
        vaults[_vault] = false;
    }

    function mint(address _account, uint256 _amount) external override onlyVault {
        _mint(_account, _amount);
    }

    function burn(address _account, uint256 _amount) external override onlyVault {
        _burn(_account, _amount);
    }
}