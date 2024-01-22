// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "../interfaces/IGNSBorrowingFees.sol";

/**
 * @custom:version 6.4.3
 *
 * @dev This is a library with methods used by GNSBorrowingFees contract.
 */
library BorrowingFeesUtils {
    function getPendingAccFees(
        IGNSBorrowingFees.PendingAccFeesInput memory input
    ) public pure returns (uint64 newAccFeeLong, uint64 newAccFeeShort, uint64 delta) {
        if (input.currentBlock < input.accLastUpdatedBlock) {
            revert IGNSBorrowingFees.BlockOrder();
        }

        bool moreShorts = input.oiLong < input.oiShort;
        uint256 netOi = moreShorts ? input.oiShort - input.oiLong : input.oiLong - input.oiShort;

        uint256 _delta = input.maxOi > 0 && input.feeExponent > 0
            ? ((input.currentBlock - input.accLastUpdatedBlock) *
                input.feePerBlock *
                ((netOi * 1e10) / input.maxOi) ** input.feeExponent) / (1e18 ** input.feeExponent)
            : 0; // 1e10 (%)

        if (_delta > type(uint64).max) {
            revert IGNSBorrowingFees.Overflow();
        }
        delta = uint64(_delta);

        newAccFeeLong = moreShorts ? input.accFeeLong : input.accFeeLong + delta;
        newAccFeeShort = moreShorts ? input.accFeeShort + delta : input.accFeeShort;
    }
}