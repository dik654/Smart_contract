// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../libraries/token/SafeERC20.sol";
import "../libraries/utils/ReentrancyGuard.sol";

import "../tokens/interfaces/IUSDG.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IVaultUtils.sol";
import "./interfaces/IVaultPriceFeed.sol";

contract Vault is ReentrancyGuard, IVault {
    using SafeERC20 for IERC20;

    struct Position {
        uint256 size;
        uint256 collateral;
        uint256 averagePrice;
        uint256 entryFundingRate;
        uint256 reserveAmount;
        int256 realisedPnl;
        uint256 lastIncreasedTime;
    }

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant FUNDING_RATE_PRECISION = 1000000;
    uint256 public constant PRICE_PRECISION = 10 ** 30;
    uint256 public constant MIN_LEVERAGE = 10000; // 1x
    uint256 public constant USDG_DECIMALS = 18;
    uint256 public constant MAX_FEE_BASIS_POINTS = 500; // 5%
    uint256 public constant MAX_LIQUIDATION_FEE_USD = 100 * PRICE_PRECISION; // 100 USD
    uint256 public constant MIN_FUNDING_RATE_INTERVAL = 1 hours;
    uint256 public constant MAX_FUNDING_RATE_FACTOR = 10000; // 1%

    bool public override isInitialized;
    bool public override isSwapEnabled = true;
    bool public override isLeverageEnabled = true;

    IVaultUtils public vaultUtils;

    address public errorController;

    address public override router;
    address public override priceFeed;

    address public override usdg;
    address public override gov;

    uint256 public override whitelistedTokenCount;

    uint256 public override maxLeverage = 50 * 10000; // 50x

    uint256 public override liquidationFeeUsd;
    uint256 public override taxBasisPoints = 50; // 0.5%
    uint256 public override stableTaxBasisPoints = 20; // 0.2%
    uint256 public override mintBurnFeeBasisPoints = 30; // 0.3%
    uint256 public override swapFeeBasisPoints = 30; // 0.3%
    uint256 public override stableSwapFeeBasisPoints = 4; // 0.04%
    uint256 public override marginFeeBasisPoints = 10; // 0.1%

    uint256 public override minProfitTime;
    bool public override hasDynamicFees = false;

    uint256 public override fundingInterval = 8 hours;
    uint256 public override fundingRateFactor;
    uint256 public override stableFundingRateFactor;
    uint256 public override totalTokenWeights;

    bool public includeAmmPrice = true;
    bool public useSwapPricing = false;

    bool public override inManagerMode = false;
    bool public override inPrivateLiquidationMode = false;

    uint256 public override maxGasPrice;

    mapping (address => mapping (address => bool)) public override approvedRouters;
    mapping (address => bool) public override isLiquidator;
    mapping (address => bool) public override isManager;

    address[] public override allWhitelistedTokens;

    mapping (address => bool) public override whitelistedTokens;
    mapping (address => uint256) public override tokenDecimals;
    mapping (address => uint256) public override minProfitBasisPoints;
    mapping (address => bool) public override stableTokens;
    mapping (address => bool) public override shortableTokens;

    // tokenBalances is used only to determine _transferIn values
    mapping (address => uint256) public override tokenBalances;

    // tokenWeights allows customisation of index composition
    mapping (address => uint256) public override tokenWeights;

    // usdgAmounts tracks the amount of USDG debt for each whitelisted token
    mapping (address => uint256) public override usdgAmounts;

    // maxUsdgAmounts allows setting a max amount of USDG debt for a token
    mapping (address => uint256) public override maxUsdgAmounts;

    // poolAmounts tracks the number of received tokens that can be used for leverage
    // this is tracked separately from tokenBalances to exclude funds that are deposited as margin collateral
    mapping (address => uint256) public override poolAmounts;

    // reservedAmounts tracks the number of tokens reserved for open leverage positions
    mapping (address => uint256) public override reservedAmounts;

    // bufferAmounts allows specification of an amount to exclude from swaps
    // this can be used to ensure a certain amount of liquidity is available for leverage positions
    mapping (address => uint256) public override bufferAmounts;

    // guaranteedUsd tracks the amount of USD that is "guaranteed" by opened leverage positions
    // this value is used to calculate the redemption values for selling of USDG
    // this is an estimated amount, it is possible for the actual guaranteed value to be lower
    // in the case of sudden price decreases, the guaranteed value should be corrected
    // after liquidations are carried out
    mapping (address => uint256) public override guaranteedUsd;

    // cumulativeFundingRates tracks the funding rates based on utilization
    mapping (address => uint256) public override cumulativeFundingRates;
    // lastFundingTimes tracks the last time funding was updated for a token
    mapping (address => uint256) public override lastFundingTimes;

    // positions tracks all open positions
    mapping (bytes32 => Position) public positions;

    // feeReserves tracks the amount of fees per token
    mapping (address => uint256) public override feeReserves;

    mapping (address => uint256) public override globalShortSizes;
    mapping (address => uint256) public override globalShortAveragePrices;
    mapping (address => uint256) public override maxGlobalShortSizes;

    mapping (uint256 => string) public errors;

    event BuyUSDG(address account, address token, uint256 tokenAmount, uint256 usdgAmount, uint256 feeBasisPoints);
    event SellUSDG(address account, address token, uint256 usdgAmount, uint256 tokenAmount, uint256 feeBasisPoints);
    event Swap(address account, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, uint256 amountOutAfterFees, uint256 feeBasisPoints);

    event IncreasePosition(
        bytes32 key,
        address account,
        address collateralToken,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 price,
        uint256 fee
    );
    event DecreasePosition(
        bytes32 key,
        address account,
        address collateralToken,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 price,
        uint256 fee
    );
    event LiquidatePosition(
        bytes32 key,
        address account,
        address collateralToken,
        address indexToken,
        bool isLong,
        uint256 size,
        uint256 collateral,
        uint256 reserveAmount,
        int256 realisedPnl,
        uint256 markPrice
    );
    event UpdatePosition(
        bytes32 key,
        uint256 size,
        uint256 collateral,
        uint256 averagePrice,
        uint256 entryFundingRate,
        uint256 reserveAmount,
        int256 realisedPnl,
        uint256 markPrice
    );
    event ClosePosition(
        bytes32 key,
        uint256 size,
        uint256 collateral,
        uint256 averagePrice,
        uint256 entryFundingRate,
        uint256 reserveAmount,
        int256 realisedPnl
    );

    event UpdateFundingRate(address token, uint256 fundingRate);
    event UpdatePnl(bytes32 key, bool hasProfit, uint256 delta);

    event CollectSwapFees(address token, uint256 feeUsd, uint256 feeTokens);
    event CollectMarginFees(address token, uint256 feeUsd, uint256 feeTokens);

    event DirectPoolDeposit(address token, uint256 amount);
    event IncreasePoolAmount(address token, uint256 amount);
    event DecreasePoolAmount(address token, uint256 amount);
    event IncreaseUsdgAmount(address token, uint256 amount);
    event DecreaseUsdgAmount(address token, uint256 amount);
    event IncreaseReservedAmount(address token, uint256 amount);
    event DecreaseReservedAmount(address token, uint256 amount);
    event IncreaseGuaranteedUsd(address token, uint256 amount);
    event DecreaseGuaranteedUsd(address token, uint256 amount);

    // forge create --rpc-url localhost:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 src/core/Vault.sol:Vault
    // once the parameters are verified to be working correctly,
    // gov should be set to a timelock contract or a governance contract
    constructor() {
        gov = msg.sender;
    }

    function initialize(
        address _router,
        address _usdg,
        address _priceFeed,
        uint256 _liquidationFeeUsd,
        uint256 _fundingRateFactor,
        uint256 _stableFundingRateFactor
    ) external {
        _onlyGov();
        _validate(!isInitialized, 1);
        isInitialized = true;

        router = _router;
        usdg = _usdg;
        priceFeed = _priceFeed;
        // 청산 실행 수수료 10 USD
        liquidationFeeUsd = _liquidationFeeUsd;
        // 1%인 10000보다 작아야함, 100 ~ 1000
        fundingRateFactor = _fundingRateFactor;
        // 1%인 10000보다 작아야함, 50 ~ 500
        stableFundingRateFactor = _stableFundingRateFactor;
    }

    function setVaultUtils(IVaultUtils _vaultUtils) external override {
        _onlyGov();
        vaultUtils = _vaultUtils;
    }

    function setErrorController(address _errorController) external {
        _onlyGov();
        errorController = _errorController;
    }

    function setError(uint256 _errorCode, string calldata _error) external override {
        require(msg.sender == errorController, "Vault: invalid errorController");
        errors[_errorCode] = _error;
    }

    function allWhitelistedTokensLength() external override view returns (uint256) {
        return allWhitelistedTokens.length;
    }

    function setInManagerMode(bool _inManagerMode) external override {
        _onlyGov();
        inManagerMode = _inManagerMode;
    }

    function setManager(address _manager, bool _isManager) external override {
        _onlyGov();
        isManager[_manager] = _isManager;
    }

    function setInPrivateLiquidationMode(bool _inPrivateLiquidationMode) external override {
        _onlyGov();
        inPrivateLiquidationMode = _inPrivateLiquidationMode;
    }

    function setLiquidator(address _liquidator, bool _isActive) external override {
        _onlyGov();
        isLiquidator[_liquidator] = _isActive;
    }

    function setIsSwapEnabled(bool _isSwapEnabled) external override {
        _onlyGov();
        isSwapEnabled = _isSwapEnabled;
    }

    function setIsLeverageEnabled(bool _isLeverageEnabled) external override {
        _onlyGov();
        isLeverageEnabled = _isLeverageEnabled;
    }

    function setMaxGasPrice(uint256 _maxGasPrice) external override {
        _onlyGov();
        maxGasPrice = _maxGasPrice;
    }

    function setGov(address _gov) external {
        _onlyGov();
        gov = _gov;
    }

    function setPriceFeed(address _priceFeed) external override {
        _onlyGov();
        priceFeed = _priceFeed;
    }

    function setMaxLeverage(uint256 _maxLeverage) external override {
        _onlyGov();
        _validate(_maxLeverage > MIN_LEVERAGE, 2);
        maxLeverage = _maxLeverage;
    }

    function setBufferAmount(address _token, uint256 _amount) external override {
        _onlyGov();
        bufferAmounts[_token] = _amount;
    }

    function setMaxGlobalShortSize(address _token, uint256 _amount) external override {
        _onlyGov();
        maxGlobalShortSizes[_token] = _amount;
    }

    function setFees(
        uint256 _taxBasisPoints,
        uint256 _stableTaxBasisPoints,
        uint256 _mintBurnFeeBasisPoints,
        uint256 _swapFeeBasisPoints,
        uint256 _stableSwapFeeBasisPoints,
        uint256 _marginFeeBasisPoints,
        uint256 _liquidationFeeUsd,
        uint256 _minProfitTime,
        bool _hasDynamicFees
    ) external override {
        _onlyGov();
        _validate(_taxBasisPoints <= MAX_FEE_BASIS_POINTS, 3);
        _validate(_stableTaxBasisPoints <= MAX_FEE_BASIS_POINTS, 4);
        _validate(_mintBurnFeeBasisPoints <= MAX_FEE_BASIS_POINTS, 5);
        _validate(_swapFeeBasisPoints <= MAX_FEE_BASIS_POINTS, 6);
        _validate(_stableSwapFeeBasisPoints <= MAX_FEE_BASIS_POINTS, 7);
        _validate(_marginFeeBasisPoints <= MAX_FEE_BASIS_POINTS, 8);
        _validate(_liquidationFeeUsd <= MAX_LIQUIDATION_FEE_USD, 9);
        taxBasisPoints = _taxBasisPoints;
        stableTaxBasisPoints = _stableTaxBasisPoints;
        mintBurnFeeBasisPoints = _mintBurnFeeBasisPoints;
        swapFeeBasisPoints = _swapFeeBasisPoints;
        stableSwapFeeBasisPoints = _stableSwapFeeBasisPoints;
        marginFeeBasisPoints = _marginFeeBasisPoints;
        liquidationFeeUsd = _liquidationFeeUsd;
        minProfitTime = _minProfitTime;
        hasDynamicFees = _hasDynamicFees;
    }

    function setFundingRate(uint256 _fundingInterval, uint256 _fundingRateFactor, uint256 _stableFundingRateFactor) external override {
        _onlyGov();
        _validate(_fundingInterval >= MIN_FUNDING_RATE_INTERVAL, 10);
        _validate(_fundingRateFactor <= MAX_FUNDING_RATE_FACTOR, 11);
        _validate(_stableFundingRateFactor <= MAX_FUNDING_RATE_FACTOR, 12);
        fundingInterval = _fundingInterval;
        fundingRateFactor = _fundingRateFactor;
        stableFundingRateFactor = _stableFundingRateFactor;
    }

    function setTokenConfig(
        address _token,
        uint256 _tokenDecimals,
        uint256 _tokenWeight,
        uint256 _minProfitBps,
        uint256 _maxUsdgAmount,
        bool _isStable,
        bool _isShortable
    ) external override {
        _onlyGov();
        // increment token count for the first time
        if (!whitelistedTokens[_token]) {
            whitelistedTokenCount = whitelistedTokenCount+ 1;
            allWhitelistedTokens.push(_token);
        }

        uint256 _totalTokenWeights = totalTokenWeights;
        _totalTokenWeights = _totalTokenWeights - tokenWeights[_token];

        whitelistedTokens[_token] = true;
        tokenDecimals[_token] = _tokenDecimals;
        tokenWeights[_token] = _tokenWeight;
        minProfitBasisPoints[_token] = _minProfitBps;
        maxUsdgAmounts[_token] = _maxUsdgAmount;
        stableTokens[_token] = _isStable;
        shortableTokens[_token] = _isShortable;

        totalTokenWeights = _totalTokenWeights + _tokenWeight;

        // validate price feed
        getMaxPrice(_token);
    }

    function clearTokenConfig(address _token) external {
        _onlyGov();
        _validate(whitelistedTokens[_token], 13);
        totalTokenWeights = totalTokenWeights - tokenWeights[_token];
        delete whitelistedTokens[_token];
        delete tokenDecimals[_token];
        delete tokenWeights[_token];
        delete minProfitBasisPoints[_token];
        delete maxUsdgAmounts[_token];
        delete stableTokens[_token];
        delete shortableTokens[_token];
        whitelistedTokenCount = whitelistedTokenCount - 1;
    }

    /**
     * @dev governor withdraw token from fee reserve pool
     * @param _token kind of token
     * @param _receiver where to transfer
     */
    function withdrawFees(address _token, address _receiver) external override returns (uint256) {
        _onlyGov();
        uint256 amount = feeReserves[_token];
        if(amount == 0) { return 0; }
        feeReserves[_token] = 0;
        _transferOut(_token, amount, _receiver);
        return amount;
    }

    function addRouter(address _router) external {
        approvedRouters[msg.sender][_router] = true;
    }

    function removeRouter(address _router) external {
        approvedRouters[msg.sender][_router] = false;
    }

    function setUsdgAmount(address _token, uint256 _amount) external override {
        _onlyGov();

        uint256 usdgAmount = usdgAmounts[_token];
        if (_amount > usdgAmount) {
            _increaseUsdgAmount(_token, _amount - usdgAmount);
            return;
        }

        _decreaseUsdgAmount(_token, usdgAmount - _amount);
    }

    // the governance controlling this function should have a timelock
    
    /**
     * @dev vault 컨트랙트를 변경하기 위해서 들어있는 토큰을 변경할 vault로 전송하는 함수
     * @param _newVault .
     * @param _token .
     * @param _amount .
     */
    function upgradeVault(address _newVault, address _token, uint256 _amount) external {
        _onlyGov();
        IERC20(_token).safeTransfer(_newVault, _amount);
    }

    // deposit into the pool without minting USDG tokens
    // useful in allowing the pool to become over-collaterised
    /**
     * @dev 토큰을 vault pool에 바로 넣는 함수
     * @param _token .
     */
    function directPoolDeposit(address _token) external override nonReentrant {
        // 사용 가능한 토큰인지 체크
        _validate(whitelistedTokens[_token], 14);
        // 넣은 토큰의 크기가 0보다 많은지 체크
        uint256 tokenAmount = _transferIn(_token);
        _validate(tokenAmount > 0, 15);
        // 넣은 토큰만큼 pool에 추가
        _increasePoolAmount(_token, tokenAmount);
        emit DirectPoolDeposit(_token, tokenAmount);
    }

    /**
     * @dev 토큰을 USDG로 swap
     * @param _token 넣을 토큰
     * @param _receiver .
     */
    function buyUSDG(address _token, address _receiver) external override nonReentrant returns (uint256) {
        // 매니저 컨트랙트에 의해서만 실행 가능
        _validateManager();
        // 사용 가능한 토큰인지 체크
        _validate(whitelistedTokens[_token], 16);
        // 실제 사용되는 플래그는 아님
        useSwapPricing = true;

        // 넣은 토큰 개수 체크
        uint256 tokenAmount = _transferIn(_token);
        _validate(tokenAmount > 0, 17);

        // 변경된 reserve / pool 기록 증가시키기
        updateCumulativeFundingRate(_token, _token);

        // 해당 토큰 최소 가격 가져오기
        uint256 price = getMinPrice(_token);

        // 내가 넣은 토큰의 총 USD 가치 계산
        uint256 usdgAmount = tokenAmount * price / PRICE_PRECISION;
        usdgAmount = adjustForDecimals(usdgAmount, _token, usdg);
        _validate(usdgAmount > 0, 18);

        // 수수료 Basis Point를 가져와 swap 수수료 처리 이후 토큰 개수 리턴
        uint256 feeBasisPoints = vaultUtils.getBuyUsdgFeeBasisPoints(_token, usdgAmount);
        uint256 amountAfterFees = _collectSwapFees(_token, tokenAmount, feeBasisPoints);
  
        // 수수료 처리 이후 토큰 개수 * 토큰 최소가격
        uint256 mintAmount = amountAfterFees * price / PRICE_PRECISION;
        mintAmount = adjustForDecimals(mintAmount, _token, usdg);

        // usdg pool에 토큰 개수만큼 추가
        _increaseUsdgAmount(_token, mintAmount);
        // 전체 pool에 토큰 가치만큼 추가
        _increasePoolAmount(_token, amountAfterFees);

        // usdg 토큰 개수만큼 receiver에게 전송
        IUSDG(usdg).mint(_receiver, mintAmount);

        emit BuyUSDG(_receiver, _token, tokenAmount, mintAmount, feeBasisPoints);

        // 실제 사용되는 플래그는 아님
        useSwapPricing = false;
        return mintAmount;
    }

    /**
     * @dev USDG를 특정 토큰으로 swap
     * @dev USDG는 시장에서 제거 (총 공급량 감소)
     * @param _token 받을 토큰
     * @param _receiver .
     */
    function sellUSDG(address _token, address _receiver) external override nonReentrant returns (uint256) {
        // 등록된 매니저 컨트랙트만 실행 가능
        _validateManager();
        // 등록된 토큰만 사용가능
        _validate(whitelistedTokens[_token], 19);
        // 실제 사용되는 플래그는 아님
        useSwapPricing = true;

        // 넣은 usdg가 0보다 큰지 체크
        uint256 usdgAmount = _transferIn(usdg);
        _validate(usdgAmount > 0, 20);
        
        // reserve / pool 누적 업데이트
        updateCumulativeFundingRate(_token, _token);

        // 받을 수 있는 토큰 개수가 0보다 큰지 체크 
        uint256 redemptionAmount = getRedemptionAmount(_token, usdgAmount);
        _validate(redemptionAmount > 0, 21);

        // swap되는 USDG만큼 usdg pool에서 빼기 (시장에서 제거)
        // USDG는 Vault 시스템 내에서 생성되고 관리되는 스테이블코인이므로 총 공급량이 usdgAmount로 고정되어있기 때문)
        _decreaseUsdgAmount(_token, usdgAmount);
        // 전체 pool에서 받는 토큰의 개수만큼 빼기
        _decreasePoolAmount(_token, redemptionAmount);

        // USDG 시장에서 실제로 제거
        IUSDG(usdg).burn(address(this), usdgAmount);

        // _decreaseUsdgAmount로 token balance까지 업데이트 되지 않으므로 
        // 실제로 제거된 usdg 토큰 개수만큼 token balance 업데이트 
        _updateTokenBalance(usdg);

        // 수수료를 제외한 토큰 개수 계산
        uint256 feeBasisPoints = vaultUtils.getSellUsdgFeeBasisPoints(_token, usdgAmount);
        uint256 amountOut = _collectSwapFees(_token, redemptionAmount, feeBasisPoints);
        _validate(amountOut > 0, 22);

        // 바꾼 토큰을 receiver에게 전달
        _transferOut(_token, amountOut, _receiver);

        emit SellUSDG(_receiver, _token, usdgAmount, amountOut, feeBasisPoints);

        // 실제 사용되는 플래그는 아님
        useSwapPricing = false;
        return amountOut;
    }

    /**
     * @dev A 토큰을 B 토큰으로 바꾸는 함수
     * @param _tokenIn .
     * @param _tokenOut .
     * @param _receiver .
     */
    function swap(address _tokenIn, address _tokenOut, address _receiver) external override nonReentrant returns (uint256) {
        // swap 가능 플래그가 켜져있는지 체크
        _validate(isSwapEnabled, 23);
        // 두 토큰 모두 등록된 토큰인지 체크
        _validate(whitelistedTokens[_tokenIn], 24);
        _validate(whitelistedTokens[_tokenOut], 25);
        // 서로 다른 토큰이 맞는지 체크
        _validate(_tokenIn != _tokenOut, 26);
        // 실제 사용되는 플래그는 아님
        useSwapPricing = true;

        // 두 토큰 모두 reserve / pool 비율 누적 업데이트
        updateCumulativeFundingRate(_tokenIn, _tokenIn);
        updateCumulativeFundingRate(_tokenOut, _tokenOut);

        // 토큰 넣은 개수가 0개보다 큰 지 체크
        uint256 amountIn = _transferIn(_tokenIn);
        _validate(amountIn > 0, 27);

        // 넣은 토큰의 최소 가치와 받을 토큰의 최대 가치 
        uint256 priceIn = getMinPrice(_tokenIn);
        uint256 priceOut = getMaxPrice(_tokenOut);

        // 받을 토큰 개수 = 넣은 토큰 개수 * (넣은 토큰 가치 / 받을 토큰 가치)
        uint256 amountOut = amountIn * priceIn / priceOut;
        amountOut = adjustForDecimals(amountOut, _tokenIn, _tokenOut);

        // USDG는 Vault 시스템 내에서 다른 토큰을 예치하고 발행되는 스테이블코인
        // 항상 각 토큰의 가치 변동을 USDG가 해야 시스템이 안정적이므로 두 토큰 간 교환임에도 usdgAmount를 변경시킨다
        // 토큰 개수 = 넣은 토큰 * 넣은 토큰 가격
        // USDG 개수 = 토큰 개수 * (넣은 토큰 가치 / USDG 가치) 
        // adjust usdgAmounts by the same usdgAmount as debt is shifted between the assets
        uint256 usdgAmount = amountIn * priceIn / PRICE_PRECISION;
        usdgAmount = adjustForDecimals(usdgAmount, _tokenIn, usdg);

        // 수수료 처리 후의 토큰 개수 계산 
        uint256 feeBasisPoints = vaultUtils.getSwapFeeBasisPoints(_tokenIn, _tokenOut, usdgAmount);
        uint256 amountOutAfterFees = _collectSwapFees(_tokenOut, amountOut, feeBasisPoints);

        // swap에 따른 USDG 가치 업데이트
        _increaseUsdgAmount(_tokenIn, usdgAmount);
        _decreaseUsdgAmount(_tokenOut, usdgAmount);

        // swap에 따른 전체 pool의 토큰 개수 업데이트
        _increasePoolAmount(_tokenIn, amountIn);
        _decreasePoolAmount(_tokenOut, amountOut);

        // Buffer은 최소 유동성으로, 시스템의 안정성을 위해 항상 vault안에 지정한 Buffer보다 많은 양의 토큰을 갖도록 검사
        _validateBufferAmount(_tokenOut);

        // swap한 토큰 receiver에게 전송
        _transferOut(_tokenOut, amountOutAfterFees, _receiver);

        emit Swap(_receiver, _tokenIn, _tokenOut, amountIn, amountOut, amountOutAfterFees, feeBasisPoints);

        // 실제 사용되는 플래그는 아님
        useSwapPricing = false;
        return amountOutAfterFees;
    }

    /**
     * @dev only tx.origin's approved router can change position
     * @param _account tx.origin address. (transaction direction: tx.origin -> router -> vault)
     * @param _collateralToken .
     * @param _indexToken .
     * @param _sizeDelta .
     * @param _isLong .
     */
    function increasePosition(address _account, address _collateralToken, address _indexToken, uint256 _sizeDelta, bool _isLong) external override nonReentrant {
        _validate(isLeverageEnabled, 28);
        _validateGasPrice();
        _validateRouter(_account);
        // long일 때는 포지션을 잡을 index 토큰을 그대로 담보로 사용하지만, short일 때는 stable coin을 담보로 설정해야한다.
        _validateTokens(_collateralToken, _indexToken, _isLong);
        // setVaultUtils로 vaultUtils 설정이 선행되어야 실행가능하다(원본에는 validate 로직 내용은 비어있다)
        vaultUtils.validateIncreasePosition(_account, _collateralToken, _indexToken, _sizeDelta, _isLong);

        // interval동안 pool에 추가된 reserve 토큰 비율 업데이트
        updateCumulativeFundingRate(_collateralToken, _indexToken);

        // 포지션 데이터 가져오기
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position storage position = positions[key];

        // long이라면 maxise 설정을 true로 만들어 가격을 가져오고
        // short라면 false로 만들어 가격을 가져온다
        uint256 price = _isLong ? getMaxPrice(_indexToken) : getMinPrice(_indexToken);

        // 평균 가격 최신화
        if (position.size == 0) {
            position.averagePrice = price;
        }

        // 포지션 변경시 바뀌는 평균가격 최신화
        if (position.size > 0 && _sizeDelta > 0) {
            position.averagePrice = getNextAveragePrice(_indexToken, position.size, position.averagePrice, _isLong, price, _sizeDelta, position.lastIncreasedTime);
        }

        // 레버리지 수수료 계산
        uint256 fee = _collectMarginFees(_account, _collateralToken, _indexToken, _isLong, _sizeDelta, position.size, position.entryFundingRate);
        // 이번 트랜잭션에 넣은 담보 토큰 개수
        uint256 collateralDelta = _transferIn(_collateralToken);
        // 이번 트랜잭션에 넣은 담보 토큰의 가격 
        uint256 collateralDeltaUsd = tokenToUsdMin(_collateralToken, collateralDelta);

        // 포지션 담보에 이번 트랜잭션에 넣은 담보 토큰의 가격을 더해서 업데이트
        position.collateral += collateralDeltaUsd;
        // 포지션 담보가 레버리지 수수료를 감당할 수 있는지 확인
        _validate(position.collateral >= fee, 29);

        // 감당 가능하다면 수수료만큼 포지션 담보에서 빼기
        position.collateral -= fee;
        // 포지션 시작 수수료 최신화 
        position.entryFundingRate = getEntryFundingRate(_collateralToken, _indexToken, _isLong);
        // 포지션의 크기 최신화
        position.size += _sizeDelta;
        // 포지션 마지막 증가 시간 최신화
        position.lastIncreasedTime = block.timestamp;

        _validate(position.size > 0, 30);
        _validatePosition(position.size, position.collateral);
        validateLiquidation(_account, _collateralToken, _indexToken, _isLong, true);

        // 포지션으로 들어가는 담보 토큰은 reserve로 추가
        uint256 reserveDelta = usdToTokenMax(_collateralToken, _sizeDelta);
        position.reserveAmount += reserveDelta;
        _increaseReservedAmount(_collateralToken, reserveDelta);

        // 롱이라면
        if (_isLong) {
            // 수수료는 담보에서 빠져나갔으니 (포지션 크기 - 담보)인 순수익에 fee만큼을 더해준다 (포지션의 전체 가치(size)에서 담보(collateral)를 뺀 값)
            _increaseGuaranteedUsd(_collateralToken, _sizeDelta + fee);
            _decreaseGuaranteedUsd(_collateralToken, collateralDeltaUsd);
            // 담보도 pool의 일부이므로 추가한다
            _increasePoolAmount(_collateralToken, collateralDelta);
            // fee는 pool에서 빠지는 값이므로 뺴준다
            _decreasePoolAmount(_collateralToken, usdToTokenMin(_collateralToken, fee));
        } else {
            // 숏이라면
            if (globalShortSizes[_indexToken] == 0) {
                globalShortAveragePrices[_indexToken] = price;
            } else {
                // 다음 숏 평균가격 저장
                globalShortAveragePrices[_indexToken] = getNextGlobalShortAveragePrice(_indexToken, price, _sizeDelta);
            }
            // 전체 숏의 크기 저장
            _increaseGlobalShortSize(_indexToken, _sizeDelta);
        }

        emit IncreasePosition(key, _account, _collateralToken, _indexToken, collateralDeltaUsd, _sizeDelta, _isLong, price, fee);
        emit UpdatePosition(key, position.size, position.collateral, position.averagePrice, position.entryFundingRate, position.reserveAmount, position.realisedPnl, price);
    }

    function decreasePosition(address _account, address _collateralToken, address _indexToken, uint256 _collateralDelta, uint256 _sizeDelta, bool _isLong, address _receiver) external override nonReentrant returns (uint256) {
        _validateGasPrice();
        _validateRouter(_account);
        return _decreasePosition(_account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, _receiver);
    }

    /**
     * @dev 포지션 감소시키기(숏 아님, 포지션에 들어있는 담보의 양을 줄이는 것)
     * @param _account .
     * @param _collateralToken .
     * @param _indexToken .
     * @param _collateralDelta .
     * @param _sizeDelta .
     * @param _isLong .
     * @param _receiver .
     */
    function _decreasePosition(address _account, address _collateralToken, address _indexToken, uint256 _collateralDelta, uint256 _sizeDelta, bool _isLong, address _receiver) private returns (uint256) {
        // 인수 검사 (없는 로직)
        vaultUtils.validateDecreasePosition(_account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, _receiver);
        // CumulativeFundingRate 증가시키기
        updateCumulativeFundingRate(_collateralToken, _indexToken);

        // 포지션 데이터 가져오기
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position storage position = positions[key];
        _validate(position.size > 0, 31);
        _validate(position.size >= _sizeDelta, 32);
        _validate(position.collateral >= _collateralDelta, 33);

        uint256 collateral = position.collateral;
        // scrop variables to avoid stack too deep errors
        {
            // 포지션 내의 reserve 감소시키기
            uint256 reserveDelta = position.reserveAmount * _sizeDelta / position.size;
            position.reserveAmount = position.reserveAmount - reserveDelta;
            _decreaseReservedAmount(_collateralToken, reserveDelta);
        }

        // 담보 감소시키기
        (uint256 usdOut, uint256 usdOutAfterFee) = _reduceCollateral(_account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong);

        // 모두 빼는게 아니라면
        if (position.size != _sizeDelta) {
            position.entryFundingRate = getEntryFundingRate(_collateralToken, _indexToken, _isLong);
            // 전체 크기에서 빼려는 크기만큼을 빼고
            position.size = position.size - _sizeDelta;

            _validatePosition(position.size, position.collateral);
            validateLiquidation(_account, _collateralToken, _indexToken, _isLong, true);

            // 롱이라면
            if (_isLong) {
                // 보장 USD - 빼려는 크기 + 변화한 담보(_reduceCollateral로 position.collateral이 변화되었음)
                _increaseGuaranteedUsd(_collateralToken, collateral - position.collateral);
                _decreaseGuaranteedUsd(_collateralToken, _sizeDelta);
            }

            uint256 price = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);
            emit DecreasePosition(key, _account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, price, usdOut - usdOutAfterFee);
            emit UpdatePosition(key, position.size, position.collateral, position.averagePrice, position.entryFundingRate, position.reserveAmount, position.realisedPnl, price);
        } else {
            // 모두 빼는거라면
            if (_isLong) {
                // 보장 USD - 전체 크기 + 전체 담보 (포지션의 전체 가치(size)에서 담보(collateral)를 뺀 값)
                _increaseGuaranteedUsd(_collateralToken, collateral);
                _decreaseGuaranteedUsd(_collateralToken, _sizeDelta);
            }

            uint256 price = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);
            emit DecreasePosition(key, _account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, price, usdOut - usdOutAfterFee);
            emit ClosePosition(key, position.size, position.collateral, position.averagePrice, position.entryFundingRate, position.reserveAmount, position.realisedPnl);
            // 모두 꺼냈으니 포지션 데이터 삭제
            delete positions[key];
        }

        // 숏이라면 전체 숏크기에 size만큼 감소 (뺐으므로)
        if (!_isLong) {
            _decreaseGlobalShortSize(_indexToken, _sizeDelta);
        }

        if (usdOut > 0) {
            if (_isLong) {
                // 꺼내는 만큼 pool에서도 빼기
                _decreasePoolAmount(_collateralToken, usdToTokenMin(_collateralToken, usdOut));
            }
            // 계산이 완료되어 수수료를 제외한 꺼낸 양만큼 receiver에게 전송
            uint256 amountOutAfterFees = usdToTokenMin(_collateralToken, usdOutAfterFee);
            _transferOut(_collateralToken, amountOutAfterFees, _receiver);
            return amountOutAfterFees;
        }

        return 0;
    }

    /**
     * @dev 포지션 강제 청산
     * @param _account 청산시킬 유저
     * @param _collateralToken .
     * @param _indexToken .
     * @param _isLong .
     * @param _feeReceiver 유저가 청산 수수료를 받게하여 자발적으로 청산 함수를 실행시키도록 한다
     */
    function liquidatePosition(address _account, address _collateralToken, address _indexToken, bool _isLong, address _feeReceiver) external override nonReentrant {
        if (inPrivateLiquidationMode) {
            _validate(isLiquidator[msg.sender], 34);
        }

        // set includeAmmPrice to false to prevent manipulated liquidations
        includeAmmPrice = false;

        // reserve / amount 최신화
        updateCumulativeFundingRate(_collateralToken, _indexToken);

        // 포지션 데이터 가져오기
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position memory position = positions[key];
        _validate(position.size > 0, 35);

        // 유효한 유동성 상태인지 체크
        (uint256 liquidationState, uint256 marginFees) = validateLiquidation(_account, _collateralToken, _indexToken, _isLong, false);
        _validate(liquidationState != 0, 36);
        if (liquidationState == 2) {
            // 담보변화량은 0으로 두고 size를 변화시켜서 레버리지 범위를 변경한다
            _decreasePosition(_account, _collateralToken, _indexToken, 0, position.size, _isLong, _account);
            includeAmmPrice = true;
            return;
        }

        // 마진 수수료의 usd 가치만큼 feeReserves에 추가 
        uint256 feeTokens = usdToTokenMin(_collateralToken, marginFees);
        feeReserves[_collateralToken] = feeReserves[_collateralToken] + feeTokens;
        emit CollectMarginFees(_collateralToken, marginFees, feeTokens);

        // reserve pool에서 reserve amount만큼 빼기
        _decreaseReservedAmount(_collateralToken, position.reserveAmount);
        if (_isLong) {
            // guaranteedUsd에서 (크기 - 담보)만큼 빼기
            _decreaseGuaranteedUsd(_collateralToken, position.size - position.collateral);
            // pool에서 usd 가치만큼 빼기
            _decreasePoolAmount(_collateralToken, usdToTokenMin(_collateralToken, marginFees));
        }

        uint256 markPrice = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);
        emit LiquidatePosition(key, _account, _collateralToken, _indexToken, _isLong, position.size, position.collateral, position.reserveAmount, position.realisedPnl, markPrice);

        // 숏이고 담보가 마진 수수료를 감당할 수 있다면
        if (!_isLong && marginFees < position.collateral) {
            // 수수료를 제외한 남은 담보만큼 pool에 증가시키기
            uint256 remainingCollateral = position.collateral - marginFees;
            _increasePoolAmount(_collateralToken, usdToTokenMin(_collateralToken, remainingCollateral));
        }

        // 숏이라면
        if (!_isLong) {
            // 전체 숏 크기 증가
            _decreaseGlobalShortSize(_indexToken, position.size);
        }

        // 포지션 정보 삭제
        delete positions[key];


        // 청산 실행자에게 청산 수수료를 전달
        _decreasePoolAmount(_collateralToken, usdToTokenMin(_collateralToken, liquidationFeeUsd));
        _transferOut(_collateralToken, usdToTokenMin(_collateralToken, liquidationFeeUsd), _feeReceiver);

        includeAmmPrice = true;
    }

    // note that if calling this function independently the cumulativeFundingRates used in getFundingFee will not be the latest value
    // validateLiquidation returns (state, fees)
    function validateLiquidation(address _account, address _collateralToken, address _indexToken, bool _isLong, bool _raise) override public view returns (uint256, uint256) {
        return vaultUtils.validateLiquidation(_account, _collateralToken, _indexToken, _isLong, _raise);
    }

    function getMaxPrice(address _token) public override view returns (uint256) {
        return IVaultPriceFeed(priceFeed).getPrice(_token, true, includeAmmPrice, useSwapPricing);
    }

    function getMinPrice(address _token) public override view returns (uint256) {
        return IVaultPriceFeed(priceFeed).getPrice(_token, false, includeAmmPrice, useSwapPricing);
    }

    function getRedemptionAmount(address _token, uint256 _usdgAmount) public override view returns (uint256) {
        // 토큰의 최대 가격
        uint256 price = getMaxPrice(_token);
        // 받을 수 있는 최소 토큰 개수 = (USDG 개수 * USDG의 가치) / 최대 토큰 가격
        uint256 redemptionAmount = _usdgAmount * PRICE_PRECISION / price;
        return adjustForDecimals(redemptionAmount, usdg, _token);
    }

    function getRedemptionCollateral(address _token) public view returns (uint256) {
        if (stableTokens[_token]) {
            return poolAmounts[_token];
        }
        uint256 collateral = usdToTokenMin(_token, guaranteedUsd[_token]);
        return collateral + poolAmounts[_token] - reservedAmounts[_token];
    }

    function getRedemptionCollateralUsd(address _token) public view returns (uint256) {
        return tokenToUsdMin(_token, getRedemptionCollateral(_token));
    }

    function adjustForDecimals(uint256 _amount, address _tokenDiv, address _tokenMul) public view returns (uint256) {
        uint256 decimalsDiv = _tokenDiv == usdg ? USDG_DECIMALS : tokenDecimals[_tokenDiv];
        uint256 decimalsMul = _tokenMul == usdg ? USDG_DECIMALS : tokenDecimals[_tokenMul];
        return _amount * 10 ** decimalsMul / 10 ** decimalsDiv;
    }

    function tokenToUsdMin(address _token, uint256 _tokenAmount) public override view returns (uint256) {
        if (_tokenAmount == 0) { return 0; }
        uint256 price = getMinPrice(_token);
        uint256 decimals = tokenDecimals[_token];
        return _tokenAmount * price / 10 ** decimals;
    }

    function usdToTokenMax(address _token, uint256 _usdAmount) public view returns (uint256) {
        if (_usdAmount == 0) { return 0; }
        return usdToToken(_token, _usdAmount, getMinPrice(_token));
    }

    function usdToTokenMin(address _token, uint256 _usdAmount) public view returns (uint256) {
        if (_usdAmount == 0) { return 0; }
        return usdToToken(_token, _usdAmount, getMaxPrice(_token));
    }

    function usdToToken(address _token, uint256 _usdAmount, uint256 _price) public view returns (uint256) {
        if (_usdAmount == 0) { return 0; }
        uint256 decimals = tokenDecimals[_token];
        return _usdAmount * 10 ** decimals / _price;
    }

    function getPosition(address _account, address _collateralToken, address _indexToken, bool _isLong) public override view returns (uint256, uint256, uint256, uint256, uint256, uint256, bool, uint256) {
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position memory position = positions[key];
        uint256 realisedPnl = position.realisedPnl > 0 ? uint256(position.realisedPnl) : uint256(-position.realisedPnl);
        return (
            position.size, // 0
            position.collateral, // 1
            position.averagePrice, // 2
            position.entryFundingRate, // 3
            position.reserveAmount, // 4
            realisedPnl, // 5
            position.realisedPnl >= 0, // 6
            position.lastIncreasedTime // 7
        );
    }

    function getPositionKey(address _account, address _collateralToken, address _indexToken, bool _isLong) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            _account,
            _collateralToken,
            _indexToken,
            _isLong
        ));
    }
    
    /**
     * @dev interval동안 pool에 추가된 reserve 토큰 비율 업데이트
     * @param _collateralToken .
     * @param _indexToken .
     */
    function updateCumulativeFundingRate(address _collateralToken, address _indexToken) public {
        // 구현되지않은 로직 pass
        bool shouldUpdate = vaultUtils.updateCumulativeFundingRate(_collateralToken, _indexToken);
        if (!shouldUpdate) {
            return;
        }

        // 최초 update라면
        if (lastFundingTimes[_collateralToken] == 0) {
            // 마지막 자금 조달 비율을 현재시간으로 업데이트 (현재시간 % interval로 필요없는 시간정보 제거)
            lastFundingTimes[_collateralToken] = block.timestamp / fundingInterval * fundingInterval;
            return;
        }

        // 마지막 자금 조달 이후 일정 시간(interval)이 지나지 않았다면 종료
        if (lastFundingTimes[_collateralToken] + fundingInterval > block.timestamp) {
            return;
        }

        // interval 동안 변경 된 fundingRate = 코인 종류에 따른 비율 * reseve pool에 들어있는 토큰 개수 * 지난 interval 개수 / pool에 들어있는 총 토큰 개수 
        uint256 fundingRate = getNextFundingRate(_collateralToken);
        // 변경된 fundingRate 누적시키기
        cumulativeFundingRates[_collateralToken] += fundingRate;
        // 마지막 funding 타임 업데이트
        lastFundingTimes[_collateralToken] = block.timestamp / fundingInterval * fundingInterval;

        emit UpdateFundingRate(_collateralToken, cumulativeFundingRates[_collateralToken]);
    }

    function getNextFundingRate(address _token) public override view returns (uint256) {
        // 마지막 자금 조달 이후 일정 시간(interval)이 지나지 않았다면 종료
        if (lastFundingTimes[_token] + fundingInterval > block.timestamp) { return 0; }

        // 마지막 자금 조달 이후 몇 번의 interval을 지났는지 체크
        uint256 intervals = block.timestamp - lastFundingTimes[_token] / fundingInterval;
        // pool에 토큰이 비어있다면 0을 리턴
        uint256 poolAmount = poolAmounts[_token];
        if (poolAmount == 0) { return 0; }

        // 코인의 종류에 따라 비율을 다르게 설정
        uint256 _fundingRateFactor = stableTokens[_token] ? stableFundingRateFactor : fundingRateFactor;
        // 코인 종류에 따른 비율 * reserve pool에 들어있는 토큰 개수 * 지난 interval 개수 / pool에 들어있는 총 토큰 개수
        return _fundingRateFactor * reservedAmounts[_token] * intervals / poolAmount;
    }

    function getUtilisation(address _token) public view returns (uint256) {
        uint256 poolAmount = poolAmounts[_token];
        if (poolAmount == 0) { return 0; }

        return reservedAmounts[_token] * FUNDING_RATE_PRECISION / poolAmount;
    }

    /**
     * @dev 현재 내 포지션의 레버리지 계산
     * @param _account .
     * @param _collateralToken .
     * @param _indexToken .
     * @param _isLong .
     */
    function getPositionLeverage(address _account, address _collateralToken, address _indexToken, bool _isLong) public view returns (uint256) {
        // 저장한 포지션을 나타내는 해시값 계산하여 포지션 가져오기
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position memory position = positions[key];
        // 해당 포지션에 담보가 있는지 체크
        _validate(position.collateral > 0, 37);
        // 레버리지 = 포지션의 전체 가치 / 담보
        return position.size * BASIS_POINTS_DIVISOR / position.collateral;
    }

    // for longs: nextAveragePrice = (nextPrice * nextSize) / (nextSize + delta)
    // for shorts: nextAveragePrice = (nextPrice * nextSize) / (nextSize - delta)
    /**
     * @dev 다음 평균 가격 계산 
     * @param _indexToken .
     * @param _size .
     * @param _averagePrice .
     * @param _isLong .
     * @param _nextPrice .
     * @param _sizeDelta .
     * @param _lastIncreasedTime .
     */
    function getNextAveragePrice(address _indexToken, uint256 _size, uint256 _averagePrice, bool _isLong, uint256 _nextPrice, uint256 _sizeDelta, uint256 _lastIncreasedTime) public view returns (uint256) {
        // 변화량을 확인하여 변화량이 이득인지 손해인지 체크
        (bool hasProfit, uint256 delta) = getDelta(_indexToken, _size, _averagePrice, _isLong, _lastIncreasedTime);
        uint256 nextSize = _size + _sizeDelta;
        uint256 divisor;
        // long이라면
        if (_isLong) {
            divisor = hasProfit ? nextSize + delta : nextSize - delta;
        } else {
            divisor = hasProfit ? nextSize - delta : nextSize + delta;
        }
        // (nextPrice * nextSize)/ (nextSize +- delta)
        return _nextPrice * nextSize / divisor;
    }

    function getNextGlobalShortAveragePrice(address _indexToken, uint256 _nextPrice, uint256 _sizeDelta) public view returns (uint256) {
        // for longs: nextAveragePrice = (nextPrice * nextSize)/ (nextSize + delta)
        // for shorts: nextAveragePrice = (nextPrice * nextSize) / (nextSize - delta)
        // short 크기 
        uint256 size = globalShortSizes[_indexToken];
        // short 평균 가격 가져오기
        uint256 averagePrice = globalShortAveragePrices[_indexToken];
        // 평균가와 다음 가격의 차이
        uint256 priceDelta = averagePrice > _nextPrice ? averagePrice - _nextPrice : _nextPrice - averagePrice;
        // short 크기 * 차이 / 평균가
        uint256 delta = size * priceDelta / averagePrice;
        // 다음 가격이 평균 가격보다 작으면 short
        bool hasProfit = averagePrice > _nextPrice;

        uint256 nextSize = size + _sizeDelta;
        // short이면 (다음 크기 - delta), long이면 (다음 크기 + delta)
        uint256 divisor = hasProfit ? nextSize - delta : nextSize + delta;
        // 다음 가격 * 다음 크기 / 다음 크기 +- delta
        return _nextPrice * nextSize / divisor;
    }

    function getGlobalShortDelta(address _token) public view returns (bool, uint256) {
        uint256 size = globalShortSizes[_token];
        if (size == 0) { return (false, 0); }

        // 토큰의 최대 가격
        uint256 nextPrice = getMaxPrice(_token);
        uint256 averagePrice = globalShortAveragePrices[_token];
        // 평균 short 가격과 토큰 가격간의 차이
        uint256 priceDelta = averagePrice > nextPrice ? averagePrice - nextPrice : nextPrice - averagePrice;
        // 크기 * (평균 short 가격과 토큰 가격간의 차이) 
        uint256 delta = size * priceDelta / averagePrice;
        // short 여부
        bool hasProfit = averagePrice > nextPrice;

        return (hasProfit, delta);
    }

    function getPositionDelta(address _account, address _collateralToken, address _indexToken, bool _isLong) public view returns (bool, uint256) {
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position memory position = positions[key];
        return getDelta(_indexToken, position.size, position.averagePrice, _isLong, position.lastIncreasedTime);
    }

    function getDelta(address _indexToken, uint256 _size, uint256 _averagePrice, bool _isLong, uint256 _lastIncreasedTime) public override view returns (bool, uint256) {
        // 평균 가격이 0이라면 초기값이므로 종료
        _validate(_averagePrice > 0, 38);
        // 이득이 있는지 체크해야하므로 long일 경우 
        // 여러 데이터 중 최소 가격을 가져와서 이득인지 체크할 준비
        uint256 price = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);
        uint256 priceDelta = _averagePrice > price ? _averagePrice - price : price - _averagePrice;
        uint256 delta = _size * priceDelta / _averagePrice;

        bool hasProfit;

        // long일 경우
        if (_isLong) {
            // 가격이 작성해뒀던 평균가보다 크다면 이득
            hasProfit = price > _averagePrice;
        // short일 경우
        } else {
            // 가격이 작성해뒀던 평균가보다 작다면 이득
            hasProfit = _averagePrice > price;
        }

        // 일정 시간이 지나야 최소 이득을 얻을 수 있음
        uint256 minBps = block.timestamp > _lastIncreasedTime + minProfitTime ? 0 : minProfitBasisPoints[_indexToken];
        // 이득이지만 크기의 최소 이득 이하라면 delta는 0
        if (hasProfit && delta * BASIS_POINTS_DIVISOR <= _size * minBps) {
            delta = 0;
        }

        // 이득 여부, 크기 * 가격 변화량 / 저장된 가격
        return (hasProfit, delta);
    }

    function getEntryFundingRate(address _collateralToken, address _indexToken, bool _isLong) public view returns (uint256) {
        return vaultUtils.getEntryFundingRate(_collateralToken, _indexToken, _isLong);
    }

    function getFundingFee(address _account, address _collateralToken, address _indexToken, bool _isLong, uint256 _size, uint256 _entryFundingRate) public view returns (uint256) {
        return vaultUtils.getFundingFee(_account, _collateralToken, _indexToken, _isLong, _size, _entryFundingRate);
    }

    function getPositionFee(address _account, address _collateralToken, address _indexToken, bool _isLong, uint256 _sizeDelta) public view returns (uint256) {
        return vaultUtils.getPositionFee(_account, _collateralToken, _indexToken, _isLong, _sizeDelta);
    }

    // cases to consider
    // 1. initialAmount is far from targetAmount, action increases balance slightly => high rebate
    // 2. initialAmount is far from targetAmount, action increases balance largely => high rebate
    // 3. initialAmount is close to targetAmount, action increases balance slightly => low rebate
    // 4. initialAmount is far from targetAmount, action reduces balance slightly => high tax
    // 5. initialAmount is far from targetAmount, action reduces balance largely => high tax
    // 6. initialAmount is close to targetAmount, action reduces balance largely => low tax
    // 7. initialAmount is above targetAmount, nextAmount is below targetAmount and vice versa
    // 8. a large swap should have similar fees as the same trade split into multiple smaller swaps
    function getFeeBasisPoints(address _token, uint256 _usdgDelta, uint256 _feeBasisPoints, uint256 _taxBasisPoints, bool _increment) public override view returns (uint256) {
        return vaultUtils.getFeeBasisPoints(_token, _usdgDelta, _feeBasisPoints, _taxBasisPoints, _increment);
    }

    /**
     * @dev     해당 토큰이 vault에 들어있는 총 USDG에 어느정도 중요도 비율로 가질지 목표치
     * @param   _token  .
     * @return  uint256  .
     */
    function getTargetUsdgAmount(address _token) public override view returns (uint256) {
        uint256 supply = IERC20(usdg).totalSupply();
        if (supply == 0) { return 0; }
        // 토큰 중요도 가져오기
        uint256 weight = tokenWeights[_token];
        // 토큰 중요도 * USDG 개수 / 총 토큰 중요도 
        return weight * supply / totalTokenWeights;
    }

    function _reduceCollateral(address _account, address _collateralToken, address _indexToken, uint256 _collateralDelta, uint256 _sizeDelta, bool _isLong) private returns (uint256, uint256) {
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position storage position = positions[key];

        uint256 fee = _collectMarginFees(_account, _collateralToken, _indexToken, _isLong, _sizeDelta, position.size, position.entryFundingRate);
        bool hasProfit;
        uint256 adjustedDelta;

        // scope variables to avoid stack too deep errors
        {
        (bool _hasProfit, uint256 delta) = getDelta(_indexToken, position.size, position.averagePrice, _isLong, position.lastIncreasedTime);
        hasProfit = _hasProfit;
        // get the proportional change in pnl
        adjustedDelta = _sizeDelta * delta / position.size;
        }

        uint256 usdOut;
        // transfer profits out
        if (hasProfit && adjustedDelta > 0) {
            usdOut = adjustedDelta;
            position.realisedPnl = position.realisedPnl + int256(adjustedDelta);

            // pay out realised profits from the pool amount for short positions
            if (!_isLong) {
                uint256 tokenAmount = usdToTokenMin(_collateralToken, adjustedDelta);
                _decreasePoolAmount(_collateralToken, tokenAmount);
            }
        }

        if (!hasProfit && adjustedDelta > 0) {
            position.collateral = position.collateral - adjustedDelta;

            // transfer realised losses to the pool for short positions
            // realised losses for long positions are not transferred here as
            // _increasePoolAmount was already called in increasePosition for longs
            if (!_isLong) {
                uint256 tokenAmount = usdToTokenMin(_collateralToken, adjustedDelta);
                _increasePoolAmount(_collateralToken, tokenAmount);
            }

            position.realisedPnl = position.realisedPnl - int256(adjustedDelta);
        }

        // reduce the position's collateral by _collateralDelta
        // transfer _collateralDelta out
        if (_collateralDelta > 0) {
            usdOut = usdOut + _collateralDelta;
            position.collateral -= _collateralDelta;
        }

        // if the position will be closed, then transfer the remaining collateral out
        if (position.size == _sizeDelta) {
            usdOut += position.collateral;
            position.collateral = 0;
        }

        // if the usdOut is more than the fee then deduct the fee from the usdOut directly
        // else deduct the fee from the position's collateral
        uint256 usdOutAfterFee = usdOut;
        if (usdOut > fee) {
            usdOutAfterFee = usdOut - fee;
        } else {
            position.collateral -= fee;
            if (_isLong) {
                uint256 feeTokens = usdToTokenMin(_collateralToken, fee);
                _decreasePoolAmount(_collateralToken, feeTokens);
            }
        }

        emit UpdatePnl(key, hasProfit, adjustedDelta);

        return (usdOut, usdOutAfterFee);
    }

    function _validatePosition(uint256 _size, uint256 _collateral) private view {
        if (_size == 0) {
            _validate(_collateral == 0, 39);
            return;
        }
        _validate(_size >= _collateral, 40);
    }

    function _validateRouter(address _account) private view {
        if (msg.sender == _account) { return; }
        if (msg.sender == router) { return; }
        _validate(approvedRouters[_account][msg.sender], 41);
    }

    function _validateTokens(address _collateralToken, address _indexToken, bool _isLong) private view {
        if (_isLong) {
            _validate(_collateralToken == _indexToken, 42);
            _validate(whitelistedTokens[_collateralToken], 43);
            _validate(!stableTokens[_collateralToken], 44);
            return;
        }

        _validate(whitelistedTokens[_collateralToken], 45);
        _validate(stableTokens[_collateralToken], 46);
        _validate(!stableTokens[_indexToken], 47);
        _validate(shortableTokens[_indexToken], 48);
    }

    function _collectSwapFees(address _token, uint256 _amount, uint256 _feeBasisPoints) private returns (uint256) {
        uint256 afterFeeAmount = _amount * (BASIS_POINTS_DIVISOR - _feeBasisPoints) / BASIS_POINTS_DIVISOR;
        uint256 feeAmount = _amount - afterFeeAmount;
        feeReserves[_token] = feeReserves[_token] + feeAmount;
        emit CollectSwapFees(_token, tokenToUsdMin(_token, feeAmount), feeAmount);
        return afterFeeAmount;
    }

    function _collectMarginFees(address _account, address _collateralToken, address _indexToken, bool _isLong, uint256 _sizeDelta, uint256 _size, uint256 _entryFundingRate) private returns (uint256) {
        uint256 feeUsd = getPositionFee(_account, _collateralToken, _indexToken, _isLong, _sizeDelta);

        // 포지션 총 크기 * fundingRate
        uint256 fundingFee = getFundingFee(_account, _collateralToken, _indexToken, _isLong, _size, _entryFundingRate);
        feeUsd = feeUsd + fundingFee;

        uint256 feeTokens = usdToTokenMin(_collateralToken, feeUsd);
        feeReserves[_collateralToken] = feeReserves[_collateralToken] + feeTokens;

        emit CollectMarginFees(_collateralToken, feeUsd, feeTokens);
        return feeUsd;
    }

    function _transferIn(address _token) private returns (uint256) {
        uint256 prevBalance = tokenBalances[_token];
        uint256 nextBalance = IERC20(_token).balanceOf(address(this));
        tokenBalances[_token] = nextBalance;

        return nextBalance - prevBalance;
    }

    function _transferOut(address _token, uint256 _amount, address _receiver) private {
        IERC20(_token).safeTransfer(_receiver, _amount);
        tokenBalances[_token] = IERC20(_token).balanceOf(address(this));
    }

    function _updateTokenBalance(address _token) private {
        uint256 nextBalance = IERC20(_token).balanceOf(address(this));
        tokenBalances[_token] = nextBalance;
    }

    function _increasePoolAmount(address _token, uint256 _amount) private {
        poolAmounts[_token] = poolAmounts[_token] + _amount;
        uint256 balance = IERC20(_token).balanceOf(address(this));
        _validate(poolAmounts[_token] <= balance, 49);
        emit IncreasePoolAmount(_token, _amount);
    }

    function _decreasePoolAmount(address _token, uint256 _amount) private {
        poolAmounts[_token] = poolAmounts[_token] - _amount;
        _validate(reservedAmounts[_token] <= poolAmounts[_token], 50);
        emit DecreasePoolAmount(_token, _amount);
    }

    function _validateBufferAmount(address _token) private view {
        if (poolAmounts[_token] < bufferAmounts[_token]) {
            revert("Vault: poolAmount < buffer");
        }
    }

    function _increaseUsdgAmount(address _token, uint256 _amount) private {
        usdgAmounts[_token] = usdgAmounts[_token] + _amount;
        uint256 maxUsdgAmount = maxUsdgAmounts[_token];
        if (maxUsdgAmount != 0) {
            _validate(usdgAmounts[_token] <= maxUsdgAmount, 51);
        }
        emit IncreaseUsdgAmount(_token, _amount);
    }

    function _decreaseUsdgAmount(address _token, uint256 _amount) private {
        uint256 value = usdgAmounts[_token];
        // since USDG can be minted using multiple assets
        // it is possible for the USDG debt for a single asset to be less than zero
        // the USDG debt is capped to zero for this case
        if (value <= _amount) {
            usdgAmounts[_token] = 0;
            emit DecreaseUsdgAmount(_token, value);
            return;
        }
        usdgAmounts[_token] = value - _amount;
        emit DecreaseUsdgAmount(_token, _amount);
    }

    function _increaseReservedAmount(address _token, uint256 _amount) private {
        reservedAmounts[_token] = reservedAmounts[_token] + _amount;
        _validate(reservedAmounts[_token] <= poolAmounts[_token], 52);
        emit IncreaseReservedAmount(_token, _amount);
    }

    function _decreaseReservedAmount(address _token, uint256 _amount) private {
        reservedAmounts[_token] = reservedAmounts[_token] - _amount;
        emit DecreaseReservedAmount(_token, _amount);
    }

    function _increaseGuaranteedUsd(address _token, uint256 _usdAmount) private {
        guaranteedUsd[_token] = guaranteedUsd[_token] + _usdAmount;
        emit IncreaseGuaranteedUsd(_token, _usdAmount);
    }

    function _decreaseGuaranteedUsd(address _token, uint256 _usdAmount) private {
        guaranteedUsd[_token] = guaranteedUsd[_token] - _usdAmount;
        emit DecreaseGuaranteedUsd(_token, _usdAmount);
    }

    function _increaseGlobalShortSize(address _token, uint256 _amount) internal {
        globalShortSizes[_token] = globalShortSizes[_token] + _amount;

        uint256 maxSize = maxGlobalShortSizes[_token];
        if (maxSize != 0) {
            require(globalShortSizes[_token] <= maxSize, "Vault: max shorts exceeded");
        }
    }

    function _decreaseGlobalShortSize(address _token, uint256 _amount) private {
        uint256 size = globalShortSizes[_token];
        if (_amount > size) {
          globalShortSizes[_token] = 0;
          return;
        }

        globalShortSizes[_token] = size - _amount;
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _onlyGov() private view {
        _validate(msg.sender == gov, 53);
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _validateManager() private view {
        if (inManagerMode) {
            _validate(isManager[msg.sender], 54);
        }
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _validateGasPrice() private view {
        if (maxGasPrice == 0) { return; }
        _validate(tx.gasprice <= maxGasPrice, 55);
    }

    function _validate(bool _condition, uint256 _errorCode) private view {
        require(_condition, errors[_errorCode]);
    }
}