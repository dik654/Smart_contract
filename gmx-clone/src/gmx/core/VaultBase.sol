// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../libraries/token/SafeERC20.sol";
import "../libraries/utils/ReentrancyGuard.sol";

import "./interfaces/IVaultBase.sol";
import "./interfaces/IVaultUtils.sol";
import "./interfaces/IVaultPriceFeed.sol";

contract VaultBase is IVaultBase {
    using SafeERC20 for IERC20;
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

    address public vaultSwap;
    address public vaultTrading;
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

    // forge create --rpc-url localhost:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 src/core/Vault.sol:Vault
    // once the parameters are verified to be working correctly,
    // gov should be set to a timelock contract or a governance contract
    constructor() {
        gov = msg.sender;
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _onlyGov() private view {
        validate(msg.sender == gov, 53);
    }

    function _onlyVault() private view {
        validate(msg.sender == vaultSwap || msg.sender == vaultTrading, 53);
    }

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

    function setVaultSwap(address _vaultSwap) public {
        _onlyGov();
        vaultSwap = _vaultSwap;
    }

    function setVaultTrading(address _vaultTrading) public {
        _onlyGov();
        vaultTrading = _vaultTrading;
    }


    function setVaultUtils(address _vaultUtils) external override {
        _onlyGov();
        vaultUtils = IVaultUtils(_vaultUtils);
    }

    function setErrorController(address _errorController) external {
        _onlyGov();
        errorController = _errorController;
    }

    function setError(uint256 _errorCode, string calldata _error) external override {
        require(msg.sender == errorController, "Vault: invalid errorController");
        errors[_errorCode] = _error;
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
        validate(_maxLeverage > MIN_LEVERAGE, 2);
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

    function initialize(
        address _router,
        address _usdg,
        address _priceFeed,
        uint256 _liquidationFeeUsd,
        uint256 _fundingRateFactor,
        uint256 _stableFundingRateFactor
    ) external {
        _onlyGov();
        validate(!isInitialized, 1);
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
        validate(_taxBasisPoints <= MAX_FEE_BASIS_POINTS, 3);
        validate(_stableTaxBasisPoints <= MAX_FEE_BASIS_POINTS, 4);
        validate(_mintBurnFeeBasisPoints <= MAX_FEE_BASIS_POINTS, 5);
        validate(_swapFeeBasisPoints <= MAX_FEE_BASIS_POINTS, 6);
        validate(_stableSwapFeeBasisPoints <= MAX_FEE_BASIS_POINTS, 7);
        validate(_marginFeeBasisPoints <= MAX_FEE_BASIS_POINTS, 8);
        validate(_liquidationFeeUsd <= MAX_LIQUIDATION_FEE_USD, 9);
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
        validate(_fundingInterval >= MIN_FUNDING_RATE_INTERVAL, 10);
        validate(_fundingRateFactor <= MAX_FUNDING_RATE_FACTOR, 11);
        validate(_stableFundingRateFactor <= MAX_FUNDING_RATE_FACTOR, 12);
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
            whitelistedTokenCount += 1;
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
        validate(whitelistedTokens[_token], 13);
        totalTokenWeights = totalTokenWeights - tokenWeights[_token];
        delete whitelistedTokens[_token];
        delete tokenDecimals[_token];
        delete tokenWeights[_token];
        delete minProfitBasisPoints[_token];
        delete maxUsdgAmounts[_token];
        delete stableTokens[_token];
        delete shortableTokens[_token];
        whitelistedTokenCount -= 1;
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
        transferOut(_token, amount, _receiver);
        return amount;
    }

    function setUsdgAmount(address _token, uint256 _amount) external {
        _onlyGov();

        uint256 usdgAmount = usdgAmounts[_token];
        if (_amount > usdgAmount) {
        increaseUsdgAmount(_token, _amount - usdgAmount);
            return;
        }
        decreaseUsdgAmount(_token, usdgAmount - _amount);
    }

    function addRouter(address _router) external {
        approvedRouters[msg.sender][_router] = true;
    }

    function removeRouter(address _router) external {
        approvedRouters[msg.sender][_router] = false;
    }

    // note that if calling this function independently the cumulativeFundingRates used in getFundingFee will not be the latest value
    // validateLiquidation returns (state, fees)
    function validateLiquidation(address _account, address _collateralToken, address _indexToken, bool _isLong, bool _raise) override public view returns (uint256, uint256) {
        return vaultUtils.validateLiquidation(_account, _collateralToken, _indexToken, _isLong, _raise);
    }

    function allWhitelistedTokensLength() external override view returns (uint256) {
        return allWhitelistedTokens.length;
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
        return _adjustForDecimals(redemptionAmount, usdg, _token);
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

    function _adjustForDecimals(uint256 _amount, address _tokenDiv, address _tokenMul) internal view returns (uint256) {
        uint256 decimalsDiv = _tokenDiv == usdg ? USDG_DECIMALS : tokenDecimals[_tokenDiv];
        uint256 decimalsMul = _tokenMul == usdg ? USDG_DECIMALS : tokenDecimals[_tokenMul];
        return _amount * 10 ** decimalsMul / 10 ** decimalsDiv;
    }

    function adjustForDecimals(uint256 _amount, address _tokenDiv, address _tokenMul) external view returns (uint256) {
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

    function deletePosition(bytes32 _keys) external returns (bool) {
        delete positions[_keys];
    }

    function setPosition(bytes32 _key, Position calldata _position) external returns (bool) {
        _onlyVault();
        positions[_key] = _position;
        return true;
    }

    function setIncludeAmmPrice(bool _setting) external {
        _onlyVault();
        includeAmmPrice = _setting;
    }
    
    /**
     * @dev interval동안 pool에 추가된 reserve 토큰 비율 업데이트
     * @param _collateralToken .
     * @param _indexToken .
     */
    function updateCumulativeFundingRate(address _collateralToken, address _indexToken) external {
        _onlyVault();

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
        validate(position.collateral > 0, 37);
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
    function getNextAveragePrice(address _indexToken, uint256 _size, uint256 _averagePrice, bool _isLong, uint256 _nextPrice, uint256 _sizeDelta, uint256 _lastIncreasedTime) external view returns (uint256) {
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
        validate(_averagePrice > 0, 38);
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

    function validateRouter(address _account) external view {
        if (msg.sender == _account) { return; }
        if (msg.sender == router) { return; }
        validate(approvedRouters[_account][msg.sender], 41);
    }

    function validateTokens(address _collateralToken, address _indexToken, bool _isLong) external view {
        if (_isLong) {
            validate(_collateralToken == _indexToken, 42);
            validate(whitelistedTokens[_collateralToken], 43);
            validate(!stableTokens[_collateralToken], 44);
            return;
        }

        validate(whitelistedTokens[_collateralToken], 45);
        validate(stableTokens[_collateralToken], 46);
        validate(!stableTokens[_indexToken], 47);
        validate(shortableTokens[_indexToken], 48);
    }

    function increaseUsdgAmount(address _token, uint256 _amount) public {
        _onlyVault();
        usdgAmounts[_token] = usdgAmounts[_token] + _amount;
        uint256 maxUsdgAmount = maxUsdgAmounts[_token];
        if (maxUsdgAmount != 0) {
            validate(usdgAmounts[_token] <= maxUsdgAmount, 51);
        }
        emit IncreaseUsdgAmount(_token, _amount);
    }

    function decreaseUsdgAmount(address _token, uint256 _amount) public {
        _onlyVault();
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

    function transferIn(address _token) external returns (uint256) {
        _onlyVault();
        uint256 prevBalance = tokenBalances[_token];
        uint256 nextBalance = IERC20(_token).balanceOf(address(this));
        tokenBalances[_token] = nextBalance;

        return nextBalance - prevBalance;
    }

    function transferOut(address _token, uint256 _amount, address _receiver) public {
        _onlyVault();
        IERC20(_token).safeTransfer(_receiver, _amount);
        tokenBalances[_token] = IERC20(_token).balanceOf(address(this));
    }

    function updateTokenBalance(address _token) external {
        _onlyVault();
        uint256 nextBalance = IERC20(_token).balanceOf(address(this));
        tokenBalances[_token] = nextBalance;
    }

    function increaseFeeReserves(address _token, uint256 _amount) external {
        _onlyVault();
        feeReserves[_token] += _amount;
    }

    function increaseGlobalShortSize(address _token, uint256 _amount) external {
        _onlyVault();
        globalShortSizes[_token] += _amount;
    }

    function decreaseGlobalShortSize(address _token, uint256 _amount) external {
        _onlyVault();
        globalShortSizes[_token] -= _amount;
    }

    function increasePoolAmount(address _token, uint256 _amount) external {
        _onlyVault();
        poolAmounts[_token] = poolAmounts[_token] + _amount;
        uint256 balance = IERC20(_token).balanceOf(address(this));
        validate(poolAmounts[_token] <= balance, 49);
        emit IncreasePoolAmount(_token, _amount);
    }

    function decreasePoolAmount(address _token, uint256 _amount) external {
        _onlyVault();
        poolAmounts[_token] = poolAmounts[_token] - _amount;
        validate(reservedAmounts[_token] <= poolAmounts[_token], 50);
        emit DecreasePoolAmount(_token, _amount);
    }

    function validateBufferAmount(address _token) external view {
        if (poolAmounts[_token] < bufferAmounts[_token]) {
            revert("Vault: poolAmount < buffer");
        }
    }

    function increaseReservedAmount(address _token, uint256 _amount) external {
        _onlyVault();
        reservedAmounts[_token] = reservedAmounts[_token] + _amount;
        validate(reservedAmounts[_token] <= poolAmounts[_token], 52);
        emit IncreaseReservedAmount(_token, _amount);
    }

    function decreaseReservedAmount(address _token, uint256 _amount) external {
        _onlyVault();
        reservedAmounts[_token] = reservedAmounts[_token] - _amount;
        emit DecreaseReservedAmount(_token, _amount);
    }

    function increaseGuaranteedUsd(address _token, uint256 _usdAmount) external {
        _onlyVault();
        guaranteedUsd[_token] = guaranteedUsd[_token] + _usdAmount;
        emit IncreaseGuaranteedUsd(_token, _usdAmount);
    }

    function _decreaseGuaranteedUsd(address _token, uint256 _usdAmount) external {
        _onlyVault();
        guaranteedUsd[_token] = guaranteedUsd[_token] - _usdAmount;
        emit DecreaseGuaranteedUsd(_token, _usdAmount);
    }


    function validate(bool _condition, uint256 _errorCode) public view {
        require(_condition, errors[_errorCode]);
    }
}