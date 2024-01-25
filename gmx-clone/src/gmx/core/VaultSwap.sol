// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "../libraries/utils/ReentrancyGuard.sol";
import "../tokens/interfaces/IUSDG.sol";
import "./interfaces/IVaultBase.sol";

contract VaultSwap is ReentrancyGuard, IVaultBase {
    IVaultBase public vaultbase;
    constructor(address _vaultbase) {
        vaultbase = IVaultBase(_vaultbase);
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _validateManager() private view {
        if (vaultbase.inManagerMode()) {
            vaultbase.validate(vaultbase.isManager(msg.sender), 54);
        }
    }

    // deposit into the pool without minting USDG tokens
    // useful in allowing the pool to become over-collaterised
    /**
     * @dev 토큰을 vault pool에 바로 넣는 함수
     * @param _token .
     */
    function directPoolDeposit(address _token) external override nonReentrant {
        // 사용 가능한 토큰인지 체크
        vaultbase.validate(vaultbase.whitelistedTokens(_token), 14);
        // 넣은 토큰의 크기가 0보다 많은지 체크
        uint256 tokenAmount = vaultbase.transferIn(_token);
        vaultbase.validate(tokenAmount > 0, 15);
        // 넣은 토큰만큼 pool에 추가
        vaultbase.increasePoolAmount(_token, tokenAmount);
        emit DirectPoolDeposit(_token, tokenAmount);
    }

    /**
     * @dev 토큰을 USDG로 swap
     * @param _token 넣을 토큰
     * @param _receiver .
     */
    function buyUSDG(address _token, address _receiver) external override nonReentrant returns (uint256) {
        // 매니저 컨트랙트에 의해서만 실행 가능
        _validateManager();
        // 사용 가능한 토큰인지 체크
        vaultbase.validate(vaultbase.whitelistedTokens(_token), 16);

        // 넣은 토큰 개수 체크
        uint256 tokenAmount = vaultbase.transferIn(_token);
        vaultbase.validate(tokenAmount > 0, 17);

        // 변경된 reserve / pool 기록 증가시키기
        vaultbase.updateCumulativeFundingRate(_token, _token);

        // 해당 토큰 최소 가격 가져오기
        uint256 price = vaultbase.getMinPrice(_token);

        // 내가 넣은 토큰의 총 USD 가치 계산
        uint256 usdgAmount = tokenAmount * price / vaultbase.PRICE_PRECISION();
        usdgAmount = vaultbase.adjustForDecimals(usdgAmount, _token, vaultbase.usdg());
        vaultbase.validate(usdgAmount > 0, 18);

        // 수수료 Basis Point를 가져와 swap 수수료 처리 이후 토큰 개수 리턴
        uint256 feeBasisPoints = vaultbase.vaultUtils().getBuyUsdgFeeBasisPoints(_token, usdgAmount);
        uint256 amountAfterFees = _collectSwapFees(_token, tokenAmount, feeBasisPoints);
  
        // 수수료 처리 이후 토큰 개수 * 토큰 최소가격
        uint256 mintAmount = amountAfterFees * price / vaultbase.PRICE_PRECISION();
        mintAmount = vaultbase.adjustForDecimals(mintAmount, _token, vaultbase.usdg());

        // usdg pool에 토큰 개수만큼 추가
        vaultbase.increaseUsdgAmount(_token, mintAmount);
        // 전체 pool에 토큰 가치만큼 추가
        vaultbase.increasePoolAmount(_token, amountAfterFees);

        // usdg 토큰 개수만큼 receiver에게 전송
        IUSDG(vaultbase.usdg()).mint(_receiver, mintAmount);

        emit BuyUSDG(_receiver, _token, tokenAmount, mintAmount, feeBasisPoints);
        return mintAmount;
    }

    /**
     * @dev USDG를 특정 토큰으로 swap
     * @dev USDG는 시장에서 제거 (총 공급량 감소)
     * @param _token 받을 토큰
     * @param _receiver .
     */
    function sellUSDG(address _token, address _receiver) external override nonReentrant returns (uint256) {
        // 등록된 매니저 컨트랙트만 실행 가능
        _validateManager();
        // 등록된 토큰만 사용가능
        vaultbase.validate(vaultbase.whitelistedTokens(_token), 19);
        
        // 넣은 usdg가 0보다 큰지 체크
        uint256 usdgAmount = vaultbase.transferIn(vaultbase.usdg());
        vaultbase.validate(usdgAmount > 0, 20);
        
        // reserve / pool 누적 업데이트
        vaultbase.updateCumulativeFundingRate(_token, _token);

        // 받을 수 있는 토큰 개수가 0보다 큰지 체크 
        uint256 redemptionAmount = vaultbase.getRedemptionAmount(_token, usdgAmount);
        vaultbase.validate(redemptionAmount > 0, 21);

        // swap되는 USDG만큼 usdg pool에서 빼기 (시장에서 제거)
        // USDG는 Vault 시스템 내에서 생성되고 관리되는 스테이블코인이므로 총 공급량이 usdgAmount로 고정되어있기 때문)
        vaultbase.decreaseUsdgAmount(_token, usdgAmount);
        // 전체 pool에서 받는 토큰의 개수만큼 빼기
        vaultbase.decreasePoolAmount(_token, redemptionAmount);

        // USDG 시장에서 실제로 제거
        IUSDG(vaultbase.usdg()).burn(address(this), usdgAmount);

        // _decreaseUsdgAmount로 token balance까지 업데이트 되지 않으므로 
        // 실제로 제거된 usdg 토큰 개수만큼 token balance 업데이트 
        vaultbase.updateTokenBalance(vaultbase.usdg());

        // 수수료를 제외한 토큰 개수 계산
        uint256 feeBasisPoints = vaultbase.vaultUtils().getSellUsdgFeeBasisPoints(_token, usdgAmount);
        uint256 amountOut = _collectSwapFees(_token, redemptionAmount, feeBasisPoints);
        vaultbase.validate(amountOut > 0, 22);

        // 바꾼 토큰을 receiver에게 전달
        vaultbase.transferOut(_token, amountOut, _receiver);

        emit SellUSDG(_receiver, _token, usdgAmount, amountOut, feeBasisPoints);
        return amountOut;
    }

    /**
     * @dev A 토큰을 B 토큰으로 바꾸는 함수
     * @param _tokenIn .
     * @param _tokenOut .
     * @param _receiver .
     */
    function swap(address _tokenIn, address _tokenOut, address _receiver) external override nonReentrant returns (uint256) {
        // swap 가능 플래그가 켜져있는지 체크
        vaultbase.validate(vaultbase.isSwapEnabled(), 23);
        // 두 토큰 모두 등록된 토큰인지 체크
        vaultbase.validate(vaultbase.whitelistedTokens(_tokenIn), 24);
        vaultbase.validate(vaultbase.whitelistedTokens(_tokenOut), 25);
        // 서로 다른 토큰이 맞는지 체크
        vaultbase.validate(_tokenIn != _tokenOut, 26);

        // 두 토큰 모두 reserve / pool 비율 누적 업데이트
        vaultbase.updateCumulativeFundingRate(_tokenIn, _tokenIn);
        vaultbase.updateCumulativeFundingRate(_tokenOut, _tokenOut);

        // 토큰 넣은 개수가 0개보다 큰 지 체크
        uint256 amountIn = vaultbase.transferIn(_tokenIn);
        vaultbase.validate(amountIn > 0, 27);

        // 넣은 토큰의 최소 가치와 받을 토큰의 최대 가치 
        uint256 priceIn = vaultbase.getMinPrice(_tokenIn);
        uint256 priceOut = vaultbase.getMaxPrice(_tokenOut);

        // 받을 토큰 개수 = 넣은 토큰 개수 * (넣은 토큰 가치 / 받을 토큰 가치)
        uint256 amountOut = amountIn * priceIn / priceOut;
        amountOut = vaultbase.adjustForDecimals(amountOut, _tokenIn, _tokenOut);

        // USDG는 Vault 시스템 내에서 다른 토큰을 예치하고 발행되는 스테이블코인
        // 항상 각 토큰의 가치 변동을 USDG가 해야 시스템이 안정적이므로 두 토큰 간 교환임에도 usdgAmount를 변경시킨다
        // 토큰 개수 = 넣은 토큰 * 넣은 토큰 가격
        // USDG 개수 = 토큰 개수 * (넣은 토큰 가치 / USDG 가치) 
        // adjust usdgAmounts by the same usdgAmount as debt is shifted between the assets
        uint256 usdgAmount = amountIn * priceIn / vaultbase.PRICE_PRECISION();
        usdgAmount = vaultbase.adjustForDecimals(usdgAmount, _tokenIn, vaultbase.usdg());

        // 수수료 처리 후의 토큰 개수 계산 
        uint256 feeBasisPoints = vaultbase.vaultUtils().getSwapFeeBasisPoints(_tokenIn, _tokenOut, usdgAmount);
        uint256 amountOutAfterFees = _collectSwapFees(_tokenOut, amountOut, feeBasisPoints);

        // swap에 따른 USDG 가치 업데이트
        vaultbase.increaseUsdgAmount(_tokenIn, usdgAmount);
        vaultbase.decreaseUsdgAmount(_tokenOut, usdgAmount);

        // swap에 따른 전체 pool의 토큰 개수 업데이트
        vaultbase.increasePoolAmount(_tokenIn, amountIn);
        vaultbase.decreasePoolAmount(_tokenOut, amountOut);

        // Buffer은 최소 유동성으로, 시스템의 안정성을 위해 항상 vault안에 지정한 Buffer보다 많은 양의 토큰을 갖도록 검사
        vaultbase.validateBufferAmount(_tokenOut);

        // swap한 토큰 receiver에게 전송
        vaultbase.transferOut(_tokenOut, amountOutAfterFees, _receiver);

        emit Swap(_receiver, _tokenIn, _tokenOut, amountIn, amountOut, amountOutAfterFees, feeBasisPoints);
        return amountOutAfterFees;
    }

    function _collectSwapFees(address _token, uint256 _amount, uint256 _feeBasisPoints) private returns (uint256) {
        uint256 afterFeeAmount = _amount * (vaultbase.BASIS_POINTS_DIVISOR() - _feeBasisPoints) / vaultbase.BASIS_POINTS_DIVISOR();
        uint256 feeAmount = _amount - afterFeeAmount;
        vaultbase.increaseFeeReserves(_token, feeAmount);
        emit CollectSwapFees(_token, vaultbase.tokenToUsdMin(_token, feeAmount), feeAmount);
        return afterFeeAmount;
    }
}