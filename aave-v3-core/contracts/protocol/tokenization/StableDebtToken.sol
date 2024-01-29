// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {IERC20} from '../../dependencies/openzeppelin/contracts/IERC20.sol';
import {VersionedInitializable} from '../libraries/aave-upgradeability/VersionedInitializable.sol';
import {MathUtils} from '../libraries/math/MathUtils.sol';
import {WadRayMath} from '../libraries/math/WadRayMath.sol';
import {Errors} from '../libraries/helpers/Errors.sol';
import {IAaveIncentivesController} from '../../interfaces/IAaveIncentivesController.sol';
import {IInitializableDebtToken} from '../../interfaces/IInitializableDebtToken.sol';
import {IStableDebtToken} from '../../interfaces/IStableDebtToken.sol';
import {IPool} from '../../interfaces/IPool.sol';
import {EIP712Base} from './base/EIP712Base.sol';
import {DebtTokenBase} from './base/DebtTokenBase.sol';
import {IncentivizedERC20} from './base/IncentivizedERC20.sol';
import {SafeCast} from '../../dependencies/openzeppelin/contracts/SafeCast.sol';

/**
 * @title StableDebtToken
 * @author Aave
 * @notice Implements a stable debt token to track the borrowing positions of users
 * at stable rate mode
 * @dev Transfer and approve functionalities are disabled since its a non-transferable token
 */
