// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "../libraries/utils/ReentrancyGuard.sol";
import "./interfaces/IVaultBase.sol";

contract VaultTrading is ReentrancyGuard, IVaultBase {
    IVaultBase public vaultbase;
    constructor(address _vaultbase) {
        vaultbase = IVaultBase(_vaultbase);
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _validateGasPrice() private view {
        if (vaultbase.maxGasPrice() == 0) { return; }
        vaultbase.validate(tx.gasprice <= vaultbase.maxGasPrice(), 55);
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
        vaultbase.validate(vaultbase.isLeverageEnabled(), 28);
        _validateGasPrice();
        vaultbase.validateRouter(_account);
        // long일 때는 포지션을 잡을 index 토큰을 그대로 담보로 사용하지만, short일 때는 stable coin을 담보로 설정해야한다.
        vaultbase.validateTokens(_collateralToken, _indexToken, _isLong);
        // setVaultUtils로 vaultUtils 설정이 선행되어야 실행가능하다(원본에는 validate 로직 내용은 비어있다)
        vaultbase.vaultUtils.validateIncreasePosition(_account, _collateralToken, _indexToken, _sizeDelta, _isLong);

        // interval동안 pool에 추가된 reserve 토큰 비율 업데이트
        vaultbase.updateCumulativeFundingRate(_collateralToken, _indexToken);

        // 포지션 데이터 가져오기
        bytes32 key = vaultbase.getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position memory position = vaultbase.positions(key);

        // long이라면 maxise 설정을 true로 만들어 가격을 가져오고
        // short라면 false로 만들어 가격을 가져온다
        uint256 price = _isLong ? vaultbase.getMaxPrice(_indexToken) : vaultbase.getMinPrice(_indexToken);

        // 평균 가격 최신화
        if (position.size == 0) {
            position.averagePrice = price;
        }

        // 포지션 변경시 바뀌는 평균가격 최신화
        if (position.size > 0 && _sizeDelta > 0) {
            position.averagePrice = vaultbase.getNextAveragePrice(_indexToken, position.size, position.averagePrice, _isLong, price, _sizeDelta, position.lastIncreasedTime);
        }

        // 레버리지 수수료 계산
        uint256 fee = _collectMarginFees(_account, _collateralToken, _indexToken, _isLong, _sizeDelta, position.size, position.entryFundingRate);
        // 이번 트랜잭션에 넣은 담보 토큰 개수
        uint256 collateralDelta = vaultbase.transferIn(_collateralToken);
        // 이번 트랜잭션에 넣은 담보 토큰의 가격 
        uint256 collateralDeltaUsd = vaultbase.tokenToUsdMin(_collateralToken, collateralDelta);

        // 포지션 담보에 이번 트랜잭션에 넣은 담보 토큰의 가격을 더해서 업데이트
        position.collateral += collateralDeltaUsd;
        // 포지션 담보가 레버리지 수수료를 감당할 수 있는지 확인
        vaultbase.validate(position.collateral >= fee, 29);

        // 감당 가능하다면 수수료만큼 포지션 담보에서 빼기
        position.collateral -= fee;
        // 포지션 시작 수수료 최신화 
        position.entryFundingRate = getEntryFundingRate(_collateralToken, _indexToken, _isLong);
        // 포지션의 크기 최신화
        position.size += _sizeDelta;
        // 포지션 마지막 증가 시간 최신화
        position.lastIncreasedTime = block.timestamp;

        vaultbase.validate(position.size > 0, 30);
        _validatePosition(position.size, position.collateral);
        vaultbase.validateLiquidation(_account, _collateralToken, _indexToken, _isLong, true);

        // 포지션으로 들어가는 담보 토큰은 reserve로 추가
        uint256 reserveDelta = vaultbase.usdToTokenMax(_collateralToken, _sizeDelta);
        position.reserveAmount += reserveDelta;
        vaultbase.increaseReservedAmount(_collateralToken, reserveDelta);

        // 롱이라면
        if (_isLong) {
            // 수수료는 담보에서 빠져나갔으니 (포지션 크기 - 담보)인 순수익에 fee만큼을 더해준다 (포지션의 전체 가치(size)에서 담보(collateral)를 뺀 값)
            vaultbase.increaseGuaranteedUsd(_collateralToken, _sizeDelta + fee);
            vaultbase.decreaseGuaranteedUsd(_collateralToken, collateralDeltaUsd);
            // 담보도 pool의 일부이므로 추가한다
            vaultbase.increasePoolAmount(_collateralToken, collateralDelta);
            // fee는 pool에서 빠지는 값이므로 뺴준다
            vaultbase.decreasePoolAmount(_collateralToken, vaultbase.usdToTokenMin(_collateralToken, fee));
        } else {
            // 숏이라면
            if (vaultbase.globalShortSizes(_indexToken) == 0) {
                vaultbase.globalShortAveragePrices(_indexToken) = price;
            } else {
                // 다음 숏 평균가격 저장
                vaultbase.globalShortAveragePrices[_indexToken] = vaultbase.getNextGlobalShortAveragePrice(_indexToken, price, _sizeDelta);
            }
            // 전체 숏의 크기 저장
            _increaseGlobalShortSize(_indexToken, _sizeDelta);
        }

        vaultbase.setPosition(key, position);
        emit IncreasePosition(key, _account, _collateralToken, _indexToken, collateralDeltaUsd, _sizeDelta, _isLong, price, fee);
        emit UpdatePosition(key, position.size, position.collateral, position.averagePrice, position.entryFundingRate, position.reserveAmount, position.realisedPnl, price);
    }

    function decreasePosition(address _account, address _collateralToken, address _indexToken, uint256 _collateralDelta, uint256 _sizeDelta, bool _isLong, address _receiver) external override nonReentrant returns (uint256) {
        _validateGasPrice();
        vaultbase.validateRouter(_account);
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
        vaultbase.vaultUtils().validateDecreasePosition(_account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, _receiver);
        // CumulativeFundingRate 증가시키기
        vaultbase.updateCumulativeFundingRate(_collateralToken, _indexToken);

        // 포지션 데이터 가져오기
        bytes32 key = vaultbase.getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position memory position = vaultbase.positions(key);
        vaultbase.validate(position.size > 0, 31);
        vaultbase.validate(position.size >= _sizeDelta, 32);
        vaultbase.validate(position.collateral >= _collateralDelta, 33);

        uint256 collateral = position.collateral;
        // scrop variables to avoid stack too deep errors
        {
            // 포지션 내의 reserve 감소시키기
            uint256 reserveDelta = position.reserveAmount * _sizeDelta / position.size;
            position.reserveAmount = position.reserveAmount - reserveDelta;
            vaultbase.decreaseReservedAmount(_collateralToken, reserveDelta);
        }

        // 담보 감소시키기
        (uint256 usdOut, uint256 usdOutAfterFee) = _reduceCollateral(_account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong);

        // 모두 빼는게 아니라면
        if (position.size != _sizeDelta) {
            position.entryFundingRate = getEntryFundingRate(_collateralToken, _indexToken, _isLong);
            // 전체 크기에서 빼려는 크기만큼을 빼고
            position.size = position.size - _sizeDelta;

            _validatePosition(position.size, position.collateral);
            vaultbase.validateLiquidation(_account, _collateralToken, _indexToken, _isLong, true);

            // 롱이라면
            if (_isLong) {
                // 보장 USD - 빼려는 크기 + 변화한 담보(_reduceCollateral로 position.collateral이 변화되었음)
                vaultbase.increaseGuaranteedUsd(_collateralToken, collateral - position.collateral);
                vaultbase.decreaseGuaranteedUsd(_collateralToken, _sizeDelta);
            }

            uint256 price = _isLong ? vaultbase.getMinPrice(_indexToken) : vaultbase.getMaxPrice(_indexToken);
            emit DecreasePosition(key, _account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, price, usdOut - usdOutAfterFee);
            emit UpdatePosition(key, position.size, position.collateral, position.averagePrice, position.entryFundingRate, position.reserveAmount, position.realisedPnl, price);
        } else {
            // 모두 빼는거라면
            if (_isLong) {
                // 보장 USD - 전체 크기 + 전체 담보 (포지션의 전체 가치(size)에서 담보(collateral)를 뺀 값)
                vaultbase.increaseGuaranteedUsd(_collateralToken, collateral);
                vaultbase.decreaseGuaranteedUsd(_collateralToken, _sizeDelta);
            }

            uint256 price = _isLong ? vaultbase.getMinPrice(_indexToken) : vaultbase.getMaxPrice(_indexToken);
            emit DecreasePosition(key, _account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, price, usdOut - usdOutAfterFee);
            emit ClosePosition(key, position.size, position.collateral, position.averagePrice, position.entryFundingRate, position.reserveAmount, position.realisedPnl);
            // 모두 꺼냈으니 포지션 데이터 삭제
            delete vaultbase.positions[key];
        }

        // 숏이라면 전체 숏크기에 size만큼 감소 (뺐으므로)
        if (!_isLong) {
            _decreaseGlobalShortSize(_indexToken, _sizeDelta);
        }

        if (usdOut > 0) {
            if (_isLong) {
                // 꺼내는 만큼 pool에서도 빼기
                vaultbase.decreasePoolAmount(_collateralToken, vaultbase.usdToTokenMin(_collateralToken, usdOut));
            }
            // 계산이 완료되어 수수료를 제외한 꺼낸 양만큼 receiver에게 전송
            uint256 amountOutAfterFees = vaultbase.usdToTokenMin(_collateralToken, usdOutAfterFee);
            vaultbase.transferOut(_collateralToken, amountOutAfterFees, _receiver);
            return amountOutAfterFees;
        }
        vaultbase.setPosition(key, position);
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
        if (vaultbase.inPrivateLiquidationMode()) {
            vaultbase.validate(vaultbase.isLiquidator(msg.sender), 34);
        }

        // set includeAmmPrice to false to prevent manipulated liquidations
        vaultbase.setIncludeAmmPrice(false);

        // reserve / amount 최신화
        vaultbase.updateCumulativeFundingRate(_collateralToken, _indexToken);

        // 포지션 데이터 가져오기
        bytes32 key = vaultbase.getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position memory position = vaultbase.positions[key];
        vaultbase.validate(position.size > 0, 35);

        // 유효한 유동성 상태인지 체크
        (uint256 liquidationState, uint256 marginFees) = vaultbase.validateLiquidation(_account, _collateralToken, _indexToken, _isLong, false);
        vaultbase.validate(liquidationState != 0, 36);
        if (liquidationState == 2) {
            // 담보변화량은 0으로 두고 size를 변화시켜서 레버리지 범위를 변경한다
            _decreasePosition(_account, _collateralToken, _indexToken, 0, position.size, _isLong, _account);
            vaultbase.setIncludeAmmPrice(true);
            return;
        }

        // 마진 수수료의 usd 가치만큼 feeReserves에 추가 
        uint256 feeTokens = vaultbase.usdToTokenMin(_collateralToken, marginFees);
        vaultbase.feeReserves(_collateralToken) = vaultbase.feeReserves(_collateralToken) + feeTokens;
        emit CollectMarginFees(_collateralToken, marginFees, feeTokens);

        // reserve pool에서 reserve amount만큼 빼기
        vaultbase.decreaseReservedAmount(_collateralToken, position.reserveAmount);
        if (_isLong) {
            // guaranteedUsd에서 (크기 - 담보)만큼 빼기
            vaultbase.decreaseGuaranteedUsd(_collateralToken, position.size - position.collateral);
            // pool에서 usd 가치만큼 빼기
            vaultbase.decreasePoolAmount(_collateralToken, vaultbase.usdToTokenMin(_collateralToken, marginFees));
        }

        uint256 markPrice = _isLong ? vaultbase.getMinPrice(_indexToken) : vaultbase.getMaxPrice(_indexToken);
        emit LiquidatePosition(key, _account, _collateralToken, _indexToken, _isLong, position.size, position.collateral, position.reserveAmount, position.realisedPnl, markPrice);

        // 숏이고 담보가 마진 수수료를 감당할 수 있다면
        if (!_isLong && marginFees < position.collateral) {
            // 수수료를 제외한 남은 담보만큼 pool에 증가시키기
            uint256 remainingCollateral = position.collateral - marginFees;
            vaultbase.increasePoolAmount(_collateralToken, vaultbase.usdToTokenMin(_collateralToken, remainingCollateral));
        }

        // 숏이라면
        if (!_isLong) {
            // 전체 숏 크기 증가
            _decreaseGlobalShortSize(_indexToken, position.size);
        }

        // 포지션 정보 삭제
        vaultbase.deletePosition(key);

        // 청산 실행자에게 청산 수수료를 전달
        vaultbase.decreasePoolAmount(_collateralToken, vaultbase.usdToTokenMin(_collateralToken, vaultbase.liquidationFeeUsd()));
        vaultbase.transferOut(_collateralToken, vaultbase.usdToTokenMin(_collateralToken, vaultbase.liquidationFeeUsd()), _feeReceiver);

        vaultbase.setIncludeAmmPrice(true);
    }

    function _reduceCollateral(address _account, address _collateralToken, address _indexToken, uint256 _collateralDelta, uint256 _sizeDelta, bool _isLong) private returns (uint256, uint256) {
        bytes32 key = vaultbase.getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position storage position = vaultbase.positions(key);

        uint256 fee = _collectMarginFees(_account, _collateralToken, _indexToken, _isLong, _sizeDelta, position.size, position.entryFundingRate);
        bool hasProfit;
        uint256 adjustedDelta;

        // scope variables to avoid stack too deep errors
        {
        (bool _hasProfit, uint256 delta) = vaultbase.getDelta(_indexToken, position.size, position.averagePrice, _isLong, position.lastIncreasedTime);
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
                uint256 tokenAmount = vaultbase.usdToTokenMin(_collateralToken, adjustedDelta);
                vaultbase.decreasePoolAmount(_collateralToken, tokenAmount);
            }
        }

        if (!hasProfit && adjustedDelta > 0) {
            position.collateral = position.collateral - adjustedDelta;

            // transfer realised losses to the pool for short positions
            // realised losses for long positions are not transferred here as
            // _increasePoolAmount was already called in increasePosition for longs
            if (!_isLong) {
                uint256 tokenAmount = vaultbase.usdToTokenMin(_collateralToken, adjustedDelta);
                vaultbase.increasePoolAmount(_collateralToken, tokenAmount);
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
                uint256 feeTokens = vaultbase.usdToTokenMin(_collateralToken, fee);
                vaultbase.decreasePoolAmount(_collateralToken, feeTokens);
            }
        }

        emit UpdatePnl(key, hasProfit, adjustedDelta);
        return (usdOut, usdOutAfterFee);
    }

    function _collectMarginFees(address _account, address _collateralToken, address _indexToken, bool _isLong, uint256 _sizeDelta, uint256 _size, uint256 _entryFundingRate) private returns (uint256) {
        uint256 feeUsd = getPositionFee(_account, _collateralToken, _indexToken, _isLong, _sizeDelta);

        // 포지션 총 크기 * fundingRate
        uint256 fundingFee = getFundingFee(_account, _collateralToken, _indexToken, _isLong, _size, _entryFundingRate);
        feeUsd = feeUsd + fundingFee;

        uint256 feeTokens = vaultbase.usdToTokenMin(_collateralToken, feeUsd);
        vaultbase.increaseFeeReserves(_collateralToken, feeTokens);

        emit CollectMarginFees(_collateralToken, feeUsd, feeTokens);
        return feeUsd;
    }

    function _increaseGlobalShortSize(address _token, uint256 _amount) internal {
        vaultbase.increaseGlobalShortSize(_token, _amount);

        uint256 maxSize = vaultbase.maxGlobalShortSizes(_token);
        if (maxSize != 0) {
            require(vaultbase.globalShortSizes(_token) <= maxSize, "Vault: max shorts exceeded");
        }
    }

    function _decreaseGlobalShortSize(address _token, uint256 _amount) private {
        uint256 size = vaultbase.globalShortSizes(_token);

        if (_amount > size) {
          vaultbase.globalShortSizes(_token) = 0;
          return;
        }

        vaultbase.decreaseGlobalShortSize(_token, _amount);
    }

    function getFundingFee(address _account, address _collateralToken, address _indexToken, bool _isLong, uint256 _size, uint256 _entryFundingRate) public view returns (uint256) {
        return vaultbase.vaultUtils().getFundingFee(_account, _collateralToken, _indexToken, _isLong, _size, _entryFundingRate);
    }

    function getPositionFee(address _account, address _collateralToken, address _indexToken, bool _isLong, uint256 _sizeDelta) public view returns (uint256) {
        return vaultbase.vaultUtils().getPositionFee(_account, _collateralToken, _indexToken, _isLong, _sizeDelta);
    }

    function getEntryFundingRate(address _collateralToken, address _indexToken, bool _isLong) public view returns (uint256) {
        return vaultbase.vaultUtils().getEntryFundingRate(_collateralToken, _indexToken, _isLong);
    }

    function _validatePosition(uint256 _size, uint256 _collateral) private view {
        if (_size == 0) {
            vaultbase.validate(_collateral == 0, 39);
            return;
        }
        vaultbase.validate(_size >= _collateral, 40);
    }
}