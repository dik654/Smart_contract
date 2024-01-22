// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

/**
 * @custom:version 6.4.3
 *
 * @dev This is a library to help manage storage slots used by our external libraries.
 *
 * BE EXTREMELY CAREFUL, DO NOT EDIT THIS WITHOUT A GOOD REASON
 *
 */
library StorageUtils {
    uint256 internal constant PRICE_IMPACT_OI_WINDOWS_STORAGE_SLOT = 7;
    uint256 internal constant ADDRESSES_STORAGE_SLOT = 1;
    uint256 internal constant FEE_TIERS_STORAGE_SLOT = 51;
}