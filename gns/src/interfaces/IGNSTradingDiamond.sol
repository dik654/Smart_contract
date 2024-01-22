// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "../interfaces/IGNSPairsStorage.sol";
import "../libraries/FeeTiersUtils.sol";

/**
 * @custom:version 6.4.3
 */
interface IGNSTradingDiamond {
    /**
     * Global
     */
    struct Addresses {
        address gov;
        address callbacks;
        IGNSPairsStorage pairsStorage;
    }

    struct AddressStore {
        Addresses addresses;
        uint256[47] __gap; // 50 addresses maximum
    }

    error WrongSlot();
    error WrongAccess();

    event AddressesUpdated(Addresses addresses);

    /**
     * v6.4.3
     */
    function updateTraderPoints(address trader, uint256 amount, uint256 pairIndex) external;
    function calculateFeeAmount(address trader, uint256 normalFeeAmount) external view returns (uint256);

    event GroupVolumeMultipliersUpdated(uint256[] groupIndices, uint256[] groupVolumeMultipliers);
    event FeeTiersUpdated(uint256[] feeTiersIndices, FeeTiersUtils.FeeTier[] feeTiers);
    event TraderDailyPointsIncreased(address indexed trader, uint32 indexed day, uint224 points);
    event TraderInfoFirstUpdate(address indexed trader, uint32 day);
    event TraderTrailingPointsExpired(address indexed trader, uint32 fromDay, uint32 toDay, uint224 amount);
    event TraderInfoUpdated(address indexed trader, FeeTiersUtils.TraderInfo traderInfo);
    event TraderFeeMultiplierCached(address indexed trader, uint32 indexed day, uint32 feeMultiplier);
}