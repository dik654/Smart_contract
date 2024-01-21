// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../libraries/math/SafeMath.sol";
import "../libraries/token/IERC20.sol";
import "../libraries/token/SafeERC20.sol";
import "../libraries/utils/ReentrancyGuard.sol";

import "./interfaces/IRewardDistributor.sol";
import "./interfaces/IRewardTracker.sol";
import "../access/Governable.sol";

// GMX token 관리
contract RewardTracker is IERC20, ReentrancyGuard, IRewardTracker, Governable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant PRECISION = 1e30;

    uint8 public constant decimals = 18;

    bool public isInitialized;

    string public name;
    string public symbol;

    address public distributor;
    mapping (address => bool) public isDepositToken;
    mapping (address => mapping (address => uint256)) public override depositBalances;
    mapping (address => uint256) public totalDepositSupply;

    uint256 public override totalSupply;
    mapping (address => uint256) public balances;
    mapping (address => mapping (address => uint256)) public allowances;

    uint256 public cumulativeRewardPerToken;
    mapping (address => uint256) public override stakedAmounts;
    mapping (address => uint256) public claimableReward;
    mapping (address => uint256) public previousCumulatedRewardPerToken;
    mapping (address => uint256) public override cumulativeRewards;
    mapping (address => uint256) public override averageStakedAmounts;

    bool public inPrivateTransferMode;
    bool public inPrivateStakingMode;
    bool public inPrivateClaimingMode;
    mapping (address => bool) public isHandler;

    event Claim(address receiver, uint256 amount);

    constructor(string memory _name, string memory _symbol) public {
        name = _name;
        symbol = _symbol;
    }

    function initialize(
        address[] memory _depositTokens,
        address _distributor
    ) external onlyGov {
        require(!isInitialized, "RewardTracker: already initialized");
        isInitialized = true;

        for (uint256 i = 0; i < _depositTokens.length; i++) {
            address depositToken = _depositTokens[i];
            isDepositToken[depositToken] = true;
        }

        distributor = _distributor;
    }

    function setDepositToken(address _depositToken, bool _isDepositToken) external onlyGov {
        isDepositToken[_depositToken] = _isDepositToken;
    }

    function setInPrivateTransferMode(bool _inPrivateTransferMode) external onlyGov {
        inPrivateTransferMode = _inPrivateTransferMode;
    }

    function setInPrivateStakingMode(bool _inPrivateStakingMode) external onlyGov {
        inPrivateStakingMode = _inPrivateStakingMode;
    }

    function setInPrivateClaimingMode(bool _inPrivateClaimingMode) external onlyGov {
        inPrivateClaimingMode = _inPrivateClaimingMode;
    }

    function setHandler(address _handler, bool _isActive) external onlyGov {
        isHandler[_handler] = _isActive;
    }

    // to help users who accidentally send their tokens to this contract
    function withdrawToken(address _token, address _account, uint256 _amount) external onlyGov {
        IERC20(_token).safeTransfer(_account, _amount);
    }

    function balanceOf(address _account) external view override returns (uint256) {
        return balances[_account];
    }

    function stake(address _depositToken, uint256 _amount) external override nonReentrant {
        if (inPrivateStakingMode) { revert("RewardTracker: action not enabled"); }
        _stake(msg.sender, msg.sender, _depositToken, _amount);
    }

    function stakeForAccount(address _fundingAccount, address _account, address _depositToken, uint256 _amount) external override nonReentrant {
        _validateHandler();
        _stake(_fundingAccount, _account, _depositToken, _amount);
    }

    function unstake(address _depositToken, uint256 _amount) external override nonReentrant {
        if (inPrivateStakingMode) { revert("RewardTracker: action not enabled"); }
        _unstake(msg.sender, _depositToken, _amount, msg.sender);
    }

    function unstakeForAccount(address _account, address _depositToken, uint256 _amount, address _receiver) external override nonReentrant {
        _validateHandler();
        _unstake(_account, _depositToken, _amount, _receiver);
    }

    function transfer(address _recipient, uint256 _amount) external override returns (bool) {
        _transfer(msg.sender, _recipient, _amount);
        return true;
    }

    function allowance(address _owner, address _spender) external view override returns (uint256) {
        return allowances[_owner][_spender];
    }

    function approve(address _spender, uint256 _amount) external override returns (bool) {
        _approve(msg.sender, _spender, _amount);
        return true;
    }

    function transferFrom(address _sender, address _recipient, uint256 _amount) external override returns (bool) {
        if (isHandler[msg.sender]) {
            _transfer(_sender, _recipient, _amount);
            return true;
        }

        uint256 nextAllowance = allowances[_sender][msg.sender].sub(_amount, "RewardTracker: transfer amount exceeds allowance");
        _approve(_sender, msg.sender, nextAllowance);
        _transfer(_sender, _recipient, _amount);
        return true;
    }

    function tokensPerInterval() external override view returns (uint256) {
        return IRewardDistributor(distributor).tokensPerInterval();
    }

    function updateRewards() external override nonReentrant {
        _updateRewards(address(0));
    }

    function claim(address _receiver) external override nonReentrant returns (uint256) {
        if (inPrivateClaimingMode) { revert("RewardTracker: action not enabled"); }
        return _claim(msg.sender, _receiver);
    }

    function claimForAccount(address _account, address _receiver) external override nonReentrant returns (uint256) {
        _validateHandler();
        return _claim(_account, _receiver);
    }

    function claimable(address _account) public override view returns (uint256) {
        // 유저가 스테이킹한 개수
        uint256 stakedAmount = stakedAmounts[_account];
        if (stakedAmount == 0) {
            return claimableReward[_account];
        }
        // 총 gmx
        uint256 supply = totalSupply;
        uint256 pendingRewards = IRewardDistributor(distributor).pendingRewards().mul(PRECISION);
        uint256 nextCumulativeRewardPerToken = cumulativeRewardPerToken.add(pendingRewards.div(supply));
        return claimableReward[_account].add(
            stakedAmount.mul(nextCumulativeRewardPerToken.sub(previousCumulatedRewardPerToken[_account])).div(PRECISION));
    }

    function rewardToken() public view returns (address) {
        return IRewardDistributor(distributor).rewardToken();
    }

    function _claim(address _account, address _receiver) private returns (uint256) {
        _updateRewards(_account);

        uint256 tokenAmount = claimableReward[_account];
        claimableReward[_account] = 0;

        if (tokenAmount > 0) {
            IERC20(rewardToken()).safeTransfer(_receiver, tokenAmount);
            emit Claim(_account, tokenAmount);
        }

        return tokenAmount;
    }

    function _mint(address _account, uint256 _amount) internal {
        require(_account != address(0), "RewardTracker: mint to the zero address");

        totalSupply = totalSupply.add(_amount);
        balances[_account] = balances[_account].add(_amount);

        emit Transfer(address(0), _account, _amount);
    }

    function _burn(address _account, uint256 _amount) internal {
        require(_account != address(0), "RewardTracker: burn from the zero address");

        balances[_account] = balances[_account].sub(_amount, "RewardTracker: burn amount exceeds balance");
        // 총 gmx - 태울 양
        totalSupply = totalSupply.sub(_amount);

        emit Transfer(_account, address(0), _amount);
    }

    function _transfer(address _sender, address _recipient, uint256 _amount) private {
        require(_sender != address(0), "RewardTracker: transfer from the zero address");
        require(_recipient != address(0), "RewardTracker: transfer to the zero address");

        // private mode에서는 허용된 핸들러만 실행 가능
        if (inPrivateTransferMode) { _validateHandler(); }

        balances[_sender] = balances[_sender].sub(_amount, "RewardTracker: transfer amount exceeds balance");
        balances[_recipient] = balances[_recipient].add(_amount);

        emit Transfer(_sender, _recipient,_amount);
    }

    function _approve(address _owner, address _spender, uint256 _amount) private {
        require(_owner != address(0), "RewardTracker: approve from the zero address");
        require(_spender != address(0), "RewardTracker: approve to the zero address");

        allowances[_owner][_spender] = _amount;

        emit Approval(_owner, _spender, _amount);
    }

    function _validateHandler() private view {
        require(isHandler[msg.sender], "RewardTracker: forbidden");
    }

    function _stake(address _fundingAccount, address _account, address _depositToken, uint256 _amount) private {
        require(_amount > 0, "RewardTracker: invalid _amount");
        // 허용된 토큰만 deposit 가능
        require(isDepositToken[_depositToken], "RewardTracker: invalid _depositToken");

        // 이 컨트랙트에 토큰 전송
        IERC20(_depositToken).safeTransferFrom(_fundingAccount, address(this), _amount);

        // 유저 리워드 갱신
        _updateRewards(_account);

        // 유저가 스테이킹한 총 토큰 양(모든 토큰) += 이번에 추가할 양
        stakedAmounts[_account] = stakedAmounts[_account].add(_amount);
        // 해당 토큰 종류로 스테이킹한 양
        depositBalances[_account][_depositToken] = depositBalances[_account][_depositToken].add(_amount);
        // 해당 토큰으로 스테이킹된 총량
        totalDepositSupply[_depositToken] = totalDepositSupply[_depositToken].add(_amount);

        // gmx 민팅
        _mint(_account, _amount);
    }

    function _unstake(address _account, address _depositToken, uint256 _amount, address _receiver) private {
        require(_amount > 0, "RewardTracker: invalid _amount");
        require(isDepositToken[_depositToken], "RewardTracker: invalid _depositToken");
        // 유저 리워드 갱신
        _updateRewards(_account);

        // 유저 stake 총량이 unstake량보다 커야한다
        uint256 stakedAmount = stakedAmounts[_account];
        require(stakedAmounts[_account] >= _amount, "RewardTracker: _amount exceeds stakedAmount");

        // 꺼냈으므로 stake 총량 - unstake하려는 양
        stakedAmounts[_account] = stakedAmount.sub(_amount);

        uint256 depositBalance = depositBalances[_account][_depositToken];
        require(depositBalance >= _amount, "RewardTracker: _amount exceeds depositBalance");
        // 해당 토큰 deposit balance 감소(stake한 특정 토큰)
        depositBalances[_account][_depositToken] = depositBalance.sub(_amount);
        // 컨트랙트에 deposit된 총량 unstake한만큼 감소
        totalDepositSupply[_depositToken] = totalDepositSupply[_depositToken].sub(_amount);

        // unstake한만큼 gmx 태우고
        _burn(_account, _amount);
        // 동일한 양만큼 특정 토큰 전송
        IERC20(_depositToken).safeTransfer(_receiver, _amount);
    }

    function _updateRewards(address _account) private {
        // rewardTracker에 쌓여있는 staking 리워드 이 컨트랙트로 전송(vesting)
        uint256 blockReward = IRewardDistributor(distributor).distribute();

        uint256 supply = totalSupply;
        uint256 _cumulativeRewardPerToken = cumulativeRewardPerToken;
        if (supply > 0 && blockReward > 0) {
            // 누적으로 계산하고있던 토큰 보상 = 이전 누적으로 계산하고있던 토큰 보상 + ((rewardTracker에서 꺼내온 보상 / 총 gmx 개수) * 정밀도)로 업데이트
            _cumulativeRewardPerToken = _cumulativeRewardPerToken.add(blockReward.mul(PRECISION).div(supply));
            cumulativeRewardPerToken = _cumulativeRewardPerToken;
        }

        // cumulativeRewardPerToken can only increase
        // so if cumulativeRewardPerToken is zero, it means there are no rewards yet
        // 아직 쌓여있는 보상이 없는 경우 종료
        if (_cumulativeRewardPerToken == 0) {
            return;
        }

        if (_account != address(0)) {
            uint256 stakedAmount = stakedAmounts[_account];
            // 이번 유저 보상 = 스테이킹된 양 * (rewardTracker에서 꺼내온 보상 / 총 gmx 개수) 
            // 즉 (스테이킹된 양 / 총 gmx)는 전체에서 유저의 비율 * 이번에 꺼내온 보상으로 계산
            uint256 accountReward = stakedAmount.mul(_cumulativeRewardPerToken.sub(previousCumulatedRewardPerToken[_account])).div(PRECISION);
            // 계정이 받을 수 있는 보상 += 방금 계산한 보상
            uint256 _claimableReward = claimableReward[_account].add(accountReward);

            // 유저가 받을 수 있는 보상 기록
            claimableReward[_account] = _claimableReward;
            // 이전 누적 토큰 보상 계산 업데이트 
            previousCumulatedRewardPerToken[_account] = _cumulativeRewardPerToken;

            if (_claimableReward > 0 && stakedAmounts[_account] > 0) {
                // 유저의 누적 리워드 += 이번 리워드
                uint256 nextCumulativeReward = cumulativeRewards[_account].add(accountReward);

                // 업데이트된 유저의 평균 스테이킹된 양 = 기존 유저의 평균 스테이킹된 양 * (기존 유저의 누적 리워드 / 갱신된 유저의 누적 리워드) + (유저가 스테이킹한 양 * 이번 유저 보상 / 갱신된 유저 리워드)
                averageStakedAmounts[_account] = averageStakedAmounts[_account].mul(cumulativeRewards[_account]).div(nextCumulativeReward)
                    .add(stakedAmount.mul(accountReward).div(nextCumulativeReward));

                // 누적 리워드 업데이트
                cumulativeRewards[_account] = nextCumulativeReward;
            }
        }
    }
}