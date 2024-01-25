// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {Script, console2} from "forge-std/Script.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/gmx/core/Vault.sol";
import "../src/gmx/tokens/USDG.sol";
import "../src/gmx/core/VaultPriceFeed.sol";
import "../src/gmx/core/VaultUtils.sol";
import "../src/gmx/core/Router.sol";
import "../src/gmx/core/PositionRouter.sol";
import "../src/gmx/core/ShortsTracker.sol";
import "../src/gmx/core/GlpManager.sol";
import "../src/gmx/core/OrderBook.sol";

contract myVault is Vault {}

contract myUSDG is USDG {
    constructor(address _vault) USDG(_vault) {}
}

contract myVaultPriceFeed is VaultPriceFeed {
    constructor() {}
}

contract myVaultUtils is VaultUtils {
    constructor(address _vault) VaultUtils(_vault) {}
}

contract myRouter is Router {
    constructor(address _vault, address _usdg, address _weth) Router(_vault, _usdg, _weth) {}
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

contract myShortsTracker is ShortsTracker {
    constructor(address _vault) ShortsTracker(_vault) {}
}

contract myPositionRouter is PositionRouter {
    constructor(
        address _vault,
        address _router,
        address _weth,
        address _shortsTracker,
        uint256 _depositFee,
        uint256 _minExecutionFee
    ) PositionRouter(
        _vault,
        _router,
        _weth,
        _shortsTracker,
        _depositFee,
        _minExecutionFee
    ) {}
}

// initialize
contract myOrderBook is OrderBook {}

contract myGlpManager is GlpManager {
    constructor(
        address _vault, 
        address _usdg, 
        address _glp, 
        address _shortsTracker, 
        uint256 _cooldownDuration
        ) GlpManager(
            _vault, 
            _usdg, 
            _glp, 
            _shortsTracker, 
            _cooldownDuration
        ) {}
}

contract deployScript is Script {
    uint256 public privateKey;
    address public account;
    address public weth;
    address public vault;

    function setUp() public {
        privateKey = vm.envUint("DEV_PRIVATE_KEY");
        account = vm.addr(privateKey);
        weth = vm.envAddress("WETH");
        vault = vm.envAddress("VAULT");
    }

    function run() public {
        vm.startBroadcast(privateKey);
        VaultPriceFeed vaultpricefeed = new VaultPriceFeed();
        VaultUtils vaultutils = new VaultUtils(vault);
        console.log("pancake router address", address(vaultutils));  

        USDG usdg = new USDG(address(vault));
        Router router = new Router(address(vault), address(usdg), address(weth));

        Vault vaultinstance = Vault(vault);
        vaultinstance.initialize(address(router), address(usdg), address(vaultpricefeed), 10, 100, 50);
        vaultinstance.setVaultUtils(vaultutils);
        GLP glp = new GLP();
        ShortsTracker shortstracker = new ShortsTracker(vault);
        PositionRouter positionRouter = new PositionRouter(vault, address(router), weth, address(shortstracker), 10, 10000000000000);

        OrderBook orderbook = new OrderBook();
        GlpManager glpmanager = new GlpManager(address(vault), address(usdg), address(glp), address(shortstracker), 0);
        vm.stopBroadcast();
    }
}