contract StableDebtToken is DebtTokenBase, IncentivizedERC20, IStableDebtToken {
  using WadRayMath for uint256;
  using SafeCast for uint256;

  uint256 public constant DEBT_TOKEN_REVISION = 0x1;

  // Map of users address and the timestamp of their last update (userAddress => lastUpdateTimestamp)
  mapping(address => uint40) internal _timestamps;

  uint128 internal _avgStableRate;

  // Timestamp of the last update of the total supply
  uint40 internal _totalSupplyTimestamp;

  /**
   * @dev Constructor.
   * @param pool The address of the Pool contract
   */
  constructor(
    IPool pool
  ) DebtTokenBase() IncentivizedERC20(pool, 'STABLE_DEBT_TOKEN_IMPL', 'STABLE_DEBT_TOKEN_IMPL', 0) {
  }

  function initialize(
    IPool initializingPool,
    address underlyingAsset,
    IAaveIncentivesController incentivesController,
    uint8 debtTokenDecimals,
    string memory debtTokenName,
    string memory debtTokenSymbol,
    bytes calldata params
  ) external override initializer {
    require(initializingPool == POOL, Errors.POOL_ADDRESSES_DO_NOT_MATCH);
    _setName(debtTokenName);
    _setSymbol(debtTokenSymbol);
    _setDecimals(debtTokenDecimals);

    _underlyingAsset = underlyingAsset;
    _incentivesController = incentivesController;

    _domainSeparator = _calculateDomainSeparator();

    emit Initialized(
      underlyingAsset,
      address(POOL),
      address(incentivesController),
      debtTokenDecimals,
      debtTokenName,
      debtTokenSymbol,
      params
    );
  }

  /// @inheritdoc VersionedInitializable
  function getRevision() internal pure virtual override returns (uint256) {
    return DEBT_TOKEN_REVISION;
  }

  /// @inheritdoc IStableDebtToken
  function getAverageStableRate() external view virtual override returns (uint256) {
    return _avgStableRate;
  }

  /// @inheritdoc IStableDebtToken
  function getUserLastUpdated(address user) external view virtual override returns (uint40) {
    return _timestamps[user];
  }

  /// @inheritdoc IStableDebtToken
  function getUserStableRate(address user) external view virtual override returns (uint256) {
    return _userState[user].additionalData;
  }

  function balanceOf(address account) public view virtual override returns (uint256) {
    uint256 accountBalance = super.balanceOf(account);
    uint256 stableRate = _userState[account].additionalData;
    if (accountBalance == 0) {
      return 0;
    }
    // 이항급수를 이용한 이자율 계산
    uint256 cumulatedInterest = MathUtils.calculateCompoundedInterest(
      stableRate,
      _timestamps[account]
    );
    // 보유한 balance * 이자율
    return accountBalance.rayMul(cumulatedInterest);
  }

  struct MintLocalVars {
    uint256 previousSupply;
    uint256 nextSupply;
    uint256 amountInRay;
    uint256 currentStableRate;
    uint256 nextStableRate;
    uint256 currentAvgStableRate;
  }

  /**
   * @dev     고정 이자 계산용 토큰 mint
   * @param   user  .
   * @param   onBehalfOf  .
   * @param   amount  .
   * @param   rate  .
   * @return  bool  .
   * @return  uint256  .
   * @return  uint256  .
   */
  function mint(
    address user,
    address onBehalfOf,
    uint256 amount,
    uint256 rate
  ) external virtual override onlyPool returns (bool, uint256, uint256) {
    MintLocalVars memory vars;

    // 다른 유저에게 mint한다면 user가 onBehalfOf에게 approve된 민팅할 amount만큼 감소
    if (user != onBehalfOf) {
      _decreaseBorrowAllowance(onBehalfOf, user, amount);
    }

    // 민팅할 주소의 이자율 포함 balance 및 증가한 balance
    (, uint256 currentBalance, uint256 balanceIncrease) = _calculateBalanceIncrease(onBehalfOf);

    vars.previousSupply = totalSupply();
    vars.currentAvgStableRate = _avgStableRate;
    // 민팅할 양만큼 totalSupply 업데이트 
    vars.nextSupply = _totalSupply = vars.previousSupply + amount;

    // 민팅할 양을 RAY단위로 변환
    vars.amountInRay = amount.wadToRay();

    // _userState의 additionalData에 저장되어있던 기존 stable비율 가져오기 
    vars.currentStableRate = _userState[onBehalfOf].additionalData;
    // 다음 stable비율 = ((현재 stable비율 * 이자율 포함 balance) + amount * 현재 적용되고 있는 stable비율(rate)) / (이자율 포함 balance + 민팅할 amount)
    vars.nextStableRate = (vars.currentStableRate.rayMul(currentBalance.wadToRay()) +
      vars.amountInRay.rayMul(rate)).rayDiv((currentBalance + amount).wadToRay());
    // additionalData에 최신화한 stable비율 저장
    _userState[onBehalfOf].additionalData = vars.nextStableRate.toUint128();

    // totalSupply 업데이트 시간 갱신
    _totalSupplyTimestamp = _timestamps[onBehalfOf] = uint40(block.timestamp);

    // 평균 stable비율 업데이트
    vars.currentAvgStableRate = _avgStableRate = (
      // ((저장되어있던 평균 stable비율 * mint하기 전 totalSupply) + (현재 적용되고 있는 stable비율(rate) * 민팅하는 amount)) / mint이후 totalSupply
      (vars.currentAvgStableRate.rayMul(vars.previousSupply.wadToRay()) +
        rate.rayMul(vars.amountInRay)).rayDiv(vars.nextSupply.wadToRay())
    ).toUint128();

    // 민팅할 amount에 추가된 이자 더하기
    uint256 amountToMint = amount + balanceIncrease;
    // _userState에 이자가 더해진 amount 추가 
    _mint(onBehalfOf, amountToMint, vars.previousSupply);

    emit Transfer(address(0), onBehalfOf, amountToMint);
    emit Mint(
      user,
      onBehalfOf,
      amountToMint,
      currentBalance,
      balanceIncrease,
      vars.nextStableRate,
      vars.currentAvgStableRate,
      vars.nextSupply
    );

    return (currentBalance == 0, vars.nextSupply, vars.currentAvgStableRate);
  }

  /**
   * @dev     토큰을 태워 유저의 고정 이자 상환
   * @param   from  .
   * @param   amount  .
   * @return  uint256  .
   * @return  uint256  .
   */
  function burn(
    address from,
    uint256 amount
  ) external virtual override onlyPool returns (uint256, uint256) {
    // 이자가 포함된 balance 및 이자
    (, uint256 currentBalance, uint256 balanceIncrease) = _calculateBalanceIncrease(from);

    uint256 previousSupply = totalSupply();
    uint256 nextAvgStableRate = 0;
    uint256 nextSupply = 0;
    uint256 userStableRate = _userState[from].additionalData;

    // Since the total supply and each single user debt accrue separately,
    // there might be accumulation errors so that the last borrower repaying
    // might actually try to repay more than the available debt supply.
    // In this case we simply set the total supply and the avg stable rate to 0
    if (previousSupply <= amount) {
      _avgStableRate = 0;
      _totalSupply = 0;
    } else {
      // 다음 totalSupply는 burn할 amount만큼 축소
      nextSupply = _totalSupply = previousSupply - amount;
      // 이전 평균 stable비율 * burn 이전 totalSupply
      uint256 firstTerm = uint256(_avgStableRate).rayMul(previousSupply.wadToRay());
      // 전체 부채 공급 = 유저에게 적용되었던 마지막 stable비율 * 태울 amount
      uint256 secondTerm = userStableRate.rayMul(amount.wadToRay());

      // 사용자 stable 이자율 * amount가 전체 부채 공급보다 클 경우
      // 계산 오류나 유동성 부족같은 비정상적인 상황이므로
      // 다음 평균 stable 이자율을 0으로 설정하여 프로토콜 보호
      if (secondTerm >= firstTerm) {
        nextAvgStableRate = _totalSupply = _avgStableRate = 0;
      } else {
        // 전체 공급 평균 이자율이 더 크다면
        nextAvgStableRate = _avgStableRate = (
          // 다음 평균 stable 이자율을 두 값의 차이 / 다음 totalSupply로 설정
          (firstTerm - secondTerm).rayDiv(nextSupply.wadToRay())
        ).toUint128();
      }
    }

    // 만약 이자가 추가되지 않았다면 이자가 모두 상환된 상태이므로
    if (amount == currentBalance) {
      // 유저의 stable 이자율을 0으로 초기화
      _userState[from].additionalData = 0;
      // 유저의 timestamp 초기화
      _timestamps[from] = 0;
    } else {
      // 아니라면 유저의 timestamp 업데이트
      _timestamps[from] = uint40(block.timestamp);
    }
    // 어떤 상황이더라도 totalSupply timestamp는 업데이트
    _totalSupplyTimestamp = uint40(block.timestamp);

    // 이자가 상환할 양보다 크다면
    if (balanceIncrease > amount) {
      // 남은 이자만큼 추가로 빚 토큰 mint
      uint256 amountToMint = balanceIncrease - amount;
      _mint(from, amountToMint, previousSupply);
      emit Transfer(address(0), from, amountToMint);
      emit Mint(
        from,
        from,
        amountToMint,
        currentBalance,
        balanceIncrease,
        userStableRate,
        nextAvgStableRate,
        nextSupply
      );
    } else {
      // 상환할 양이 이자보다 크다면 
      uint256 amountToBurn = amount - balanceIncrease;
      // 빚 토큰에서 상환할 양만큼 burn
      _burn(from, amountToBurn, previousSupply);
      emit Transfer(from, address(0), amountToBurn);
      emit Burn(from, amountToBurn, currentBalance, balanceIncrease, nextAvgStableRate, nextSupply);
    }

    return (nextSupply, nextAvgStableRate);
  }

  /**
   * @notice Calculates the increase in balance since the last user interaction
   * @param user The address of the user for which the interest is being accumulated
   * @return 이자율 계산하기 전 유저의 balance
   * @return 이자율 계산 후 유저의 balance
   * @return 둘의 차이
   */
  function _calculateBalanceIncrease(
    address user
  ) internal view returns (uint256, uint256, uint256) {
    // 유저의 balance 가져오기
    uint256 previousPrincipalBalance = super.balanceOf(user);

    if (previousPrincipalBalance == 0) {
      return (0, 0, 0);
    }

    // 이자율 계산을 포함한 balance 가져오기
    uint256 newPrincipalBalance = balanceOf(user);

    return (
      previousPrincipalBalance,
      newPrincipalBalance,
      newPrincipalBalance - previousPrincipalBalance
    );
  }

  /// @inheritdoc IStableDebtToken
  function getSupplyData() external view override returns (uint256, uint256, uint256, uint40) {
    uint256 avgRate = _avgStableRate;
    return (super.totalSupply(), _calcTotalSupply(avgRate), avgRate, _totalSupplyTimestamp);
  }

  /// @inheritdoc IStableDebtToken
  function getTotalSupplyAndAvgRate() external view override returns (uint256, uint256) {
    uint256 avgRate = _avgStableRate;
    return (_calcTotalSupply(avgRate), avgRate);
  }

  /// @inheritdoc IERC20
  function totalSupply() public view virtual override returns (uint256) {
    return _calcTotalSupply(_avgStableRate);
  }

  /// @inheritdoc IStableDebtToken
  function getTotalSupplyLastUpdated() external view override returns (uint40) {
    return _totalSupplyTimestamp;
  }

  /// @inheritdoc IStableDebtToken
  function principalBalanceOf(address user) external view virtual override returns (uint256) {
    return super.balanceOf(user);
  }

  /// @inheritdoc IStableDebtToken
  function UNDERLYING_ASSET_ADDRESS() external view override returns (address) {
    return _underlyingAsset;
  }

  /**
   * @notice Calculates the total supply
   * @param avgRate The average rate at which the total supply increases
   * @return The debt balance of the user since the last burn/mint action
   */
  function _calcTotalSupply(uint256 avgRate) internal view returns (uint256) {
    uint256 principalSupply = super.totalSupply();

    if (principalSupply == 0) {
      return 0;
    }

    uint256 cumulatedInterest = MathUtils.calculateCompoundedInterest(
      avgRate,
      _totalSupplyTimestamp
    );

    return principalSupply.rayMul(cumulatedInterest);
  }

  /**
   * @notice Mints stable debt tokens to a user
   * @param account The account receiving the debt tokens
   * @param amount The amount being minted
   * @param oldTotalSupply The total supply before the minting event
   */
  function _mint(address account, uint256 amount, uint256 oldTotalSupply) internal {
    uint128 castAmount = amount.toUint128();
    uint128 oldAccountBalance = _userState[account].balance;
    // balance에 amount + _userState[account].balance
    _userState[account].balance = oldAccountBalance + castAmount;

    // 추가작업을 하는 컨트롤러가 있는 경우 추가작업
    if (address(_incentivesController) != address(0)) {
      _incentivesController.handleAction(account, oldTotalSupply, oldAccountBalance);
    }
  }

  /**
   * @notice Burns stable debt tokens of a user
   * @param account The user getting his debt burned
   * @param amount The amount being burned
   * @param oldTotalSupply The total supply before the burning event
   */
  function _burn(address account, uint256 amount, uint256 oldTotalSupply) internal {
    uint128 castAmount = amount.toUint128();
    uint128 oldAccountBalance = _userState[account].balance;
    _userState[account].balance = oldAccountBalance - castAmount;

    if (address(_incentivesController) != address(0)) {
      _incentivesController.handleAction(account, oldTotalSupply, oldAccountBalance);
    }
  }

  /// @inheritdoc EIP712Base
  function _EIP712BaseId() internal view override returns (string memory) {
    return name();
  }

  /**
   * @dev Being non transferrable, the debt token does not implement any of the
   * standard ERC20 functions for transfer and allowance.
   */
  function transfer(address, uint256) external virtual override returns (bool) {
    revert(Errors.OPERATION_NOT_SUPPORTED);
  }

  function allowance(address, address) external view virtual override returns (uint256) {
    revert(Errors.OPERATION_NOT_SUPPORTED);
  }

  function approve(address, uint256) external virtual override returns (bool) {
    revert(Errors.OPERATION_NOT_SUPPORTED);
  }

  function transferFrom(address, address, uint256) external virtual override returns (bool) {
    revert(Errors.OPERATION_NOT_SUPPORTED);
  }

  function increaseAllowance(address, uint256) external virtual override returns (bool) {
    revert(Errors.OPERATION_NOT_SUPPORTED);
  }

  function decreaseAllowance(address, uint256) external virtual override returns (bool) {
    revert(Errors.OPERATION_NOT_SUPPORTED);
  }
}
