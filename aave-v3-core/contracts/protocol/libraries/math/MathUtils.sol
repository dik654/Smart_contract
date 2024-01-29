// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {WadRayMath} from './WadRayMath.sol';

/**
 * @title MathUtils library
 * @author Aave
 * @notice Provides functions to perform linear and compounded interest calculations
 */
library MathUtils {
  using WadRayMath for uint256;

  /// @dev Ignoring leap years
  uint256 internal constant SECONDS_PER_YEAR = 365 days;

  /**
   * @dev Function to calculate the interest accumulated using a linear interest rate formula
   * @param rate The interest rate, in ray
   * @param lastUpdateTimestamp The timestamp of the last update of the interest
   * @return The interest rate linearly accumulated during the timeDelta, in ray
   */
  function calculateLinearInterest(
    uint256 rate,
    uint40 lastUpdateTimestamp
  ) internal view returns (uint256) {
    uint256 result = rate * (block.timestamp - uint256(lastUpdateTimestamp));
    // (지난 실행으로부터 얼마나 지났는지 / 365일)의 비율로 이자 계산 
    unchecked {
      result = result / SECONDS_PER_YEAR;
    }

    // 정확한 이자 계산을 위해 정밀도를 더해두기
    return WadRayMath.RAY + result;
  }

  /**
   * @dev Function to calculate the interest using a compounded interest rate formula
   * To avoid expensive exponentiation, the calculation is performed using a binomial approximation:
   *
   *  (1+x)^n = 1+n*x+[n/2*(n-1)]*x^2+[n/6*(n-1)*(n-2)*x^3...
   *
   * The approximation slightly underpays liquidity providers and undercharges borrowers, with the advantage of great
   * gas cost reductions. The whitepaper contains reference to the approximation and a table showing the margin of
   * error per different time periods
   *
   * @param rate The interest rate, in ray
   * @param lastUpdateTimestamp The timestamp of the last update of the interest
   * @return The interest rate compounded during the timeDelta, in ray
   */
  function calculateCompoundedInterest(
    uint256 rate,
    uint40 lastUpdateTimestamp,
    uint256 currentTimestamp
  ) internal pure returns (uint256) {
    //solium-disable-next-line
    uint256 exp = currentTimestamp - uint256(lastUpdateTimestamp);

    // 아직 지난 시간이 없다면
    if (exp == 0) {
      // ray 단위로 1 리턴
      return WadRayMath.RAY;
    }

    uint256 expMinusOne;
    uint256 expMinusTwo;
    uint256 basePowerTwo;
    uint256 basePowerThree;
    unchecked {
      // 지난시간 - 1
      expMinusOne = exp - 1;
      // 지난시간이 2보다 크다면 (지난시간 - 2)
      expMinusTwo = exp > 2 ? exp - 2 : 0;
      // ray단위로 초당 이자율 제곱
      basePowerTwo = rate.rayMul(rate) / (SECONDS_PER_YEAR * SECONDS_PER_YEAR);
      // ray단위로 초당 이자율 세제곱
      basePowerThree = basePowerTwo.rayMul(rate) / SECONDS_PER_YEAR;
    }

    // 지난 시간 * (지난시간 - 1) * 초당 이자율 제곱
    uint256 secondTerm = exp * expMinusOne * basePowerTwo;
    unchecked {
      // 2로 나누기
      secondTerm /= 2;
    }
    // 지난시간 * (지난시간 - 1) * (지난시간 - 2) * 초당 이자율 세제곱
    uint256 thirdTerm = exp * expMinusOne * expMinusTwo * basePowerThree;
    unchecked {
      // 6으로 나누기
      thirdTerm /= 6;
    }

    // https://math.stackexchange.com/questions/1198316/simple-vs-compound-interest-rates-and-taylor-expansion
    // 이항 급수를 이용하여 이자율 계산
    return WadRayMath.RAY + (rate * exp) / SECONDS_PER_YEAR + secondTerm + thirdTerm;
  }

  /**
   * @dev Calculates the compounded interest between the timestamp of the last update and the current block timestamp
   * @param rate The interest rate (in ray)
   * @param lastUpdateTimestamp The timestamp from which the interest accumulation needs to be calculated
   * @return The interest rate compounded between lastUpdateTimestamp and current block timestamp, in ray
   */
  function calculateCompoundedInterest(
    uint256 rate,
    uint40 lastUpdateTimestamp
  ) internal view returns (uint256) {
    return calculateCompoundedInterest(rate, lastUpdateTimestamp, block.timestamp);
  }
}
