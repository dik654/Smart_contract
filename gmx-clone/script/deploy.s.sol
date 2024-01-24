// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script, console2} from "forge-std/Script.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/gmx/tokens/WETH9.sol";
import "../src/pancake/PancakeFactory.sol";
import "../src/pancake/PancakeRouter.sol";
import "../src/gmx/core/Vault.sol";
import "../src/gmx/tokens/USDG.sol";
import "../src/gmx/core/VaultPriceFeed.sol";
import "../src/gmx/core/VaultUtils.sol";
import "../src/gmx/core/Router.sol";
// import "../src/gmx/core/ShortsTracker.sol";
// import "../src/gmx/core/PositionRouter.sol";
// import "../src/gmx/core/OrderBook.sol";
// import "../src/gmx/core/GlpManager.sol";

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

contract myUSDG is USDG {
    constructor(address _vault) USDG(_vault) {}
}

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

// // initialize
contract myVault is Vault {}

contract myVaultPriceFeed is VaultPriceFeed {
    constructor() {}
}

contract myVaultUtils is VaultUtils {
    constructor(IVault _vault) VaultUtils(_vault) {}
}

contract myRouter is Router {
    constructor(address _vault, address _usdg, address _weth) Router(_vault, _usdg, _weth) {}
}

// contract ShortsTracker is ShortsTracker {
//     constructor(address _vault) ShortsTracker(_vault) {}
// }

// contract PositionRouter is PositionRouter {
//     constructor(
//         address _vault,
//         address _router,
//         address _weth,
//         address _shortsTracker,
//         uint256 _depositFee,
//         uint256 _minExecutionFee
//     ) PositionRouter(
//         _vault,
//         _router,
//         _weth,
//         _shortsTracker,
//         _depositFee,
//         _minExecutionFee
//     ) {}
// }

// // initialize
// contract OrderBook is OrderBook {}

// contract GlpManager is GlpManager {
//     constructor(
//         address _vault, 
//         address _usdg, 
//         address _glp, 
//         address _shortsTracker, 
//         uint256 _cooldownDuration
//         ) GlpManager(
//             _vault, 
//             _usdg, 
//             _glp, 
//             _shortsTracker, 
//             _cooldownDuration
//         ) {}
// }

contract deployScript is Script {
    function setUp() public {
        uint privateKey = vm.envUint("DEV_PRIVATE_KEY");
        address account = vm.addr(privateKey);

        vm.startBroadcast(privateKey);
        WBTC wbtc = new WBTC();
        wbtc.mint(account, 100000);
        console.log("totalSupply", wbtc.totalSupply());

        WETH9 weth = new WETH9();
        vm.deal(account, 100);
        weth.deposit{value: 100}();
        weth.withdraw(10000000000000000000000000);
        console.log("balance", weth.balanceOf(account));

        GLP glp = new GLP();
        PancakeFactory pancakefactory = new PancakeFactory(account);
        PancakeRouter pancakerouter = new PancakeRouter(address(pancakefactory), address(weth));
        console.log("pancake router address", address(pancakerouter));
        
        Vault vault = new Vault();
        VaultPriceFeed vaultpricefeed = new VaultPriceFeed();
        VaultUtils vaultutils = new VaultUtils(vault);
        console.log("pancake router address", address(vaultutils));  

        USDG usdg = new USDG(address(vault));

        Router router = new Router(address(vault), address(usdg), address(weth));

        vault.initialize(address(router), address(usdg), address(vaultpricefeed), 10, 100, 50);
        vault.setVaultUtils(vaultutils);
        vm.stopBroadcast();
    }

    function run() public {
        
    }
}