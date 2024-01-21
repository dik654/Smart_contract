// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../libraries/math/SafeMath.sol";
import "../libraries/token/IERC20.sol";
import "../libraries/token/SafeERC20.sol";
import "../libraries/utils/ReentrancyGuard.sol";

import "./interfaces/IRewardDistributor.sol";
import "./interfaces/IRewardTracker.sol";
import "../access/Governable.sol";

contract RewardDistributor is IRewardDistributor, ReentrancyGuard, Governable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public override rewardToken;
    uint256 public override tokensPerInterval;
    uint256 public lastDistributionTime;
    address public rewardTracker;

    address public admin;

    event Distribute(uint256 amount);
    event TokensPerIntervalChange(uint256 amount);

    modifier onlyAdmin() {
        require(msg.sender == admin, "RewardDistributor: forbidden");
        _;
    }

    constructor(address _rewardToken, address _rewardTracker) public {
        rewardToken = _rewardToken;
        rewardTracker = _rewardTracker;
        admin = msg.sender;
    }

    function setAdmin(address _admin) external onlyGov {
        admin = _admin;
    }

    function withdrawToken(address _token, address _account, uint256 _amount) external onlyGov {
        // to help users who accidentally send their tokens to this contract
        // 실수로 이 컨트랙트에 토큰 전송한 경우 빼주기 위한 governor용 함수
        IERC20(_token).safeTransfer(_account, _amount);
    }

    function updateLastDistributionTime() external onlyAdmin {
        lastDistributionTime = block.timestamp;
    }

    function setTokensPerInterval(uint256 _amount) external onlyAdmin {
        require(lastDistributionTime != 0, "RewardDistributor: invalid lastDistributionTime");
        IRewardTracker(rewardTracker).updateRewards();
        tokensPerInterval = _amount;
        emit TokensPerIntervalChange(_amount);
    }

    
    /**
     * @dev     지난 시간동안 얼마나 리워드가 쌓였는지
     * @return  uint256  
     */
    function pendingRewards() public view override returns (uint256) {
        if (block.timestamp == lastDistributionTime) {
            return 0;
        }
        // 초당 토큰 * 지난 시간(초 단위)
        uint256 timeDiff = block.timestamp.sub(lastDistributionTime);
        return tokensPerInterval.mul(timeDiff);
    }

    /**
     * @dev     rewardTracker로 리워드 전송
     * @return  uint256 리워드 수량
     */
    function distribute() external override returns (uint256) {
        // rewardTracker만 실행가능
        require(msg.sender == rewardTracker, "RewardDistributor: invalid msg.sender");
        // 쌓인 리워드 확인하고 없다면 종료
        uint256 amount = pendingRewards();
        if (amount == 0) { return 0; }

        // 리워드 꺼낸시간 업데이트
        lastDistributionTime = block.timestamp;

        // 리워드 잔고 확인하고 충분한지 확인
        uint256 balance = IERC20(rewardToken).balanceOf(address(this));
        if (amount > balance) { amount = balance; }

        // 충분하다면 리워드 rewardTracker에 전송
        IERC20(rewardToken).safeTransfer(msg.sender, amount);

        emit Distribute(amount);
        return amount;
    }
}