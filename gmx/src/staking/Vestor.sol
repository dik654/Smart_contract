// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../libraries/math/SafeMath.sol";
import "../libraries/token/IERC20.sol";
import "../libraries/token/SafeERC20.sol";
import "../libraries/utils/ReentrancyGuard.sol";

import "./interfaces/IRewardTracker.sol";
import "./interfaces/IVester.sol";
import "../tokens/interfaces/IMintable.sol";
import "../access/Governable.sol";

contract Vester is IVester, IERC20, ReentrancyGuard, Governable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    string public name;
    string public symbol;
    uint8 public decimals = 18;

    uint256 public vestingDuration;

    address public esToken;
    address public pairToken;
    address public claimableToken;

    address public override rewardTracker;

    uint256 public override totalSupply;
    uint256 public pairSupply;

    bool public hasMaxVestableAmount;

    mapping (address => uint256) public balances;
    mapping (address => uint256) public override pairAmounts;
    mapping (address => uint256) public override cumulativeClaimAmounts;
    mapping (address => uint256) public override claimedAmounts;
    mapping (address => uint256) public lastVestingTimes;

    mapping (address => uint256) public override transferredAverageStakedAmounts;
    mapping (address => uint256) public override transferredCumulativeRewards;
    mapping (address => uint256) public override cumulativeRewardDeductions;
    mapping (address => uint256) public override bonusRewards;

    mapping (address => bool) public isHandler;

    event Claim(address receiver, uint256 amount);
    event Deposit(address account, uint256 amount);
    event Withdraw(address account, uint256 claimedAmount, uint256 balance);
    event PairTransfer(address indexed from, address indexed to, uint256 value);

    constructor (
        string memory _name,
        string memory _symbol,
        uint256 _vestingDuration,
        address _esToken,
        address _pairToken,
        address _claimableToken,
        address _rewardTracker
    ) public {
        name = _name;
        symbol = _symbol;

        // vesting 기간
        vestingDuration = _vestingDuration;

        esToken = _esToken;
        // vGMX (용도는 모르겠음)
        pairToken = _pairToken;
        // GMX
        claimableToken = _claimableToken;

        // GMX 또는 GLP
        rewardTracker = _rewardTracker;

        if (rewardTracker != address(0)) {
            hasMaxVestableAmount = true;
        }
    }

    function setHandler(address _handler, bool _isActive) external onlyGov {
        isHandler[_handler] = _isActive;
    }

    function setHasMaxVestableAmount(bool _hasMaxVestableAmount) external onlyGov {
        hasMaxVestableAmount = _hasMaxVestableAmount;
    }

    function deposit(uint256 _amount) external nonReentrant {
        _deposit(msg.sender, _amount);
    }

    function depositForAccount(address _account, uint256 _amount) external nonReentrant {
        _validateHandler();
        _deposit(_account, _amount);
    }

    function claim() external nonReentrant returns (uint256) {
        return _claim(msg.sender, msg.sender);
    }

    function claimForAccount(address _account, address _receiver) external override nonReentrant returns (uint256) {
        _validateHandler();
        return _claim(_account, _receiver);
    }

    // to help users who accidentally send their tokens to this contract
    function withdrawToken(address _token, address _account, uint256 _amount) external onlyGov {
        IERC20(_token).safeTransfer(_account, _amount);
    }

    function withdraw() external nonReentrant {
        address account = msg.sender;
        address _receiver = account;
        _claim(account, _receiver);
        // 유저가 꺼낼 수 있는 양
        uint256 claimedAmount = cumulativeClaimAmounts[account];
        uint256 balance = balances[account];
        uint256 totalVested = balance.add(claimedAmount);
        require(totalVested > 0, "Vester: vested amount is zero");

        if (hasPairToken()) {
            uint256 pairAmount = pairAmounts[account];
            _burnPair(account, pairAmount);
            IERC20(pairToken).safeTransfer(_receiver, pairAmount);
        }

        IERC20(esToken).safeTransfer(_receiver, balance);
        _burn(account, balance);

        delete cumulativeClaimAmounts[account];
        delete claimedAmounts[account];
        delete lastVestingTimes[account];

        emit Withdraw(account, claimedAmount, balance);
    }

    /**
     * @dev     계정 보상 이전
     * @param   _sender  에서
     * @param   _receiver  로 전송
     */
    function transferStakeValues(address _sender, address _receiver) external override nonReentrant {
        // 등록된 핸들러만 사용가능
        _validateHandler();

        transferredAverageStakedAmounts[_receiver] = getCombinedAverageStakedAmount(_sender);
        transferredAverageStakedAmounts[_sender] = 0;

        // sender의 전송받은 보상 가져오기
        uint256 transferredCumulativeReward = transferredCumulativeRewards[_sender];
        // rewardTracker에 쌓인 sender의 누적 보상
        uint256 cumulativeReward = IRewardTracker(rewardTracker).cumulativeRewards(_sender);

        // receiver에게 모두 옮기기
        transferredCumulativeRewards[_receiver] = transferredCumulativeReward.add(cumulativeReward);
        // 이전한 누적 보상 기록(rewardTracker의 보상을 수정하지 않으므로 여기에서 이동한 양을 기록한다)
        cumulativeRewardDeductions[_sender] = cumulativeReward;
        // sender의 누적 보상들 0으로 변경
        transferredCumulativeRewards[_sender] = 0;

        // 보너스 보상도 이전
        bonusRewards[_receiver] = bonusRewards[_sender];
        bonusRewards[_sender] = 0;
    }

    function setTransferredAverageStakedAmounts(address _account, uint256 _amount) external override nonReentrant {
        _validateHandler();
        transferredAverageStakedAmounts[_account] = _amount;
    }

    function setTransferredCumulativeRewards(address _account, uint256 _amount) external override nonReentrant {
        _validateHandler();
        transferredCumulativeRewards[_account] = _amount;
    }

    function setCumulativeRewardDeductions(address _account, uint256 _amount) external override nonReentrant {
        _validateHandler();
        cumulativeRewardDeductions[_account] = _amount;
    }

    function setBonusRewards(address _account, uint256 _amount) external override nonReentrant {
        _validateHandler();
        bonusRewards[_account] = _amount;
    }

    
    /**
     * @dev     유저가 claim 가능한 총량
     * @param   _account  
     * @return  uint256  
     */
    function claimable(address _account) public override view returns (uint256) {
        uint256 amount = cumulativeClaimAmounts[_account].sub(claimedAmounts[_account]);
        uint256 nextClaimable = _getNextClaimableAmount(_account);
        return amount.add(nextClaimable);
    }

    function getMaxVestableAmount(address _account) public override view returns (uint256) {
        if (!hasRewardTracker()) { return 0; }

        uint256 transferredCumulativeReward = transferredCumulativeRewards[_account];
        uint256 bonusReward = bonusRewards[_account];
        uint256 cumulativeReward = IRewardTracker(rewardTracker).cumulativeRewards(_account);
        // 꺼낼 수 있는 총량
        uint256 maxVestableAmount = cumulativeReward.add(transferredCumulativeReward).add(bonusReward);

        // 지워야할 양 (계정 보상 이전으로)
        uint256 cumulativeRewardDeduction = cumulativeRewardDeductions[_account];

        // 꺼낼 수 있는 양이 지워야할 양보다 커야함
        if (maxVestableAmount < cumulativeRewardDeduction) {
            return 0;
        }

        return maxVestableAmount.sub(cumulativeRewardDeduction);
    }

    function getCombinedAverageStakedAmount(address _account) public override view returns (uint256) {
        // 유저의 누적 리워드
        uint256 cumulativeReward = IRewardTracker(rewardTracker).cumulativeRewards(_account);
        // 이전 받은 누적 보상
        uint256 transferredCumulativeReward = transferredCumulativeRewards[_account];
        // 유저의 전체 누적 리워드
        uint256 totalCumulativeReward = cumulativeReward.add(transferredCumulativeReward);
        if (totalCumulativeReward == 0) { return 0; }

        // 유저의 평균 스테이킹된 양
        uint256 averageStakedAmount = IRewardTracker(rewardTracker).averageStakedAmounts(_account);
        uint256 transferredAverageStakedAmount = transferredAverageStakedAmounts[_account];

        // 그 전 유저의 평균 스테이킹된 양 * (유저의 누적 리워드 / 유저의 전체 누적 리워드) + (이전 받은 평균 스테이킹된 양 * 이전 받은 누적 보상 / 유저의 전체 누적 리워드)
        return averageStakedAmount
            .mul(cumulativeReward)
            .div(totalCumulativeReward)
            .add(
                transferredAverageStakedAmount.mul(transferredCumulativeReward).div(totalCumulativeReward)
            );
    }

    function getPairAmount(address _account, uint256 _esAmount) public view returns (uint256) {
        if (!hasRewardTracker()) { return 0; }

        uint256 combinedAverageStakedAmount = getCombinedAverageStakedAmount(_account);
        if (combinedAverageStakedAmount == 0) {
            return 0;
        }

        uint256 maxVestableAmount = getMaxVestableAmount(_account);
        if (maxVestableAmount == 0) {
            return 0;
        }

        return _esAmount.mul(combinedAverageStakedAmount).div(maxVestableAmount);
    }

    function hasRewardTracker() public view returns (bool) {
        return rewardTracker != address(0);
    }

    function hasPairToken() public view returns (bool) {
        return pairToken != address(0);
    }

    function getTotalVested(address _account) public view returns (uint256) {
        return balances[_account].add(cumulativeClaimAmounts[_account]);
    }

    function balanceOf(address _account) public view override returns (uint256) {
        return balances[_account];
    }

    // empty implementation, tokens are non-transferrable
    function transfer(address /* recipient */, uint256 /* amount */) public override returns (bool) {
        revert("Vester: non-transferrable");
    }

    // empty implementation, tokens are non-transferrable
    function allowance(address /* owner */, address /* spender */) public view virtual override returns (uint256) {
        return 0;
    }

    // empty implementation, tokens are non-transferrable
    function approve(address /* spender */, uint256 /* amount */) public virtual override returns (bool) {
        revert("Vester: non-transferrable");
    }

    // empty implementation, tokens are non-transferrable
    function transferFrom(address /* sender */, address /* recipient */, uint256 /* amount */) public virtual override returns (bool) {
        revert("Vester: non-transferrable");
    }

    function getVestedAmount(address _account) public override view returns (uint256) {
        // vesting한 양
        uint256 balance = balances[_account];
        // 받을 수 있는 양
        uint256 cumulativeClaimAmount = cumulativeClaimAmounts[_account];
        // 총량
        return balance.add(cumulativeClaimAmount);
    }

    function _mint(address _account, uint256 _amount) private {
        require(_account != address(0), "Vester: mint to the zero address");

        totalSupply = totalSupply.add(_amount);
        balances[_account] = balances[_account].add(_amount);

        emit Transfer(address(0), _account, _amount);
    }

    function _mintPair(address _account, uint256 _amount) private {
        require(_account != address(0), "Vester: mint to the zero address");

        pairSupply = pairSupply.add(_amount);
        pairAmounts[_account] = pairAmounts[_account].add(_amount);

        emit PairTransfer(address(0), _account, _amount);
    }

    function _burn(address _account, uint256 _amount) private {
        require(_account != address(0), "Vester: burn from the zero address");

        balances[_account] = balances[_account].sub(_amount, "Vester: burn amount exceeds balance");
        totalSupply = totalSupply.sub(_amount);

        emit Transfer(_account, address(0), _amount);
    }

    function _burnPair(address _account, uint256 _amount) private {
        require(_account != address(0), "Vester: burn from the zero address");

        pairAmounts[_account] = pairAmounts[_account].sub(_amount, "Vester: burn amount exceeds balance");
        pairSupply = pairSupply.sub(_amount);

        emit PairTransfer(_account, address(0), _amount);
    }

    function _deposit(address _account, uint256 _amount) private {
        require(_amount > 0, "Vester: invalid _amount");

        _updateVesting(_account);

        IERC20(esToken).safeTransferFrom(_account, address(this), _amount);

        _mint(_account, _amount);

        if (hasPairToken()) {
            uint256 pairAmount = pairAmounts[_account];
            uint256 nextPairAmount = getPairAmount(_account, balances[_account]);
            if (nextPairAmount > pairAmount) {
                uint256 pairAmountDiff = nextPairAmount.sub(pairAmount);
                IERC20(pairToken).safeTransferFrom(_account, address(this), pairAmountDiff);
                _mintPair(_account, pairAmountDiff);
            }
        }

        if (hasMaxVestableAmount) {
            uint256 maxAmount = getMaxVestableAmount(_account);
            require(getTotalVested(_account) <= maxAmount, "Vester: max vestable amount exceeded");
        }

        emit Deposit(_account, _amount);
    }

    function _updateVesting(address _account) private {
        // 꺼낼 수 있는 양
        uint256 amount = _getNextClaimableAmount(_account);
        // 마지막 작업시간 최신화
        lastVestingTimes[_account] = block.timestamp;

        if (amount == 0) {
            return;
        }

        // transfer claimableAmount from balances to cumulativeClaimAmounts
        // 꺼낼 수 있는 양만큼 태우고 cumulativeClaimAmounts(실제 GMX)에 기록
        _burn(_account, amount);
        cumulativeClaimAmounts[_account] = cumulativeClaimAmounts[_account].add(amount);
        // esGMX 태우기
        IMintable(esToken).burn(address(this), amount);
    }

    function _getNextClaimableAmount(address _account) private view returns (uint256) {
        // 지난 동작으로부터 얼마나 지났는지
        uint256 timeDiff = block.timestamp.sub(lastVestingTimes[_account]);

        // 유저의 vesting 잔고 (담겨있는 양)
        uint256 balance = balances[_account];
        if (balance == 0) { return 0; }

        // 유저의 총량 = vesting한 양 + 꺼낼 수 있는 양
        uint256 vestedAmount = getVestedAmount(_account);
        // 꺼낼 수 있는 양 = 유저의 총량 * (마지막 동작으로부터 얼마나 지났는지 / 총 vesting 기간) 
        uint256 claimableAmount = vestedAmount.mul(timeDiff).div(vestingDuration);

        // 꺼낼 수 있는 양은 잔고이내여야한다
        if (claimableAmount < balance) {
            return claimableAmount;
        }

        return balance;
    }

    function _claim(address _account, address _receiver) private returns (uint256) {
        // vesting 기록 최신화
        _updateVesting(_account);
        // 받을 수 있는 GMX양
        uint256 amount = claimable(_account);
        // 받은 GMX양 += 받을 수 있는 GMX양
        claimedAmounts[_account] = claimedAmounts[_account].add(amount);
        // GMX 전송
        IERC20(claimableToken).safeTransfer(_receiver, amount);
        emit Claim(_account, amount);
        return amount;
    }

    function _validateHandler() private view {
        require(isHandler[msg.sender], "Vester: forbidden");
    }
}