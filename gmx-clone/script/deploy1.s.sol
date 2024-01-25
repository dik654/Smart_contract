// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {Script, console2} from "forge-std/Script.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "forge-std/console.sol";
import "../src/gmx/tokens/WETH9.sol";
import "../src/pancake/PancakeFactory.sol";
import "../src/pancake/PancakeRouter.sol";
import "../src/gmx/core/Vault.sol";

contract WBTC is ERC20 {
    constructor() ERC20("Wrapped BTC", "WBTC") {} 

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

contract WETH is WETH9 {}

contract pancakeFactory is PancakeFactory {
    constructor(address _feetoSetter) PancakeFactory(_feetoSetter) {}
}

contract pancakeRouter is PancakeRouter {
    constructor(address _factory, address _WETH) PancakeRouter(_factory, _WETH) {}
}

contract GLP is ERC20 {
    constructor() ERC20("GMX LP", "GLP") {} 

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

// initialize
contract myVault is Vault {}

contract deployScript is Script {
    uint256 public privateKey;
    address public account;

    function setUp() public {
        privateKey = vm.envUint("DEV_PRIVATE_KEY");
        account = vm.addr(privateKey);
   }

    function run() public {
        vm.startBroadcast(privateKey);
        WBTC wbtc = new WBTC();
        wbtc.mint(account, 100000);
        console.log("totalSupply", wbtc.totalSupply());

        WETH9 weth = new WETH9();
        vm.deal(account, 100);
        weth.deposit{value: 100}();
        weth.withdraw(10000000000000000000000000);
        console.log("balance", weth.balanceOf(account));

        PancakeFactory pancakefactory = new PancakeFactory(account);
        PancakeRouter pancakerouter = new PancakeRouter(address(pancakefactory), address(weth));
        console.log("pancake router address", address(pancakerouter));
        
        Vault vault = new Vault();

        // write to env
        string memory envPath = "./.env";
        string memory wbtcAddressLine = string(abi.encodePacked("WBTC=", Strings.toHexString(address(wbtc))));
        vm.writeLine(envPath, wbtcAddressLine);
        string memory wethAddressLine = string(abi.encodePacked("WETH=", Strings.toHexString(address(weth))));
        vm.writeLine(envPath, wethAddressLine);
        string memory pancakefactoryAddressLine = string(abi.encodePacked("PANCAKE_FACTORY=", Strings.toHexString(address(pancakefactory))));
        vm.writeLine(envPath, pancakefactoryAddressLine);
        string memory pancakerouterAddressLine = string(abi.encodePacked("PANCAKE_ROUTER=", Strings.toHexString(address(pancakerouter))));
        vm.writeLine(envPath, pancakerouterAddressLine);
        string memory vaultAddressLine = string(abi.encodePacked("VAULT=", Strings.toHexString(address(vault))));
        vm.writeLine(envPath, vaultAddressLine);
        vm.stopBroadcast();
    }
}