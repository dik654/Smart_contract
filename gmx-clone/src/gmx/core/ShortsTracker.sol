// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import "../access/Governable.sol";
import "./interfaces/IShortsTracker.sol";
import "./interfaces/IVaultBase.sol";

contract ShortsTracker is Governable, IShortsTracker {
    event GlobalShortDataUpdated(address indexed token, uint256 globalShortSize, uint256 globalShortAveragePrice);

    uint256 public constant MAX_INT256 = uint256(type(int256).max);

    IVaultBase public vault;

    mapping (address => bool) public isHandler;
    mapping (bytes32 => bytes32) public data;

    mapping (address => uint256) override public globalShortAveragePrices;
    bool override public isGlobalShortDataReady;

    modifier onlyHandler() {
        require(isHandler[msg.sender], "ShortsTracker: forbidden");
        _;
    }

    constructor(address _vault) {
        vault = IVaultBase(_vault);
    }

    function setHandler(address _handler, bool _isActive) external onlyGov {
        require(_handler != address(0), "ShortsTracker: invalid _handler");
        isHandler[_handler] = _isActive;
    }

    function _setGlobalShortAveragePrice(address _token, uint256 _averagePrice) internal {
        globalShortAveragePrices[_token] = _averagePrice;
    }

    function setIsGlobalShortDataReady(bool value) override external onlyGov {
        isGlobalShortDataReady = value;
    }

    /**
     * @dev     토큰의 전역 short 평균 가격 설정 
     * @param   _account  .
     * @param   _collateralToken  .
     * @param   _indexToken  .
     * @param   _isLong  .
     * @param   _sizeDelta  .
     * @param   _markPrice  .
     * @param   _isIncrease  .
     */
    function updateGlobalShortData(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong,
        uint256 _sizeDelta,
        uint256 _markPrice,
        bool _isIncrease
    ) override external onlyHandler {
        // long 이거나 크기 변화량이 0이면 종료
        if (_isLong || _sizeDelta == 0) {
            return;
        }

        // 전역 short 데이터가 준비되지 않았다면 종료
        if (!isGlobalShortDataReady) {
            return;
        }

        // 전역 short 데이터 가져오기
        (uint256 globalShortSize, uint256 globalShortAveragePrice) = getNextGlobalShortData(
            _account,
            _collateralToken,
            _indexToken,
            _markPrice,
            _sizeDelta,
            _isIncrease
        );

        // 해당 토큰의 전역 short 평균 가격 설정
        _setGlobalShortAveragePrice(_indexToken, globalShortAveragePrice);

        emit GlobalShortDataUpdated(_indexToken, globalShortSize, globalShortAveragePrice);
    }

    function getGlobalShortDelta(address _token) public view returns (bool, uint256) {
        // vault에 저장된 전역 short 크기 가져오기
        uint256 size = vault.globalShortSizes(_token);
        // 토큰의 전역 short 평균 가격 가져오기
        uint256 averagePrice = globalShortAveragePrices[_token];
        // vault에 저장된 전역 short 크기가 0이라면 종료
        if (size == 0) { return (false, 0); }

        // vault에서 토큰의 최대 가격 가져오기
        uint256 nextPrice = vault.getMaxPrice(_token);
        // 토큰 전역 short 평균 가격과 토큰 최대 가격의 차이 계산
        uint256 priceDelta = averagePrice > nextPrice ? averagePrice - nextPrice : nextPrice - averagePrice;
        // 전역 short 변화량 = 크기 * 변화량 / short 평균 가격
        uint256 delta = size * priceDelta / averagePrice;
        // 숏에서 이득인지 체크 (다음 가격이 더 떨어진 경우)
        bool hasProfit = averagePrice > nextPrice;

        return (hasProfit, delta);
    }


    function setInitData(address[] calldata _tokens, uint256[] calldata _averagePrices) override external onlyGov {
        require(!isGlobalShortDataReady, "ShortsTracker: already migrated");

        for (uint256 i = 0; i < _tokens.length; i++) {
            globalShortAveragePrices[_tokens[i]] = _averagePrices[i];
        }
        isGlobalShortDataReady = true;
    }

    function getNextGlobalShortData(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _nextPrice,
        uint256 _sizeDelta,
        bool _isIncrease
    ) override public view returns (uint256, uint256) {
        int256 realisedPnl = getRealisedPnl(_account,_collateralToken, _indexToken, _sizeDelta, _isIncrease);
        uint256 averagePrice = globalShortAveragePrices[_indexToken];
        uint256 priceDelta = averagePrice > _nextPrice ? averagePrice - _nextPrice : _nextPrice - averagePrice;

        uint256 nextSize;
        uint256 delta;
        // avoid stack to deep
        {
            uint256 size = vault.globalShortSizes(_indexToken);
            // 전역 short 크기와 크기 변화량의 차이 계산
            nextSize = _isIncrease ? size + _sizeDelta : size - _sizeDelta;

            if (nextSize == 0) {
                return (0, 0);
            }

            if (averagePrice == 0) {
                return (nextSize, _nextPrice);
            }

            // 전역 short 변화량 = 크기 * (전역 short 평균가격과 다음 가격의 차이) / 전역 short 평균 가격
            delta = size * priceDelta / averagePrice;
        }

        uint256 nextAveragePrice = _getNextGlobalAveragePrice(
            averagePrice,
            _nextPrice,
            nextSize,
            delta,
            realisedPnl
        );

        return (nextSize, nextAveragePrice);
    }

    /**
     * @dev     실현된 손익 계산
     * @param   _account  .
     * @param   _collateralToken  .
     * @param   _indexToken  .
     * @param   _sizeDelta  .
     * @param   _isIncrease  .
     * @return  int256  .
     */
    function getRealisedPnl(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isIncrease
    ) public view returns (int256) {
        // 실현된 손익은 포지션의 크기가 감소할 때(즉, 일부 또는 전체 포지션이 청산되거나 닫힐 때) 발생하므로
        // 포지션이 증가하면 종료
        if (_isIncrease) {
            return 0;
        }
        (uint256 size, /*uint256 collateral*/, uint256 averagePrice, , , , , uint256 lastIncreasedTime) = vault.getPosition(_account, _collateralToken, _indexToken, false);

        // 손익 데이터 가져오기
        (bool hasProfit, uint256 delta) = vault.getDelta(_indexToken, size, averagePrice, false, lastIncreasedTime);
        // get the proportional change in pnl
        // 해당 변화량이 전체에서 어느정도 비율의 변화량인지 계산
        uint256 adjustedDelta = _sizeDelta * delta / size;
        // 변화량이 int 범위를 넘어가는지 체크
        require(adjustedDelta < MAX_INT256, "ShortsTracker: overflow");
        // 비율 변화량 리턴
        return hasProfit ? int256(adjustedDelta) : -int256(adjustedDelta);
    }

    function _getNextGlobalAveragePrice(
        uint256 _averagePrice,
        uint256 _nextPrice,
        uint256 _nextSize,
        uint256 _delta,
        int256 _realisedPnl
    ) public pure returns (uint256) {
        (bool hasProfit, uint256 nextDelta) = _getNextDelta(_delta, _averagePrice, _nextPrice, _realisedPnl);

        uint256 nextAveragePrice = _nextPrice
            * _nextSize
            / (hasProfit ? _nextSize - nextDelta : _nextSize + nextDelta);

        return nextAveragePrice;
    }

    function _getNextDelta(
        uint256 _delta,
        uint256 _averagePrice,
        uint256 _nextPrice,
        int256 _realisedPnl
    ) internal pure returns (bool, uint256) {
        // global delta 10000, realised pnl 1000 => new pnl 9000
        // global delta 10000, realised pnl -1000 => new pnl 11000
        // global delta -10000, realised pnl 1000 => new pnl -11000
        // global delta -10000, realised pnl -1000 => new pnl -9000
        // global delta 10000, realised pnl 11000 => new pnl -1000 (flips sign)
        // global delta -10000, realised pnl -11000 => new pnl 1000 (flips sign)

        // short에서 이득인지 확인
        bool hasProfit = _averagePrice > _nextPrice;
        // 이득이라면
        if (hasProfit) {
            // 실현된 손익이 이득인 경우
            if (_realisedPnl > 0) {
                // 실현된 손익이 현재 포지션의 미실현 손익보다 크다면
                if (uint256(_realisedPnl) > _delta) {
                    // global delta 10000, realised pnl 11000 => new pnl -1000 (flips sign)
                    // 손해이므로 delta는 손해량을 뜻함
                    _delta = uint256(_realisedPnl) - _delta;
                    hasProfit = false;
                } else {
                    // 이득량
                    // global delta 10000, realised pnl 1000 => new pnl 9000
                    _delta = _delta - uint256(_realisedPnl);
                }
            } else {
                // global delta 10000, realised pnl -1000 => new pnl 11000
                _delta = _delta + uint256(-_realisedPnl);
            }

            return (hasProfit, _delta);
        }

        // short에서 손해고
        // 실현된 손익이 이득인 경우
        if (_realisedPnl > 0) {
            // global delta -10000, realised pnl 1000 => new pnl -11000
            _delta = _delta + uint256(_realisedPnl);
        } else {
            if (uint256(-_realisedPnl) > _delta) {
                // global delta -10000, realised pnl -11000 => new pnl 1000 (flips sign)
                _delta = uint256(-_realisedPnl) - _delta;
                hasProfit = true;
            } else {
                // global delta -10000, realised pnl -1000 => new pnl -9000
                _delta = _delta - uint256(-_realisedPnl);
            }
        }
        return (hasProfit, _delta);
    }
}