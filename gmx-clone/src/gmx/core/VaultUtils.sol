// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IVaultBase.sol";
import "./interfaces/IVaultUtils.sol";

import "../access/Governable.sol";

contract VaultUtils is IVaultUtils, Governable {
    struct Position {
        uint256 size;
        uint256 collateral;
        uint256 averagePrice;
        uint256 entryFundingRate;
        uint256 reserveAmount;
        int256 realisedPnl;
        uint256 lastIncreasedTime;
    }

    IVaultBase public vault;

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant FUNDING_RATE_PRECISION = 1000000;

    constructor(address _vault) {
        vault = IVaultBase(_vault);
    }

    function updateCumulativeFundingRate(address /* _collateralToken */, address /* _indexToken */) public pure override returns (bool) {
        return true;
    }

    function validateIncreasePosition(address /* _account */, address /* _collateralToken */, address /* _indexToken */, uint256 /* _sizeDelta */, bool /* _isLong */) external override view {
        // no additional validations
    }

    function validateDecreasePosition(address /* _account */, address /* _collateralToken */, address /* _indexToken */ , uint256 /* _collateralDelta */, uint256 /* _sizeDelta */, bool /* _isLong */, address /* _receiver */) external override view {
        // no additional validations
    }

    function getPosition(address _account, address _collateralToken, address _indexToken, bool _isLong) internal view returns (Position memory) {
        IVaultBase _vault = vault;
        Position memory position;
        {
            (uint256 size, uint256 collateral, uint256 averagePrice, uint256 entryFundingRate, /* reserveAmount */, /* realisedPnl */, /* hasProfit */, uint256 lastIncreasedTime) = _vault.getPosition(_account, _collateralToken, _indexToken, _isLong);
            position.size = size;
            position.collateral = collateral;
            position.averagePrice = averagePrice;
            position.entryFundingRate = entryFundingRate;
            position.lastIncreasedTime = lastIncreasedTime;
        }
        return position;
    }

    /**
     * @dev liquidationState가 1이어야 한다
     * @param _account .
     * @param _collateralToken .
     * @param _indexToken .
     * @param _isLong .
     * @param _raise 청산 조건 불만족시 예외처리
     * @return liquidationState .
     * @return marginFees .
     */
    function validateLiquidation(address _account, address _collateralToken, address _indexToken, bool _isLong, bool _raise) public view override returns (uint256, uint256) {
        // 포지션 가져오기
        Position memory position = getPosition(_account, _collateralToken, _indexToken, _isLong);
        IVaultBase _vault = vault;

        // 이득 여부, 변화량 = 크기 * 변화량 / 저장된 가격
        (bool hasProfit, uint256 delta) = _vault.getDelta(_indexToken, position.size, position.averagePrice, _isLong, position.lastIncreasedTime);
        // margin fee = funding fee + position fee
        uint256 marginFees = getFundingFee(_account, _collateralToken, _indexToken, _isLong, position.size, position.entryFundingRate);
        marginFees = marginFees + getPositionFee(_account, _collateralToken, _indexToken, _isLong, position.size);

        // 손해이고 변화량이 담보보다 크다면
        if (!hasProfit && position.collateral < delta) {
            if (_raise) { revert("Vault: losses exceed collateral"); }
            return (1, marginFees);
        }

        uint256 remainingCollateral = position.collateral;
        // 손해라면 (담보 - 변화량)으로 남은 담보 계산
        if (!hasProfit) {
            remainingCollateral = position.collateral - delta;
        }

        // 남은 담보가 마진 수수료를 감당하지 못한다면
        if (remainingCollateral < marginFees) {
            // 엄격 모드일 경우 예외처리
            if (_raise) { revert("Vault: fees exceed collateral"); }
            // 아니라면 청산 가능 true, 남은 담보의 크기 리턴
            return (1, remainingCollateral);
        }

        // 포지션의 손실이 담보를 초과하거나, 남은 담보가 마진 요구사항을 충족시키지 못하는 경우 (강제 청산)
        // 남은 담보가 마진 수수료 + 유동성 수수료보다 작다면
        if (remainingCollateral < marginFees + _vault.liquidationFeeUsd()) {
            // 엄격 모드일 경우 예외처리
            if (_raise) { revert("Vault: liquidation fees exceed collateral"); }
            // 아니라면 청산 가능 true, 남은 담보의 크기 리턴
            return (1, marginFees);
        }

        // 포지션의 레버리지가 허용된 최대 레버리지를 초과하는 경우 (조정)
        // 남은 담보 * 레버리지가 포지션 크기보다 작다면
        if (remainingCollateral * _vault.maxLeverage() < position.size * BASIS_POINTS_DIVISOR) {
            // 엄격 모드일 경우 예외처리
            if (_raise) { revert("Vault: maxLeverage exceeded"); }
            // 아니라면 청산 가능 true, 남은 담보의 크기 리턴
            return (2, marginFees);
        }

        return (0, marginFees);
    }

    function getEntryFundingRate(address _collateralToken, address /* _indexToken */, bool /* _isLong */) public override view returns (uint256) {
        return vault.cumulativeFundingRates(_collateralToken);
    }

    function getPositionFee(address /* _account */, address /* _collateralToken */, address /* _indexToken */, bool /* _isLong */, uint256 _sizeDelta) public override view returns (uint256) {
        if (_sizeDelta == 0) { return 0; }
        // 포지션 총 크기 변화량 - 레버리지 수수료
        uint256 afterFeeUsd = _sizeDelta * (BASIS_POINTS_DIVISOR - vault.marginFeeBasisPoints()) / BASIS_POINTS_DIVISOR;
        return _sizeDelta - afterFeeUsd;
    }

    function getFundingFee(address /* _account */, address _collateralToken, address /* _indexToken */, bool /* _isLong */, uint256 _size, uint256 _entryFundingRate) public override view returns (uint256) {
        if (_size == 0) { return 0; }
        // 포지션을 열고 있는 동안 발생한 펀딩비율의 변화
        uint256 fundingRate = vault.cumulativeFundingRates(_collateralToken) - _entryFundingRate;
        if (fundingRate == 0) { return 0; }

        // 포지션 총 크기 * fundingRate
        return _size * fundingRate / FUNDING_RATE_PRECISION;
    }

    function getBuyUsdgFeeBasisPoints(address _token, uint256 _usdgAmount) public override view returns (uint256) {
        return getFeeBasisPoints(_token, _usdgAmount, vault.mintBurnFeeBasisPoints(), vault.taxBasisPoints(), true);
    }

    function getSellUsdgFeeBasisPoints(address _token, uint256 _usdgAmount) public override view returns (uint256) {
        return getFeeBasisPoints(_token, _usdgAmount, vault.mintBurnFeeBasisPoints(), vault.taxBasisPoints(), false);
    }

    function getSwapFeeBasisPoints(address _tokenIn, address _tokenOut, uint256 _usdgAmount) public override view returns (uint256) {
        bool isStableSwap = vault.stableTokens(_tokenIn) && vault.stableTokens(_tokenOut);
        uint256 baseBps = isStableSwap ? vault.stableSwapFeeBasisPoints() : vault.swapFeeBasisPoints();
        uint256 taxBps = isStableSwap ? vault.stableTaxBasisPoints() : vault.taxBasisPoints();
        uint256 feesBasisPoints0 = getFeeBasisPoints(_tokenIn, _usdgAmount, baseBps, taxBps, true);
        uint256 feesBasisPoints1 = getFeeBasisPoints(_tokenOut, _usdgAmount, baseBps, taxBps, false);
        // use the higher of the two fee basis points
        return feesBasisPoints0 > feesBasisPoints1 ? feesBasisPoints0 : feesBasisPoints1;
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

    
    /**
     * @dev     특정 토큰 수수료 계산 (목표량에 가까워지게 만들수록 감면)
     * @param   _token  .
     * @param   _usdgDelta  .
     * @param   _feeBasisPoints  .
     * @param   _taxBasisPoints  .
     * @param   _increment  .
     * @return  uint256  .
     */
    function getFeeBasisPoints(address _token, uint256 _usdgDelta, uint256 _feeBasisPoints, uint256 _taxBasisPoints, bool _increment) public override view returns (uint256) {
        // dynamic fee 설정이 꺼져있다면 기존 수수료 basis point를 그대로 사용
        if (!vault.hasDynamicFees()) { return _feeBasisPoints; }

        // 기존에 들어있던 해당 토큰의 USDG 가치 계산
        uint256 initialAmount = vault.usdgAmounts(_token);
        // 이번에 추가된 가치 더하기
        uint256 nextAmount = initialAmount + _usdgDelta;
        // 토큰이 빠지는 경우라면 ex) A -> B swap에서 B는 유저에게로 빠져나감
        if (!_increment) {
            // 추가된 가치가 기존 가치보다 크다면 0 (들어있는 가치보다 더 많이 나갈 순 없으니까)
            // 아니라면 기존 가치 - 추가된 가치(빠져나갈 가치)
            nextAmount = _usdgDelta > initialAmount ? 0 : initialAmount - _usdgDelta;
        }

        // 해당 토큰이 vault에 들어있는 총 USDG에 어느정도 중요도 비율로 가질지 프로토콜 목표치
        uint256 targetAmount = vault.getTargetUsdgAmount(_token);
        // 필요없다면 기존 수수료 basis point 사용
        if (targetAmount == 0) { return _feeBasisPoints; }

        // 들어있던 기존 목표치와 프로토콜 목표치간의 차이 계산
        uint256 initialDiff = initialAmount > targetAmount ? initialAmount - targetAmount : targetAmount - initialAmount;
        // 이번에 추가된 가치를 추가했을 경우 차이 계산
        uint256 nextDiff = nextAmount > targetAmount ? nextAmount - targetAmount : targetAmount - nextAmount;

        // 가치가 추가됐을 경우 차이가 더 작다면 (즉 목표치를 향해 다가가고 있다면)
        if (nextDiff < initialDiff) {
            // 세금 basis point * 기존 목표치 차이 / 프로토콜 목표치 만큼 기존 수수료 basis point에서 깎아줌
            uint256 rebateBps = _taxBasisPoints * initialDiff / targetAmount;
            return rebateBps > _feeBasisPoints ? 0 : _feeBasisPoints - rebateBps;
        }

        uint256 averageDiff = initialDiff + nextDiff / 2;
        if (averageDiff > targetAmount) {
            averageDiff = targetAmount;
        }
        uint256 taxBps = _taxBasisPoints * averageDiff / targetAmount;
        return _feeBasisPoints + taxBps;
    }
}
