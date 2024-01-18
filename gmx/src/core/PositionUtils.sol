// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import "../libraries/math/SafeMath.sol";
import "../peripherals/interfaces/ITimelock.sol";

import "./interfaces/IVault.sol";
import "./interfaces/IRouter.sol";
import "./interfaces/IShortsTracker.sol";

library PositionUtils {
    using SafeMath for uint256;

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    event LeverageDecreased(uint256 collateralDelta, uint256 prevLeverage, uint256 nextLeverage);

    function shouldDeductFee(
        address _vault,
        address _account,
        address[] memory _path,
        uint256 _amountIn,
        address _indexToken,
        bool _isLong,
        uint256 _sizeDelta,
        uint256 _increasePositionBufferBps
    ) external returns (bool) {
        // short 포지션이라면 수수료 부과 x
        if (!_isLong) { return false; }

        // 포지션 크기가 커지지않는 경우 수수료 부과 o
        if (_sizeDelta == 0) { return true; }

        // A -> B -> C 과정의 마지막 C가 담보로 사용될 토큰
        address collateralToken = _path[_path.length - 1];

        // 포지션 데이터 가져오기
        IVault vault = IVault(_vault);
        (uint256 size, uint256 collateral, , , , , , ) = vault.getPosition(_account, collateralToken, _indexToken, _isLong);

        // 포지션 크기가 0이라면 수수료 부과 x
        if (size == 0) { return false; }

        // 크기 변화량을 추가하여 다음 크기 계산
        uint256 nextSize = size.add(_sizeDelta);
        // 담보로 사용될 토큰이 추가될 경우 담보 변화량 계산
        uint256 collateralDelta = vault.tokenToUsdMin(collateralToken, _amountIn);
        // 담보 변화량을 추가한 다음 담보 계산
        uint256 nextCollateral = collateral.add(collateralDelta);

        // 이전 레버리지(크기 / 담보)
        uint256 prevLeverage = size.mul(BASIS_POINTS_DIVISOR).div(collateral);
        // allow for a maximum of a increasePositionBufferBps decrease since there might be some swap fees taken from the collateral
        // 이후 레버리지 (다음 크기 + increasePositionBufferBps / 다음 담보)
        // increasePositionBufferBps는 사용자가 포지션을 증가시키려고 할 때, 시장 변동성이나 스왑 수수료 등으로 인해 레버리지가 예상보다 약간 더 낮아질 경우
        // 수수료를 면제해주기 위한 Basis point
        uint256 nextLeverage = nextSize.mul(BASIS_POINTS_DIVISOR + _increasePositionBufferBps).div(nextCollateral);

        emit LeverageDecreased(collateralDelta, prevLeverage, nextLeverage);

        // _increasePositionBufferBps로 변동성에 의한 수수료 먼제
        return nextLeverage < prevLeverage;
    }

    
    /**
     * @dev     vault의 increasePosition를 실행하도록 하는 함수  
     * @param   _vault  
     * @param   _router  
     * @param   _shortsTracker  
     * @param   _account  
     * @param   _collateralToken  
     * @param   _indexToken  
     * @param   _sizeDelta  
     * @param   _isLong  
     * @param   _price  
     */
    function increasePosition(
        address _vault,
        address _router,
        address _shortsTracker,
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _price
    ) external {
        // markPrice = 현재 최대 가격
        uint256 markPrice = _isLong ? IVault(_vault).getMaxPrice(_indexToken) : IVault(_vault).getMinPrice(_indexToken);
        // long일 때 포지션을 키우는데 목표가격이 현재 가격보다 작으면 에러
        if (_isLong) {
            require(markPrice <= _price, "markPrice > price");
        // short일 때 포지션을 키우는데 목표가격이 현재 가격보다 크면 에러 
        } else {
            require(markPrice >= _price, "markPrice < price");
        }

        // vault의 governor는 timelock 컨트랙트
        address timelock = IVault(_vault).gov();

        // TODO
        IShortsTracker(_shortsTracker).updateGlobalShortData(_account, _collateralToken, _indexToken, _isLong, _sizeDelta, markPrice, true);

        // IsLeverageEnabled 켜기
        // 주요한 목적은 maxMarginFeeBasisPoints를 marginFeeBasisPoints로 바꾸어 
        // 이 트랜잭션을 실행하는동안만 레버리지 마진 수수료율을 적용할 수 있도록 하여 
        // 레버리지 거래를 하지않는 평소에는 최대 마진 수수료율 제한이 유지되도록 한다
        ITimelock(timelock).enableLeverage(_vault);
        // 유저가 approve한 router로 실행시켰는지 체크 후 vault의 increasePosition 실행
        IRouter(_router).pluginIncreasePosition(_account, _collateralToken, _indexToken, _sizeDelta, _isLong);
        ITimelock(timelock).disableLeverage(_vault);
    }
}