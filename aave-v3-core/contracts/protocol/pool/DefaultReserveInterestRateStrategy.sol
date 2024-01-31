// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {IERC20} from '../../dependencies/openzeppelin/contracts/IERC20.sol';
import {WadRayMath} from '../libraries/math/WadRayMath.sol';
import {PercentageMath} from '../libraries/math/PercentageMath.sol';
import {DataTypes} from '../libraries/types/DataTypes.sol';
import {Errors} from '../libraries/helpers/Errors.sol';
import {IDefaultInterestRateStrategy} from '../../interfaces/IDefaultInterestRateStrategy.sol';
import {IReserveInterestRateStrategy} from '../../interfaces/IReserveInterestRateStrategy.sol';
import {IPoolAddressesProvider} from '../../interfaces/IPoolAddressesProvider.sol';

/**
 * @title DefaultReserveInterestRateStrategy contract
 * @author Aave
 * @notice Implements the calculation of the interest rates depending on the reserve state
 * @dev The model of interest rate is based on 2 slopes, one before the `OPTIMAL_USAGE_RATIO`
 * point of usage and another from that one to 100%.
 * - An instance of this same contract, can't be used across different Aave markets, due to the caching
 *   of the PoolAddressesProvider
 */
contract DefaultReserveInterestRateStrategy is IDefaultInterestRateStrategy {
  using WadRayMath for uint256;
  using PercentageMath for uint256;

  /// @inheritdoc IDefaultInterestRateStrategy
  uint256 public immutable OPTIMAL_USAGE_RATIO;

  /// @inheritdoc IDefaultInterestRateStrategy
  uint256 public immutable OPTIMAL_STABLE_TO_TOTAL_DEBT_RATIO;

  /// @inheritdoc IDefaultInterestRateStrategy
  uint256 public immutable MAX_EXCESS_USAGE_RATIO;

  /// @inheritdoc IDefaultInterestRateStrategy
  uint256 public immutable MAX_EXCESS_STABLE_TO_TOTAL_DEBT_RATIO;

  IPoolAddressesProvider public immutable ADDRESSES_PROVIDER;

  // Base variable borrow rate when usage rate = 0. Expressed in ray
  uint256 internal immutable _baseVariableBorrowRate;

  // Slope of the variable interest curve when usage ratio > 0 and <= OPTIMAL_USAGE_RATIO. Expressed in ray
  uint256 internal immutable _variableRateSlope1;

  // Slope of the variable interest curve when usage ratio > OPTIMAL_USAGE_RATIO. Expressed in ray
  uint256 internal immutable _variableRateSlope2;

  // Slope of the stable interest curve when usage ratio > 0 and <= OPTIMAL_USAGE_RATIO. Expressed in ray
  uint256 internal immutable _stableRateSlope1;

  // Slope of the stable interest curve when usage ratio > OPTIMAL_USAGE_RATIO. Expressed in ray
  uint256 internal immutable _stableRateSlope2;

  // Premium on top of `_variableRateSlope1` for base stable borrowing rate
  uint256 internal immutable _baseStableRateOffset;

  // Additional premium applied to stable rate when stable debt surpass `OPTIMAL_STABLE_TO_TOTAL_DEBT_RATIO`
  uint256 internal immutable _stableRateExcessOffset;

  /**
   * @dev Constructor.
   * @param provider The address of the PoolAddressesProvider contract
   * @param optimalUsageRatio The optimal usage ratio
   * @param baseVariableBorrowRate The base variable borrow rate
   * @param variableRateSlope1 The variable rate slope below optimal usage ratio
   * @param variableRateSlope2 The variable rate slope above optimal usage ratio
   * @param stableRateSlope1 The stable rate slope below optimal usage ratio
   * @param stableRateSlope2 The stable rate slope above optimal usage ratio
   * @param baseStableRateOffset The premium on top of variable rate for base stable borrowing rate
   * @param stableRateExcessOffset The premium on top of stable rate when there stable debt surpass the threshold
   * @param optimalStableToTotalDebtRatio The optimal stable debt to total debt ratio of the reserve
   */
  constructor(
    IPoolAddressesProvider provider,
    uint256 optimalUsageRatio,
    uint256 baseVariableBorrowRate,
    uint256 variableRateSlope1,
    uint256 variableRateSlope2,
    uint256 stableRateSlope1,
    uint256 stableRateSlope2,
    uint256 baseStableRateOffset,
    uint256 stableRateExcessOffset,
    uint256 optimalStableToTotalDebtRatio
  ) {
    require(WadRayMath.RAY >= optimalUsageRatio, Errors.INVALID_OPTIMAL_USAGE_RATIO);
    require(
      WadRayMath.RAY >= optimalStableToTotalDebtRatio,
      Errors.INVALID_OPTIMAL_STABLE_TO_TOTAL_DEBT_RATIO
    );
    OPTIMAL_USAGE_RATIO = optimalUsageRatio;
    MAX_EXCESS_USAGE_RATIO = WadRayMath.RAY - optimalUsageRatio;
    OPTIMAL_STABLE_TO_TOTAL_DEBT_RATIO = optimalStableToTotalDebtRatio;
    MAX_EXCESS_STABLE_TO_TOTAL_DEBT_RATIO = WadRayMath.RAY - optimalStableToTotalDebtRatio;
    ADDRESSES_PROVIDER = provider;
    _baseVariableBorrowRate = baseVariableBorrowRate;
    _variableRateSlope1 = variableRateSlope1;
    _variableRateSlope2 = variableRateSlope2;
    _stableRateSlope1 = stableRateSlope1;
    _stableRateSlope2 = stableRateSlope2;
    _baseStableRateOffset = baseStableRateOffset;
    _stableRateExcessOffset = stableRateExcessOffset;
  }

  /// @inheritdoc IDefaultInterestRateStrategy
  function getVariableRateSlope1() external view returns (uint256) {
    return _variableRateSlope1;
  }

  /// @inheritdoc IDefaultInterestRateStrategy
  function getVariableRateSlope2() external view returns (uint256) {
    return _variableRateSlope2;
  }

  /// @inheritdoc IDefaultInterestRateStrategy
  function getStableRateSlope1() external view returns (uint256) {
    return _stableRateSlope1;
  }

  /// @inheritdoc IDefaultInterestRateStrategy
  function getStableRateSlope2() external view returns (uint256) {
    return _stableRateSlope2;
  }

  /// @inheritdoc IDefaultInterestRateStrategy
  function getStableRateExcessOffset() external view returns (uint256) {
    return _stableRateExcessOffset;
  }

  /// @inheritdoc IDefaultInterestRateStrategy
  function getBaseStableBorrowRate() public view returns (uint256) {
    return _variableRateSlope1 + _baseStableRateOffset;
  }

  /// @inheritdoc IDefaultInterestRateStrategy
  function getBaseVariableBorrowRate() external view override returns (uint256) {
    return _baseVariableBorrowRate;
  }

  /// @inheritdoc IDefaultInterestRateStrategy
  function getMaxVariableBorrowRate() external view override returns (uint256) {
    return _baseVariableBorrowRate + _variableRateSlope1 + _variableRateSlope2;
  }

  struct CalcInterestRatesLocalVars {
    uint256 availableLiquidity;
    uint256 totalDebt;
    uint256 currentVariableBorrowRate;
    uint256 currentStableBorrowRate;
    uint256 currentLiquidityRate;
    uint256 borrowUsageRatio;
    uint256 supplyUsageRatio;
    uint256 stableToTotalDebtRatio;
    uint256 availableLiquidityPlusDebt;
  }

  /// @inheritdoc IReserveInterestRateStrategy
  function calculateInterestRates(
    DataTypes.CalculateInterestRatesParams memory params
  ) public view override returns (uint256, uint256, uint256) {
    CalcInterestRatesLocalVars memory vars;

    // 총 빚 = 고정 빚 + 변동 빚
    vars.totalDebt = params.totalStableDebt + params.totalVariableDebt;

    vars.currentLiquidityRate = 0;
    // 현재 변동 borrow율 
    vars.currentVariableBorrowRate = _baseVariableBorrowRate;
    // 현재 고정 borrow율
    vars.currentStableBorrowRate = getBaseStableBorrowRate();

    // 빚이 전혀 없는게 아니라면
    if (vars.totalDebt != 0) {
      // (고정 / 전체) 빚 비율 = 총 고정빚 / 총 빚
      vars.stableToTotalDebtRatio = params.totalStableDebt.rayDiv(vars.totalDebt);
      vars.availableLiquidity =
        // reserve에 들어있는 AToken + 추가된 유동성 - 사용된 유동성 
        IERC20(params.reserve).balanceOf(params.aToken) +
        params.liquidityAdded -
        params.liquidityTaken;

      // 사용가능한 유동성 + 총 빚
      vars.availableLiquidityPlusDebt = vars.availableLiquidity + vars.totalDebt;
      // 이용률(80%까지 stable) = 전체 빚 / (사용가능 유동성 + 총 빚)
      vars.borrowUsageRatio = vars.totalDebt.rayDiv(vars.availableLiquidityPlusDebt);
      // 총 빚 / (사용가능한 유동성 + 총 빚 + 담보없이 생성된 토큰)
      vars.supplyUsageRatio = vars.totalDebt.rayDiv(
        vars.availableLiquidityPlusDebt + params.unbacked
      );
    }

    // 최적 사용 비율(OPTIMAL_USAGE_RATIO)을 초과하는 경우, 이자율 증가
    // 높은 이용률에 대한 위험을 반영
    // 80% 이상이 되면 이자가 증가하는 형태
    if (vars.borrowUsageRatio > OPTIMAL_USAGE_RATIO) {
      // 이용률이 80%에서 어느정도 넘었는지 / 20%(과다 이용 범위) 
      uint256 excessBorrowUsageRatio = (vars.borrowUsageRatio - OPTIMAL_USAGE_RATIO).rayDiv(
        MAX_EXCESS_USAGE_RATIO
      );

      // 현재 고정 borrow율에 (안정 이용률 수수료 기울기 + 과다 이용률 수수료 기울기 * 과다 이용 비율) 더하기
      vars.currentStableBorrowRate +=
        _stableRateSlope1 +
        _stableRateSlope2.rayMul(excessBorrowUsageRatio);

      // 현재 변동 borrow율에 (안정 이용률 수수료 기울기 + 과다 이용률 수수료 기울기 * 과다 이용 비율) 더하기
      vars.currentVariableBorrowRate +=
        _variableRateSlope1 +
        _variableRateSlope2.rayMul(excessBorrowUsageRatio);
    } else {
      // 안정 이용률일 경우
      // 현재 고정 borrow율에 (안정 이용률 수수료 기울기 * 현재 이용률 / 80%(안정 이용 범위)) 더하기
      // 현재 이용률 / 80%(안정 이용 범위)로 비율 계산
      vars.currentStableBorrowRate += _stableRateSlope1.rayMul(vars.borrowUsageRatio).rayDiv(
        OPTIMAL_USAGE_RATIO
      );

      // 현재 변동 borrow율에 (안정 이용률 수수료 기울기 * 현재 이용률 / 80%(안정 이용 범위)) 더하기
      vars.currentVariableBorrowRate += _variableRateSlope1.rayMul(vars.borrowUsageRatio).rayDiv(
        OPTIMAL_USAGE_RATIO
      );
    }

    // (고정 / 전체) 빚 비율이 최적 (고정 / 전체) 빚 비율 보다 크다면
    // 전체 구간에서 고정 이자율이 더 높게 설정된다
    if (vars.stableToTotalDebtRatio > OPTIMAL_STABLE_TO_TOTAL_DEBT_RATIO) {
      // 초과한 고정 빚 비율 += 초과한 차이를 이용한 비율
      uint256 excessStableDebtRatio = (vars.stableToTotalDebtRatio -
        OPTIMAL_STABLE_TO_TOTAL_DEBT_RATIO).rayDiv(MAX_EXCESS_STABLE_TO_TOTAL_DEBT_RATIO);
      // 현재 고정 borrow율에 (offset * 비율) 더하기
      vars.currentStableBorrowRate += _stableRateExcessOffset.rayMul(excessStableDebtRatio);
    }

    // 예치된 자산에 대한 이자율
    vars.currentLiquidityRate = _getOverallBorrowRate(
      params.totalStableDebt,
      params.totalVariableDebt,
      vars.currentVariableBorrowRate,
      params.averageStableBorrowRate
    ).rayMul(vars.supplyUsageRatio).percentMul(
        PercentageMath.PERCENTAGE_FACTOR - params.reserveFactor
      );

    return (
      vars.currentLiquidityRate,
      vars.currentStableBorrowRate,
      vars.currentVariableBorrowRate
    );
  }

  /**
   * @dev Calculates the overall borrow rate as the weighted average between the total variable debt and total stable
   * debt
   * @param totalStableDebt The total borrowed from the reserve at a stable rate
   * @param totalVariableDebt The total borrowed from the reserve at a variable rate
   * @param currentVariableBorrowRate The current variable borrow rate of the reserve
   * @param currentAverageStableBorrowRate The current weighted average of all the stable rate loans
   * @return The weighted averaged borrow rate
   */
  function _getOverallBorrowRate(
    uint256 totalStableDebt,
    uint256 totalVariableDebt,
    uint256 currentVariableBorrowRate,
    uint256 currentAverageStableBorrowRate
  ) internal pure returns (uint256) {
    uint256 totalDebt = totalStableDebt + totalVariableDebt;

    if (totalDebt == 0) return 0;

    // 가중치된 변동 수수료율 = 총 변동 빚 * 현재 변동 borrow 수수료율
    uint256 weightedVariableRate = totalVariableDebt.wadToRay().rayMul(currentVariableBorrowRate);

    // 가중치된 안정 수수료율 = 총 고정 빚 * 현재 평균 고정 borrow 수수료율
    uint256 weightedStableRate = totalStableDebt.wadToRay().rayMul(currentAverageStableBorrowRate);

    // 전반적인 borrow 수수료율 = 둘의 합 / 전체 빚
    uint256 overallBorrowRate = (weightedVariableRate + weightedStableRate).rayDiv(
      totalDebt.wadToRay()
    );

    return overallBorrowRate;
  }
}
