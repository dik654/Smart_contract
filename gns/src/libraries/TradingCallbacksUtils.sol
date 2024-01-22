// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "../interfaces/IGNSTradingStorage.sol";
import "../interfaces/IGNSPairInfos.sol";
import "../interfaces/IGNSBorrowingFees.sol";
import "../interfaces/IGNSTradingCallbacks.sol";
import "../interfaces/IGNSPairsStorage.sol";

/**
 * @custom:version 6.4.3
 *
 * @dev This is a library with methods used by GNSTradingCallbacks contract.
 */
library TradingCallbacksUtils {
    uint256 private constant PRECISION = 1e10; // 10 decimals
    uint256 private constant MAX_SL_P = 75; // -75% PNL
    uint256 private constant MAX_GAIN_P = 900; // 900% PnL (10x)

    /**
     * @dev Returns trade value and borrowing fee.
     */
    function getTradeValue(
        IGNSTradingStorage.Trade memory _trade,
        uint256 _currentDaiPos, // 1e18
        int256 _percentProfit, // PRECISION
        uint256 _closingFees, // 1e18
        IGNSBorrowingFees _borrowingFees,
        IGNSPairInfos _pairInfos
    ) external returns (uint256 value, uint256 borrowingFee) {
        int256 netProfitP;

        (netProfitP, borrowingFee) = getBorrowingFeeAdjustedPercentProfit(
            _trade,
            _currentDaiPos,
            _percentProfit,
            _borrowingFees
        );

        value = _pairInfos.getTradeValue(
            _trade.trader,
            _trade.pairIndex,
            _trade.index,
            _trade.buy,
            _currentDaiPos,
            _trade.leverage,
            netProfitP,
            _closingFees
        );
    }

    /**
     * @dev Returns borrowing fee and adjusted percent profit for a trade.
     */
    function getBorrowingFeeAdjustedPercentProfit(
        IGNSTradingStorage.Trade memory _trade,
        uint256 _currentDaiPos, // 1e18
        int256 _percentProfit, // PRECISION
        IGNSBorrowingFees _borrowingFees
    ) public view returns (int256 netProfitP, uint256 borrowingFee) {
        borrowingFee = _borrowingFees.getTradeBorrowingFee(
            IGNSBorrowingFees.BorrowingFeeInput(
                _trade.trader,
                _trade.pairIndex,
                _trade.index,
                _trade.buy,
                _currentDaiPos,
                _trade.leverage
            )
        );

        netProfitP = _percentProfit - int256((borrowingFee * 100 * PRECISION) / _currentDaiPos);
    }

    /**
     * @dev Checks if '_leverage' is not higher than maximum allowed leverage for a pair
     */
    function withinMaxLeverage(
        uint256 _pairIndex,
        uint256 _leverage,
        uint256 _pairMaxLeverage,
        IGNSPairsStorage _pairsStorage
    ) public view returns (bool) {
        return
            _pairMaxLeverage == 0
                ? _leverage <= _pairsStorage.pairMaxLeverage(_pairIndex)
                : _leverage <= _pairMaxLeverage;
    }

    /**
     * @dev Checks if total position size is not higher than maximum allowed open interest for a pair
     */
    function withinExposureLimits(
        uint256 _pairIndex,
        bool _long,
        uint256 _positionSizeDai,
        uint256 _leverage,
        IGNSTradingStorage _storageT,
        IGNSBorrowingFees _borrowingFees
    ) public view returns (bool) {
        uint256 levPositionSizeDai = _positionSizeDai * _leverage;

        return
            _storageT.openInterestDai(_pairIndex, _long ? 0 : 1) + levPositionSizeDai <=
            _borrowingFees.getPairMaxOi(_pairIndex) * 1e8 &&
            _borrowingFees.withinMaxGroupOi(_pairIndex, _long, levPositionSizeDai);
    }

    /**
     * @dev Calculates percent profit for long/short based on '_openPrice', '_currentPrice', '_leverage'.
     */
    function currentPercentProfit(
        uint256 _openPrice,
        uint256 _currentPrice,
        bool _long,
        uint256 _leverage
    ) public pure returns (int256 p) {
        int256 maxPnlP = int256(MAX_GAIN_P) * int256(PRECISION);

        p = _openPrice > 0
            ? ((_long ? int256(_currentPrice) - int256(_openPrice) : int256(_openPrice) - int256(_currentPrice)) *
                100 *
                int256(PRECISION) *
                int256(_leverage)) / int256(_openPrice)
            : int256(0);

        p = p > maxPnlP ? maxPnlP : p;
    }

    /**
     * @dev Corrects take profit price for long/short based on '_openPrice', '_tp, '_leverage'.
     */
    function correctTp(uint256 _openPrice, uint256 _leverage, uint256 _tp, bool _long) public pure returns (uint256) {
        if (
            _tp == 0 ||
            currentPercentProfit(_openPrice, _tp, _long, _leverage) == int256(MAX_GAIN_P) * int256(PRECISION)
        ) {
            uint256 tpDiff = (_openPrice * MAX_GAIN_P) / _leverage / 100;
            return _long ? _openPrice + tpDiff : (tpDiff <= _openPrice ? _openPrice - tpDiff : 0);
        }

        return _tp;
    }

    /**
     * @dev Corrects stop loss price for long/short based on '_openPrice', '_sl, '_leverage'.
     */
    function correctSl(uint256 _openPrice, uint256 _leverage, uint256 _sl, bool _long) public pure returns (uint256) {
        if (
            _sl > 0 &&
            currentPercentProfit(_openPrice, _sl, _long, _leverage) < int256(MAX_SL_P) * int256(PRECISION) * -1
        ) {
            uint256 slDiff = (_openPrice * MAX_SL_P) / _leverage / 100;
            return _long ? _openPrice - slDiff : _openPrice + slDiff;
        }

        return _sl;
    }

    /**
     * @dev Corrects '_trade' stop loss and take profit prices and returns the modified object
     */
    function handleTradeSlTp(IGNSTradingStorage.Trade memory _trade) external pure returns (uint256, uint256) {
        _trade.tp = correctTp(_trade.openPrice, _trade.leverage, _trade.tp, _trade.buy);
        _trade.sl = correctSl(_trade.openPrice, _trade.leverage, _trade.sl, _trade.buy);

        return (_trade.tp, _trade.sl);
    }

    /**
     * @dev Calculates market execution price based on '_price', '_spreadP' for short/long positions.
     */
    function marketExecutionPrice(uint256 _price, uint256 _spreadP, bool _long) public pure returns (uint256) {
        uint256 priceDiff = (_price * _spreadP) / 100 / PRECISION;

        return _long ? _price + priceDiff : _price - priceDiff;
    }

    /**
     * @dev Makes pre-trade checks: price impact, if trade should be cancelled based on parameters like: PnL, leverage, slippage, etc.
     */
    function openTradePrep(
        IGNSTradingCallbacks.OpenTradePrepInput memory _input,
        IGNSBorrowingFees _borrowingFees,
        IGNSTradingStorage _storageT,
        IGNSPairInfos _pairInfos
    )
        external
        view
        returns (uint256 priceImpactP, uint256 priceAfterImpact, IGNSTradingCallbacks.CancelReason cancelReason)
    {
        (priceImpactP, priceAfterImpact) = _borrowingFees.getTradePriceImpact(
            marketExecutionPrice(_input.executionPrice, _input.spreadP, _input.buy),
            _input.pairIndex,
            _input.buy,
            _input.positionSize * _input.leverage
        );

        uint256 maxSlippage = _input.maxSlippageP > 0
            ? (_input.wantedPrice * _input.maxSlippageP) / 100 / PRECISION
            : _input.wantedPrice / 100; // 1% by default

        cancelReason = _input.isPaused
            ? IGNSTradingCallbacks.CancelReason.PAUSED
            : (
                _input.marketPrice == 0
                    ? IGNSTradingCallbacks.CancelReason.MARKET_CLOSED
                    : (
                        _input.buy
                            ? priceAfterImpact > _input.wantedPrice + maxSlippage
                            : priceAfterImpact < _input.wantedPrice - maxSlippage
                    )
                    ? IGNSTradingCallbacks.CancelReason.SLIPPAGE
                    : (_input.tp > 0 && (_input.buy ? priceAfterImpact >= _input.tp : priceAfterImpact <= _input.tp))
                    ? IGNSTradingCallbacks.CancelReason.TP_REACHED
                    : (_input.sl > 0 &&
                        (_input.buy ? _input.executionPrice <= _input.sl : _input.executionPrice >= _input.sl))
                    ? IGNSTradingCallbacks.CancelReason.SL_REACHED
                    : !withinExposureLimits(
                        _input.pairIndex,
                        _input.buy,
                        _input.positionSize,
                        _input.leverage,
                        _storageT,
                        _borrowingFees
                    )
                    ? IGNSTradingCallbacks.CancelReason.EXPOSURE_LIMITS
                    : priceImpactP * _input.leverage > _pairInfos.maxNegativePnlOnOpenP()
                    ? IGNSTradingCallbacks.CancelReason.PRICE_IMPACT
                    : !withinMaxLeverage(
                        _input.pairIndex,
                        _input.leverage,
                        _input.pairMaxLeverage,
                        _storageT.priceAggregator().pairsStorage()
                    )
                    ? IGNSTradingCallbacks.CancelReason.MAX_LEVERAGE
                    : IGNSTradingCallbacks.CancelReason.NONE
            );
    }
}