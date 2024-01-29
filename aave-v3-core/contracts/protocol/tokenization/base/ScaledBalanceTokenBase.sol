// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {SafeCast} from '../../../dependencies/openzeppelin/contracts/SafeCast.sol';
import {Errors} from '../../libraries/helpers/Errors.sol';
import {WadRayMath} from '../../libraries/math/WadRayMath.sol';
import {IPool} from '../../../interfaces/IPool.sol';
import {IScaledBalanceToken} from '../../../interfaces/IScaledBalanceToken.sol';
import {MintableIncentivizedERC20} from './MintableIncentivizedERC20.sol';

/**
 * @title ScaledBalanceTokenBase
 * @author Aave
 * @notice Basic ERC20 implementation of scaled balance token
 */
abstract contract ScaledBalanceTokenBase is MintableIncentivizedERC20, IScaledBalanceToken {
  using WadRayMath for uint256;
  using SafeCast for uint256;

  /**
   * @dev Constructor.
   * @param pool The reference to the main Pool contract
   * @param name The name of the token
   * @param symbol The symbol of the token
   * @param decimals The number of decimals of the token
   */
  constructor(
    IPool pool,
    string memory name,
    string memory symbol,
    uint8 decimals
  ) MintableIncentivizedERC20(pool, name, symbol, decimals) {
    // Intentionally left blank
  }

  /// @inheritdoc IScaledBalanceToken
  function scaledBalanceOf(address user) external view override returns (uint256) {
    return super.balanceOf(user);
  }

  /// @inheritdoc IScaledBalanceToken
  function getScaledUserBalanceAndSupply(
    address user
  ) external view override returns (uint256, uint256) {
    return (super.balanceOf(user), super.totalSupply());
  }

  /// @inheritdoc IScaledBalanceToken
  function scaledTotalSupply() public view virtual override returns (uint256) {
    return super.totalSupply();
  }

  /// @inheritdoc IScaledBalanceToken
  function getPreviousIndex(address user) external view virtual override returns (uint256) {
    return _userState[user].additionalData;
  }

  /**
   * @notice Implements the basic logic to mint a scaled balance token.
   * @param caller The address performing the mint
   * @param onBehalfOf The address of the user that will receive the scaled tokens
   * @param amount The amount of tokens getting minted
   * @param index The next liquidity index of the reserve
   * @return `true` if the the previous balance of the user was 0
   */
  function _mintScaled(
    address caller,
    address onBehalfOf,
    uint256 amount,
    uint256 index
  ) internal returns (bool) {
    // 민팅하려는 amount / 현재 유동성 지수
    uint256 amountScaled = amount.rayDiv(index);
    require(amountScaled != 0, Errors.INVALID_MINT_AMOUNT);

    // scaled된 토큰을 받을 주소의 balance
    uint256 scaledBalance = super.balanceOf(onBehalfOf);
    // 이자 계산
    // balance * 현재 유동성 지수 - balance * 유저의 기존 유동성 지수
    // 유동성 지수란, 유동성에 대한 이자 누적을 나타내는 지수
    uint256 balanceIncrease = scaledBalance.rayMul(index) -
      scaledBalance.rayMul(_userState[onBehalfOf].additionalData);

    // 유저의 기존 유동성 지수를 현재 유동성 지수로 업데이트 
    // 유동성 지수는 항상 증가
    _userState[onBehalfOf].additionalData = index.toUint128();

    // 토큰 민팅
    _mint(onBehalfOf, amountScaled.toUint128());

    // 이벤트로만 이자 적용(StableRate로 이자율이 적용되던 stable debt와 달리 pool에서 updateState와 함께 이자율이 갱신되기에 이벤트로만 처리)
    uint256 amountToMint = amount + balanceIncrease;
    emit Transfer(address(0), onBehalfOf, amountToMint);
    emit Mint(caller, onBehalfOf, amountToMint, balanceIncrease, index);

    return (scaledBalance == 0);
  }

  /**
   * @notice Implements the basic logic to burn a scaled balance token.
   * @dev In some instances, a burn transaction will emit a mint event
   * if the amount to burn is less than the interest that the user accrued
   * @param user The user which debt is burnt
   * @param target The address that will receive the underlying, if any
   * @param amount The amount getting burned
   * @param index The variable debt index of the reserve
   */
  function _burnScaled(address user, address target, uint256 amount, uint256 index) internal {
    // 태울 양 / 유동성 지수
    uint256 amountScaled = amount.rayDiv(index);
    require(amountScaled != 0, Errors.INVALID_BURN_AMOUNT);

    uint256 scaledBalance = super.balanceOf(user);
    // 유저의 추가된 이자
    // balance * 현재 유동성 지수 - balance - 유저의 기존(마지막으로 확인한) 유동성 지수
    uint256 balanceIncrease = scaledBalance.rayMul(index) -
      scaledBalance.rayMul(_userState[user].additionalData);

    // 유저의 기존 유동성 지수를 현재 유동성 지수로 업데이트
    _userState[user].additionalData = index.toUint128();

    // (태울 양 / 유동성 지수)만큼 태우기
    _burn(user, amountScaled.toUint128());
    
    // 자율이 시간에 따라 변할 수 있기에
    // 이벤트로만 이자 적용(StableRate로 이자율이 적용되던 stable debt와 달리 pool에서 updateState와 함께 이자율이 갱신되기에 이벤트로만 처리)
    if (balanceIncrease > amount) {
      uint256 amountToMint = balanceIncrease - amount;
      emit Transfer(address(0), user, amountToMint);
      emit Mint(user, user, amountToMint, balanceIncrease, index);
    } else {
      uint256 amountToBurn = amount - balanceIncrease;
      emit Transfer(user, address(0), amountToBurn);
      emit Burn(user, target, amountToBurn, balanceIncrease, index);
    }
  }

  /**
   * @notice Implements the basic logic to transfer scaled balance tokens between two users
   * @dev It emits a mint event with the interest accrued per user
   * @param sender The source address
   * @param recipient The destination address
   * @param amount The amount getting transferred
   * @param index The next liquidity index of the reserve
   */
  function _transfer(address sender, address recipient, uint256 amount, uint256 index) internal {
    uint256 senderScaledBalance = super.balanceOf(sender);
    // 보내는 사람의 추가된 이자량 계산
    uint256 senderBalanceIncrease = senderScaledBalance.rayMul(index) -
      senderScaledBalance.rayMul(_userState[sender].additionalData);

    // 받는 사람의 추가된 이자량 계산
    uint256 recipientScaledBalance = super.balanceOf(recipient);
    uint256 recipientBalanceIncrease = recipientScaledBalance.rayMul(index) -
      recipientScaledBalance.rayMul(_userState[recipient].additionalData);

    // 둘의 유동성 지수 최신화
    _userState[sender].additionalData = index.toUint128();
    _userState[recipient].additionalData = index.toUint128();

    // (보내려는 양 / 현재 유동성 지수)만큼 전송
    super._transfer(sender, recipient, amount.rayDiv(index).toUint128());

    // 이자는 이벤트로만 처리
    if (senderBalanceIncrease > 0) {
      emit Transfer(address(0), sender, senderBalanceIncrease);
      emit Mint(_msgSender(), sender, senderBalanceIncrease, senderBalanceIncrease, index);
    }

    if (sender != recipient && recipientBalanceIncrease > 0) {
      emit Transfer(address(0), recipient, recipientBalanceIncrease);
      emit Mint(_msgSender(), recipient, recipientBalanceIncrease, recipientBalanceIncrease, index);
    }

    emit Transfer(sender, recipient, amount);
  }
}
