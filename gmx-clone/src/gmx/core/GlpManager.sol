// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../libraries/token/SafeERC20.sol";
import "../libraries/utils/ReentrancyGuard.sol";

import "./interfaces/IVault.sol";
import "./interfaces/IGlpManager.sol";
import "./interfaces/IShortsTracker.sol";
import "../tokens/interfaces/IUSDG.sol";
import "../tokens/interfaces/IMintable.sol";
import "../access/Governable.sol";


contract GlpManager is ReentrancyGuard, Governable, IGlpManager {
    using SafeERC20 for IERC20;

    uint256 public constant PRICE_PRECISION = 10 ** 30;
    uint256 public constant USDG_DECIMALS = 18;
    uint256 public constant GLP_PRECISION = 10 ** 18;
    uint256 public constant MAX_COOLDOWN_DURATION = 48 hours;
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    IVault public override vault;
    IShortsTracker public shortsTracker;
    address public override usdg;
    address public override glp;

    uint256 public override cooldownDuration;
    mapping (address => uint256) public override lastAddedAt;

    uint256 public aumAddition;
    uint256 public aumDeduction;

    bool public inPrivateMode;
    uint256 public shortsTrackerAveragePriceWeight;
    mapping (address => bool) public isHandler;

    event AddLiquidity(
        address account,
        address token,
        uint256 amount,
        uint256 aumInUsdg,
        uint256 glpSupply,
        uint256 usdgAmount,
        uint256 mintAmount
    );

    event RemoveLiquidity(
        address account,
        address token,
        uint256 glpAmount,
        uint256 aumInUsdg,
        uint256 glpSupply,
        uint256 usdgAmount,
        uint256 amountOut
    );

    constructor(address _vault, address _usdg, address _glp, address _shortsTracker, uint256 _cooldownDuration) {
        gov = msg.sender;
        vault = IVault(_vault);
        usdg = _usdg;
        glp = _glp;
        shortsTracker = IShortsTracker(_shortsTracker);
        cooldownDuration = _cooldownDuration;
    }

    function setShortsTracker(IShortsTracker _shortsTracker) external onlyGov {
        shortsTracker = _shortsTracker;
    }

    function setShortsTrackerAveragePriceWeight(uint256 _shortsTrackerAveragePriceWeight) external override onlyGov {
        require(shortsTrackerAveragePriceWeight <= BASIS_POINTS_DIVISOR, "GlpManager: invalid weight");
        shortsTrackerAveragePriceWeight = _shortsTrackerAveragePriceWeight;
    }

    function setHandler(address _handler, bool _isActive) external onlyGov {
        isHandler[_handler] = _isActive;
    }

    function setCooldownDuration(uint256 _cooldownDuration) external override onlyGov {
        require(_cooldownDuration <= MAX_COOLDOWN_DURATION, "GlpManager: invalid _cooldownDuration");
        cooldownDuration = _cooldownDuration;
    }

    function setAumAdjustment(uint256 _aumAddition, uint256 _aumDeduction) external onlyGov {
        aumAddition = _aumAddition;
        aumDeduction = _aumDeduction;
    }
    
    function addLiquidity(address _token, uint256 _amount, uint256 _minUsdg, uint256 _minGlp) external override nonReentrant returns (uint256) {
        if (inPrivateMode) { revert("GlpManager: action not enabled"); }
        return _addLiquidity(msg.sender, msg.sender, _token, _amount, _minUsdg, _minGlp);
    }

    function addLiquidityForAccount(address _fundingAccount, address _account, address _token, uint256 _amount, uint256 _minUsdg, uint256 _minGlp) external override nonReentrant returns (uint256) {
        _validateHandler();
        return _addLiquidity(_fundingAccount, _account, _token, _amount, _minUsdg, _minGlp);
    }

    function removeLiquidity(address _tokenOut, uint256 _glpAmount, uint256 _minOut, address _receiver) external override nonReentrant returns (uint256) {
        if (inPrivateMode) { revert("GlpManager: action not enabled"); }
        return _removeLiquidity(msg.sender, _tokenOut, _glpAmount, _minOut, _receiver);
    }

    function removeLiquidityForAccount(address _account, address _tokenOut, uint256 _glpAmount, uint256 _minOut, address _receiver) external override nonReentrant returns (uint256) {
        _validateHandler();
        return _removeLiquidity(_account, _tokenOut, _glpAmount, _minOut, _receiver);
    }

    function getPrice(bool _maximise) external view returns (uint256) {
        uint256 aum = getAum(_maximise);
        uint256 supply = IERC20(glp).totalSupply();
        return aum * GLP_PRECISION / supply;
    }

    /**
     * @dev     컨트랙트와 연관된 자산(토큰)의 총 가치
     * @return  uint256[]  
     */
    function getAums() public view returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](2);
        // 최대가
        amounts[0] = getAum(true);
        // 최소가
        amounts[1] = getAum(false);
        return amounts;
    }

    function getAumInUsdg(bool maximise) public override view returns (uint256) {
        uint256 aum = getAum(maximise);
        return aum * 10 ** USDG_DECIMALS / PRICE_PRECISION;
    }

    function getAum(bool maximise) public view returns (uint256) {
        uint256 length = vault.allWhitelistedTokensLength();
        // AUM 초기값
        uint256 aum = aumAddition;
        uint256 shortProfits = 0;
        IVault _vault = vault;

        // 모든 등록된 토큰들에서 반복
        for (uint256 i = 0; i < length; i++) {
            // 등록된 토큰들 중 리스트에만 존재하고 실제 등록이 되지 않은 경우 패스
            address token = vault.allWhitelistedTokens(i);
            bool isWhitelisted = vault.whitelistedTokens(token);

            if (!isWhitelisted) {
                continue;
            }

            uint256 price = maximise ? _vault.getMaxPrice(token) : _vault.getMinPrice(token);
            uint256 poolAmount = _vault.poolAmounts(token);
            uint256 decimals = _vault.tokenDecimals(token);

            // 스테이블 코인이라면 AUM에 추가
            if (_vault.stableTokens(token)) {
                aum = aum + (poolAmount * price / 10 ** decimals);
            } else {
                // 일반 토큰이라면 글로벌 short 크기를 가져온 뒤
                // add global short profit / loss
                uint256 size = _vault.globalShortSizes(token);

                // 크기가 0보다 크다면
                if (size > 0) {
                    (uint256 delta, bool hasProfit) = getGlobalShortDelta(token, price, size);
                    // long일 경우
                    if (!hasProfit) {
                        // AUM + 변화량
                        aum = aum + delta;
                    } else {
                        // short일 경우 short 이득 + 변화량
                        shortProfits = shortProfits + delta;
                    }
                }

                // AUM에 담보 가치 더하기
                aum += _vault.guaranteedUsd(token);

                // AUM + ((토큰 pool - reserve) * 토큰 가격)
                // 토큰 pool - reserve = 토큰 개수, 즉 토큰 개수 * 토큰 가격 계산으로 가치 계산
                // 결과적으로 예약된 토큰을 제외한 풀에 있는 토큰의 총 가치를 AUM에 더하는 것
                uint256 reservedAmount = _vault.reservedAmounts(token);
                aum = aum + (poolAmount - (reservedAmount * price / 10 ** decimals));
            }
        }

        // AUM이 short 이득보다 크다면 AUM = (AUM - short 이득)
        aum = shortProfits > aum ? 0 : aum - shortProfits;
        // AUM 감소
        return aumDeduction > aum ? 0 : aum - aumDeduction;
    }

    function getGlobalShortDelta(address _token, uint256 _price, uint256 _size) public view returns (uint256, bool) {
        uint256 averagePrice = getGlobalShortAveragePrice(_token);
        uint256 priceDelta = averagePrice > _price ? averagePrice - _price : _price - averagePrice;
        // 크기 * (이후 가격과 평균 가격 차이) / 평균 가격
        uint256 delta = _size * priceDelta / averagePrice;
        // (변화량, short 여부)
        return (delta, averagePrice > _price);
    }

    function getGlobalShortAveragePrice(address _token) public view returns (uint256) {
        // short 추적 주소가 설정되어있지 않거나 글로벌 short 데이터가 없다면 평균 short 가격 사용
        IShortsTracker _shortsTracker = shortsTracker;
        if (address(_shortsTracker) == address(0) || !_shortsTracker.isGlobalShortDataReady()) {
            return vault.globalShortAveragePrices(_token);
        }

        // vault와 shortsTracker의 globalShortAveragePrices 중 어떤거에 더 가중치를 둘지에 따라 다르게 동작 (0이면 vault에 100%, 10000이면 shortsTracker에 100%)
        uint256 _shortsTrackerAveragePriceWeight = shortsTrackerAveragePriceWeight;
        // 0이면 vault 가격 사용
        if (_shortsTrackerAveragePriceWeight == 0) {
            return vault.globalShortAveragePrices(_token);
        // 10000이면 shortsTracker 가격 사용
        } else if (_shortsTrackerAveragePriceWeight == BASIS_POINTS_DIVISOR) {
            return _shortsTracker.globalShortAveragePrices(_token);
        }

        // 가중치가 0이나 10000이 아니라면 두 데이터를 적절히 섞어서 사용
        uint256 vaultAveragePrice = vault.globalShortAveragePrices(_token);
        uint256 shortsTrackerAveragePrice = _shortsTracker.globalShortAveragePrices(_token);
        // vault 가격 * (10000 - 가중치) + shortsTracker 가격 * (가중치)
        return vaultAveragePrice * (BASIS_POINTS_DIVISOR - _shortsTrackerAveragePriceWeight)
            + (shortsTrackerAveragePrice * _shortsTrackerAveragePriceWeight)
            / BASIS_POINTS_DIVISOR;
    }   
    
    /**
     * @dev     유동성 공급 후 GLP 민팅
     * @param   _fundingAccount  .
     * @param   _account  .
     * @param   _token  .
     * @param   _amount  .
     * @param   _minUsdg .
     * @param   _minGlp  .
     * @return  uint256  .
     */
    function _addLiquidity(address _fundingAccount, address _account, address _token, uint256 _amount, uint256 _minUsdg, uint256 _minGlp) private returns (uint256) {
        require(_amount > 0, "GlpManager: invalid _amount");

        // AUM를 USDG 토큰으로 변환했을 때 총 개수
        uint256 aumInUsdg = getAumInUsdg(true);
        // GLP 토큰 총 개수
        uint256 glpSupply = IERC20(glp).totalSupply();

        // vault로 유동성 추가할 토큰 전송
        IERC20(_token).safeTransferFrom(_fundingAccount, address(vault), _amount);
        // 토큰을 USDG로 swap
        uint256 usdgAmount = vault.buyUSDG(_token, address(this));
        // swap한 양이 유저가 예상하는 최소 USDG보다 적을 경우 revert
        require(usdgAmount >= _minUsdg, "GlpManager: insufficient USDG output");

        // AUM을 USDG로 변환했을 때 0개라면 토큰을 USDG로 swap한 개수 사용
        // 아니라면 (토큰을 USDG로 swap한 개수 * GLP 총 개수) / AUM을 USDG로 변환했을 때 개수
        uint256 mintAmount = aumInUsdg == 0 ? usdgAmount : usdgAmount * glpSupply / aumInUsdg;
        // 이 개수는 예상하는 최소 GLP양보다 커야한다
        require(mintAmount >= _minGlp, "GlpManager: insufficient GLP output");

        // GLP 민팅
        IMintable(glp).mint(_account, mintAmount);

        // 언제 민팅했는지 시간 기록
        lastAddedAt[_account] = block.timestamp;

        emit AddLiquidity(_account, _token, _amount, aumInUsdg, glpSupply, usdgAmount, mintAmount);

        return mintAmount;
    }

    function _removeLiquidity(address _account, address _tokenOut, uint256 _glpAmount, uint256 _minOut, address _receiver) private returns (uint256) {
        require(_glpAmount > 0, "GlpManager: invalid _glpAmount");
        require(lastAddedAt[_account] + cooldownDuration <= block.timestamp, "GlpManager: cooldown duration not yet passed");

        // AUM 계산
        uint256 aumInUsdg = getAumInUsdg(false);
        // GLP 총량 계산
        uint256 glpSupply = IERC20(glp).totalSupply();

        // USDG 개수 = (빼고 싶은 GLP * AUM을 USDG로 변환했을 때 개수) / GLP 총 개수
        uint256 usdgAmount = _glpAmount * aumInUsdg / glpSupply;
        // 컨트랙트 총 USDG
        uint256 usdgBalance = IERC20(usdg).balanceOf(address(this));
        // 컨트랙트에 들어있는 총 USDG를 넘어갈 경우
        if (usdgAmount > usdgBalance) {
            // USDG를 부족분만큼 민팅
            IUSDG(usdg).mint(address(this), usdgAmount - usdgBalance);
        }

        // 제거한 유동성 GLP토큰 burn
        IMintable(glp).burn(_account, _glpAmount);
        // 부족분 이외의 USDG 전송
        IERC20(usdg).transfer(address(vault), usdgAmount);
        // USDG를 토큰으로 변환했을 때 토큰 개수
        uint256 amountOut = vault.sellUSDG(_tokenOut, _receiver);
        // 유저가 예상한 토큰 최소량보다 작다면 revert
        require(amountOut >= _minOut, "GlpManager: insufficient output");

        emit RemoveLiquidity(_account, _tokenOut, _glpAmount, aumInUsdg, glpSupply, usdgAmount, amountOut);

        return amountOut;
    }

    // 등록된 핸들러만 사용가능
    function _validateHandler() private view {
        require(isHandler[msg.sender], "GlpManager: forbidden");
    }
}