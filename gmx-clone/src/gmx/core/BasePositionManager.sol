// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../tokens/interfaces/IWETH.sol";
import "../libraries/token/SafeERC20.sol";
import "../libraries/utils/Address.sol";
import "../libraries/utils/ReentrancyGuard.sol";

import "./interfaces/IRouter.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IShortsTracker.sol";
import "./interfaces/IOrderBook.sol";
import "./interfaces/IBasePositionManager.sol";

import "../access/Governable.sol";

contract BasePositionManager is IBasePositionManager, ReentrancyGuard, Governable {
    using SafeERC20 for IERC20;
    using Address for address payable;

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    address public admin;

    address public vault;
    address public shortsTracker;
    address public router;
    address public weth;
    uint256 public marginFeeBasisPoints = 1;
    uint256 public maxMarginFeeBasisPoints = 50; 

    uint256 public ethTransferGasLimit = 500 * 1000;

    // to prevent using the deposit and withdrawal of collateral as a zero fee swap,
    // there is a small depositFee charged if a collateral deposit results in the decrease
    // of leverage for an existing position
    // increasePositionBufferBps allows for a small amount of decrease of leverage
    uint256 public depositFee;
    uint256 public increasePositionBufferBps = 100;

    mapping (address => uint256) public feeReserves;

    mapping (address => uint256) public override maxGlobalLongSizes;
    mapping (address => uint256) public override maxGlobalShortSizes;

    event SetDepositFee(uint256 depositFee);
    event SetEthTransferGasLimit(uint256 ethTransferGasLimit);
    event SetIncreasePositionBufferBps(uint256 increasePositionBufferBps);
    event SetAdmin(address admin);
    event WithdrawFees(address token, address receiver, uint256 amount);
    event LeverageDecreased(uint256 collateralDelta, uint256 prevLeverage, uint256 nextLeverage);

    event SetMaxGlobalSizes(
        address[] tokens,
        uint256[] longSizes,
        uint256[] shortSizes
    );

    modifier onlyAdmin() {
        require(msg.sender == admin, "forbidden");
        _;
    }

    constructor(
        address _vault,
        address _router,
        address _shortsTracker,
        address _weth,
        uint256 _depositFee
    ) {
        vault = _vault;
        router = _router;
        weth = _weth;
        depositFee = _depositFee;
        shortsTracker = _shortsTracker;
        admin = msg.sender;
    }

    receive() external payable {
        require(msg.sender == weth, "invalid sender");
    }

    function setAdmin(address _admin) external onlyGov {
        admin = _admin;
        emit SetAdmin(_admin);
    }

    function setEthTransferGasLimit(uint256 _ethTransferGasLimit) external onlyAdmin {
        ethTransferGasLimit = _ethTransferGasLimit;
        emit SetEthTransferGasLimit(_ethTransferGasLimit);
    }

    function setDepositFee(uint256 _depositFee) external onlyAdmin {
        depositFee = _depositFee;
        emit SetDepositFee(_depositFee);
    }

    function setIncreasePositionBufferBps(uint256 _increasePositionBufferBps) external onlyAdmin {
        increasePositionBufferBps = _increasePositionBufferBps;
        emit SetIncreasePositionBufferBps(_increasePositionBufferBps);
    }

    function setMaxGlobalSizes(
        address[] memory _tokens,
        uint256[] memory _longSizes,
        uint256[] memory _shortSizes
    ) external onlyAdmin {
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            maxGlobalLongSizes[token] = _longSizes[i];
            maxGlobalShortSizes[token] = _shortSizes[i];
        }

        emit SetMaxGlobalSizes(_tokens, _longSizes, _shortSizes);
    }

    function withdrawFees(address _token, address _receiver) external onlyAdmin {
        uint256 amount = feeReserves[_token];
        if (amount == 0) { return; }

        feeReserves[_token] = 0;
        IERC20(_token).safeTransfer(_receiver, amount);

        emit WithdrawFees(_token, _receiver, amount);
    }

    function approve(address _token, address _spender, uint256 _amount) external onlyGov {
        IERC20(_token).approve(_spender, _amount);
    }

    function sendValue(address payable _receiver, uint256 _amount) external onlyGov {
        _receiver.sendValue(_amount);
    }

    function _validateMaxGlobalSize(address _indexToken, bool _isLong, uint256 _sizeDelta) internal view {
        if (_sizeDelta == 0) {
            return;
        }

        if (_isLong) {
            uint256 maxGlobalLongSize = maxGlobalLongSizes[_indexToken];
            if (maxGlobalLongSize > 0 && IVault(vault).guaranteedUsd(_indexToken) + _sizeDelta > maxGlobalLongSize) {
                revert("max longs exceeded");
            }
        } else {
            uint256 maxGlobalShortSize = maxGlobalShortSizes[_indexToken];
            if (maxGlobalShortSize > 0 && IVault(vault).globalShortSizes(_indexToken) + _sizeDelta > maxGlobalShortSize) {
                revert("max shorts exceeded");
            }
        }
    }

    function _increasePosition(address _account, address _collateralToken, address _indexToken, uint256 _sizeDelta, bool _isLong, uint256 _price) internal {
        _validateMaxGlobalSize(_indexToken, _isLong, _sizeDelta);

        // markPrice = 현재 최대 가격
        uint256 markPrice = _isLong ? IVault(vault).getMaxPrice(_indexToken) : IVault(vault).getMinPrice(_indexToken);
        // long일 때 포지션을 키우는데 목표가격이 현재 가격보다 작으면 에러
        if (_isLong) {
            require(markPrice <= _price, "markPrice > price");
        // short일 때 포지션을 키우는데 목표가격이 현재 가격보다 크면 에러 
        } else {
            require(markPrice >= _price, "markPrice < price");
        }

        // TODO
        IShortsTracker(shortsTracker).updateGlobalShortData(_account, _collateralToken, _indexToken, _isLong, _sizeDelta, markPrice, true);

        // IsLeverageEnabled 켜기
        // 주요한 목적은 maxMarginFeeBasisPoints를 marginFeeBasisPoints로 바꾸어 
        // 이 트랜잭션을 실행하는동안만 레버리지 마진 수수료율을 적용할 수 있도록 하여 
        // 레버리지 거래를 하지않는 평소에는 최대 마진 수수료율 제한이 유지되도록 한다
        _enableLeverage();
        // 유저가 approve한 router로 실행시켰는지 체크 후 vault의 increasePosition 실행
        IRouter(router).pluginIncreasePosition(_account, _collateralToken, _indexToken, _sizeDelta, _isLong);
        _disableLeverage();
    }

    function _decreasePosition(address _account, address _collateralToken, address _indexToken, uint256 _collateralDelta, uint256 _sizeDelta, bool _isLong, address _receiver, uint256 _price) internal returns (uint256) {
        address _vault = vault;

        uint256 markPrice = _isLong ? IVault(_vault).getMinPrice(_indexToken) : IVault(_vault).getMaxPrice(_indexToken);
        if (_isLong) {
            require(markPrice >= _price, "markPrice < price");
        } else {
            require(markPrice <= _price, "markPrice > price");
        }

        // should be called strictly before position is updated in Vault
        IShortsTracker(shortsTracker).updateGlobalShortData(_account, _collateralToken, _indexToken, _isLong, _sizeDelta, markPrice, false);

        _enableLeverage();
        uint256 amountOut = IRouter(router).pluginDecreasePosition(_account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, _receiver);
        _disableLeverage();

        return amountOut;
    }

    function _enableLeverage() internal {
        
        IVault(vault).setIsLeverageEnabled(true);

        IVault(vault).setFees(
            IVault(vault).taxBasisPoints(),
            IVault(vault).stableTaxBasisPoints(),
            IVault(vault).mintBurnFeeBasisPoints(),
            IVault(vault).swapFeeBasisPoints(),
            IVault(vault).stableSwapFeeBasisPoints(),
            marginFeeBasisPoints,
            IVault(vault).liquidationFeeUsd(),
            IVault(vault).minProfitTime(),
            IVault(vault).hasDynamicFees()
        );
    }

    function _disableLeverage() internal {
        IVault(vault).setIsLeverageEnabled(false);

        IVault(vault).setFees(
            IVault(vault).taxBasisPoints(),
            IVault(vault).stableTaxBasisPoints(),
            IVault(vault).mintBurnFeeBasisPoints(),
            IVault(vault).swapFeeBasisPoints(),
            IVault(vault).stableSwapFeeBasisPoints(),
            maxMarginFeeBasisPoints, // marginFeeBasisPoints
            IVault(vault).liquidationFeeUsd(),
            IVault(vault).minProfitTime(),
            IVault(vault).hasDynamicFees()
        );
    }


    function _swap(address[] memory _path, uint256 _minOut, address _receiver) internal returns (uint256) {
        if (_path.length == 2) {
            return _vaultSwap(_path[0], _path[1], _minOut, _receiver);
        }
        revert("invalid _path.length");
    }

    function _vaultSwap(address _tokenIn, address _tokenOut, uint256 _minOut, address _receiver) internal returns (uint256) {
        uint256 amountOut = IVault(vault).swap(_tokenIn, _tokenOut, _receiver);
        require(amountOut >= _minOut, "insufficient amountOut");
        return amountOut;
    }

    function _transferInETH() internal {
        if (msg.value != 0) {
            IWETH(weth).deposit{value: msg.value}();
        }
    }

    function _transferOutETHWithGasLimitFallbackToWeth(uint256 _amountOut, address payable _receiver) internal {
        // WETH를 ETH로 변환
        IWETH _weth = IWETH(weth);
        _weth.withdraw(_amountOut);

        // receiver에게 ETH 보내기
        (bool success, /* bytes memory data */) = _receiver.call{ value: _amountOut, gas: ethTransferGasLimit }("");
        // 보내기에 성공했다면 종료
        if (success) { return; }
        // 전송에 실패했다면 WETH로 보내주기
        _weth.deposit{ value: _amountOut }();
        _weth.transfer(address(_receiver), _amountOut);
    }

    function _collectFees(
        address _account,
        address[] memory _path,
        uint256 _amountIn,
        address _indexToken,
        bool _isLong,
        uint256 _sizeDelta
    ) internal returns (uint256) {
        // 레버리지 거래에서 수수료를 부과할지 여부 체크
        bool shouldDeductFee = _shouldDeductFee(
            _account,
            _path,
            _amountIn,
            _indexToken,
            _isLong,
            _sizeDelta,
            increasePositionBufferBps
        );

        // 수수료를 부과해야한다면
        if (shouldDeductFee) {
            // deposit fee를 제외한 넣은 양
            uint256 afterFeeAmount = _amountIn * (BASIS_POINTS_DIVISOR - depositFee) / BASIS_POINTS_DIVISOR;
            uint256 feeAmount = _amountIn - afterFeeAmount;
            // C 토큰 주소
            address feeToken = _path[_path.length - 1];
            // 수수료 풀에 deposit fee만큼 추가
            feeReserves[feeToken] = feeReserves[feeToken] + feeAmount;
            // deposit fee를 제외한 넣은 양 리턴
            return afterFeeAmount;
        }

        return _amountIn;
    }

    function _shouldDeductFee(
        address _account,
        address[] memory _path,
        uint256 _amountIn,
        address _indexToken,
        bool _isLong,
        uint256 _sizeDelta,
        uint256 _increasePositionBufferBps
    ) internal returns (bool) {
        // short 포지션이라면 수수료 부과 x
        if (!_isLong) { return false; }

        // 포지션 크기가 커지지않는 경우 수수료 부과 o
        if (_sizeDelta == 0) { return true; }

        // A -> B -> C 과정의 마지막 C가 담보로 사용될 토큰
        address collateralToken = _path[_path.length - 1];

        // 포지션 데이터 가져오기
        (uint256 size, uint256 collateral, , , , , , ) = IVault(vault).getPosition(_account, collateralToken, _indexToken, _isLong);

        // 포지션 크기가 0이라면 수수료 부과 x
        if (size == 0) { return false; }

        // 크기 변화량을 추가하여 다음 크기 계산
        uint256 nextSize = size + _sizeDelta;
        // 담보로 사용될 토큰이 추가될 경우 담보 변화량 계산
        uint256 collateralDelta = IVault(vault).tokenToUsdMin(collateralToken, _amountIn);
        // 담보 변화량을 추가한 다음 담보 계산
        uint256 nextCollateral = collateral + collateralDelta;

        // 이전 레버리지(크기 / 담보)
        uint256 prevLeverage = size * BASIS_POINTS_DIVISOR / collateral;
        // allow for a maximum of a increasePositionBufferBps decrease since there might be some swap fees taken from the collateral
        // 이후 레버리지 (다음 크기 + increasePositionBufferBps / 다음 담보)
        // increasePositionBufferBps는 사용자가 포지션을 증가시키려고 할 때, 시장 변동성이나 스왑 수수료 등으로 인해 레버리지가 예상보다 약간 더 낮아질 경우
        // 수수료를 면제해주기 위한 Basis point
        uint256 nextLeverage = nextSize * (BASIS_POINTS_DIVISOR + _increasePositionBufferBps) / nextCollateral;

        emit LeverageDecreased(collateralDelta, prevLeverage, nextLeverage);

        // _increasePositionBufferBps로 변동성에 의한 수수료 먼제
        return nextLeverage < prevLeverage;
    }
}