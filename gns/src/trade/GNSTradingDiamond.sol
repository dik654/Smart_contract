// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "../interfaces/IGNSTradingDiamond.sol";
import "../libraries/FeeTiersUtils.sol";

/**
 * @custom:version 6.4.3
 * @custom:oz-upgrades-unsafe-allow external-library-linking
 * @dev For now uses external libraries and wrappers but can be turned into a full diamond when necessary.
 */
contract GNSTradingDiamond is Initializable, IGNSTradingDiamond {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * Global
     */
    AddressStore private addressStore;

    function getAddresses() external view returns (Addresses memory) {
        return addressStore.addresses;
    }

    function _getAddresses() private view returns (Addresses storage) {
        return addressStore.addresses;
    }

    modifier onlyGov() {
        if (msg.sender != _getAddresses().gov) {
            revert WrongAccess();
        }
        _;
    }

    modifier onlyCallbacks() {
        if (msg.sender != _getAddresses().callbacks) {
            revert WrongAccess();
        }
        _;
    }

    /**
     * v6.4.3
     */
    FeeTiersUtils.FeeTiersStorage private feeTiersStorage;

    function initialize(
        address _gov,
        address _callbacks,
        IGNSPairsStorage _pairsStorage,
        uint256[] calldata _groupIndices,
        uint256[] calldata _groupVolumeMultipliers,
        uint256[] calldata _feeTiersIndices,
        FeeTiersUtils.FeeTier[] calldata _feeTiers
    ) external initializer {
        uint256 feeTiersSlot;
        uint256 addressesSlot;
        assembly {
            feeTiersSlot := feeTiersStorage.slot
            addressesSlot := addressStore.slot
        }
        if (!(feeTiersSlot == FeeTiersUtils.getSlot() && addressesSlot == FeeTiersUtils.getAddressesSlot())) {
            revert WrongSlot();
        }

        FeeTiersUtils.initialize(
            _gov,
            _callbacks,
            _pairsStorage,
            _groupIndices,
            _groupVolumeMultipliers,
            _feeTiersIndices,
            _feeTiers
        );
    }

    function setGroupVolumeMultipliers(
        uint256[] calldata _groupIndices,
        uint256[] calldata _groupVolumeMultipliers
    ) external onlyGov {
        FeeTiersUtils.setGroupVolumeMultipliers(_groupIndices, _groupVolumeMultipliers);
    }

    function setFeeTiers(
        uint256[] calldata _feeTiersIndices,
        FeeTiersUtils.FeeTier[] calldata _feeTiers
    ) external onlyGov {
        FeeTiersUtils.setFeeTiers(_feeTiersIndices, _feeTiers);
    }

    function updateTraderPoints(address _trader, uint256 _amount, uint256 _pairIndex) external onlyCallbacks {
        (, , , , , uint256 feeIndex) = _getAddresses().pairsStorage.pairs(_pairIndex);
        FeeTiersUtils.updateTraderPoints(_trader, _amount, feeIndex);
    }

    function calculateFeeAmount(address _trader, uint256 _normalFeeAmount) external view returns (uint256) {
        return FeeTiersUtils.calculateFeeAmount(_trader, _normalFeeAmount);
    }

    function getFeeTiersCount() external view returns (uint256) {
        return FeeTiersUtils.getFeeTiersCount(feeTiersStorage.feeTiers);
    }

    function getFeeTier(uint256 _feeTierIndex) external view returns (FeeTiersUtils.FeeTier memory) {
        return feeTiersStorage.feeTiers[_feeTierIndex];
    }

    function getGroupVolumeMultiplier(uint256 _groupIndex) external view returns (uint256) {
        return feeTiersStorage.groupVolumeMultipliers[_groupIndex];
    }

    function getFeeTiersTraderInfo(address _trader) external view returns (FeeTiersUtils.TraderInfo memory) {
        return feeTiersStorage.traderInfos[_trader];
    }

    function getFeeTiersTraderDailyInfo(
        address _trader,
        uint32 _day
    ) external view returns (FeeTiersUtils.TraderDailyInfo memory) {
        return feeTiersStorage.traderDailyInfos[_trader][_day];
    }
}