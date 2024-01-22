// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import "./interfaces/IRouter.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IPositionRouter.sol";
import "./interfaces/IPositionRouterCallbackReceiver.sol";

import "../libraries/utils/Address.sol";
import "./BasePositionManager.sol";

// createIncreasePosition, createDecreasePosition 주로 사용
contract PositionRouter is BasePositionManager, IPositionRouter {
    using Address for address;

    struct IncreasePositionRequest {
        address account;
        address[] path;
        address indexToken;
        uint256 amountIn;
        uint256 minOut;
        uint256 sizeDelta;
        bool isLong;
        uint256 acceptablePrice;
        uint256 executionFee;
        uint256 blockNumber;
        uint256 blockTime;
        bool hasCollateralInETH;
        address callbackTarget;
    }

    struct DecreasePositionRequest {
        address account;
        address[] path;
        address indexToken;
        uint256 collateralDelta;
        uint256 sizeDelta;
        bool isLong;
        address receiver;
        uint256 acceptablePrice;
        uint256 minOut;
        uint256 executionFee;
        uint256 blockNumber;
        uint256 blockTime;
        bool withdrawETH;
        address callbackTarget;
    }

    uint256 public minExecutionFee;

    uint256 public minBlockDelayKeeper;
    uint256 public minTimeDelayPublic;
    uint256 public maxTimeDelay;

    bool public isLeverageEnabled = true;

    bytes32[] public override increasePositionRequestKeys;
    bytes32[] public override decreasePositionRequestKeys;

    uint256 public override increasePositionRequestKeysStart;
    uint256 public override decreasePositionRequestKeysStart;

    uint256 public callbackGasLimit;
    mapping (address => uint256) public customCallbackGasLimits;

    mapping (address => bool) public isPositionKeeper;

    mapping (address => uint256) public increasePositionsIndex;
    mapping (bytes32 => IncreasePositionRequest) public increasePositionRequests;

    mapping (address => uint256) public decreasePositionsIndex;
    mapping (bytes32 => DecreasePositionRequest) public decreasePositionRequests;

    event CreateIncreasePosition(
        address indexed account,
        address[] path,
        address indexToken,
        uint256 amountIn,
        uint256 minOut,
        uint256 sizeDelta,
        bool isLong,
        uint256 acceptablePrice,
        uint256 executionFee,
        uint256 index,
        uint256 queueIndex,
        uint256 blockNumber,
        uint256 blockTime,
        uint256 gasPrice
    );

    event ExecuteIncreasePosition(
        address indexed account,
        address[] path,
        address indexToken,
        uint256 amountIn,
        uint256 minOut,
        uint256 sizeDelta,
        bool isLong,
        uint256 acceptablePrice,
        uint256 executionFee,
        uint256 blockGap,
        uint256 timeGap
    );

    event CancelIncreasePosition(
        address indexed account,
        address[] path,
        address indexToken,
        uint256 amountIn,
        uint256 minOut,
        uint256 sizeDelta,
        bool isLong,
        uint256 acceptablePrice,
        uint256 executionFee,
        uint256 blockGap,
        uint256 timeGap
    );

    event CreateDecreasePosition(
        address indexed account,
        address[] path,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        address receiver,
        uint256 acceptablePrice,
        uint256 minOut,
        uint256 executionFee,
        uint256 index,
        uint256 queueIndex,
        uint256 blockNumber,
        uint256 blockTime
    );

    event ExecuteDecreasePosition(
        address indexed account,
        address[] path,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        address receiver,
        uint256 acceptablePrice,
        uint256 minOut,
        uint256 executionFee,
        uint256 blockGap,
        uint256 timeGap
    );

    event CancelDecreasePosition(
        address indexed account,
        address[] path,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        address receiver,
        uint256 acceptablePrice,
        uint256 minOut,
        uint256 executionFee,
        uint256 blockGap,
        uint256 timeGap
    );

    event SetPositionKeeper(address indexed account, bool isActive);
    event SetMinExecutionFee(uint256 minExecutionFee);
    event SetIsLeverageEnabled(bool isLeverageEnabled);
    event SetDelayValues(uint256 minBlockDelayKeeper, uint256 minTimeDelayPublic, uint256 maxTimeDelay);
    event SetRequestKeysStartValues(uint256 increasePositionRequestKeysStart, uint256 decreasePositionRequestKeysStart);
    event SetCallbackGasLimit(uint256 callbackGasLimit);
    event SetCustomCallbackGasLimit(address callbackTarget, uint256 callbackGasLimit);
    event Callback(address callbackTarget, bool success, uint256 callbackGasLimit);

    modifier onlyPositionKeeper() {
        require(isPositionKeeper[msg.sender], "403");
        _;
    }

    constructor(
        address _vault,
        address _router,
        address _weth,
        address _shortsTracker,
        uint256 _depositFee,
        uint256 _minExecutionFee
    ) public BasePositionManager(_vault, _router, _shortsTracker, _weth, _depositFee) {
        minExecutionFee = _minExecutionFee;
    }

    function setPositionKeeper(address _account, bool _isActive) external onlyAdmin {
        isPositionKeeper[_account] = _isActive;
        emit SetPositionKeeper(_account, _isActive);
    }

    function setCallbackGasLimit(uint256 _callbackGasLimit) external onlyAdmin {
        callbackGasLimit = _callbackGasLimit;
        emit SetCallbackGasLimit(_callbackGasLimit);
    }

    function setCustomCallbackGasLimit(address _callbackTarget, uint256 _callbackGasLimit) external onlyAdmin {
        customCallbackGasLimits[_callbackTarget] = _callbackGasLimit;
        emit SetCustomCallbackGasLimit(_callbackTarget, _callbackGasLimit);
    }

    function setMinExecutionFee(uint256 _minExecutionFee) external onlyAdmin {
        minExecutionFee = _minExecutionFee;
        emit SetMinExecutionFee(_minExecutionFee);
    }

    function setIsLeverageEnabled(bool _isLeverageEnabled) external onlyAdmin {
        isLeverageEnabled = _isLeverageEnabled;
        emit SetIsLeverageEnabled(_isLeverageEnabled);
    }

    function setDelayValues(uint256 _minBlockDelayKeeper, uint256 _minTimeDelayPublic, uint256 _maxTimeDelay) external onlyAdmin {
        minBlockDelayKeeper = _minBlockDelayKeeper;
        minTimeDelayPublic = _minTimeDelayPublic;
        maxTimeDelay = _maxTimeDelay;
        emit SetDelayValues(_minBlockDelayKeeper, _minTimeDelayPublic, _maxTimeDelay);
    }

    function setRequestKeysStartValues(uint256 _increasePositionRequestKeysStart, uint256 _decreasePositionRequestKeysStart) external onlyAdmin {
        increasePositionRequestKeysStart = _increasePositionRequestKeysStart;
        decreasePositionRequestKeysStart = _decreasePositionRequestKeysStart;

        emit SetRequestKeysStartValues(_increasePositionRequestKeysStart, _decreasePositionRequestKeysStart);
    }
    
    /**
     * @dev     시작 인덱스부터 종료 인덱스까지 포지션 크기 확장 실행 (키퍼만 실행 가능)
     * @param   _endIndex  .
     * @param   _executionFeeReceiver .
     */
    function executeIncreasePositions(uint256 _endIndex, address payable _executionFeeReceiver) external override onlyPositionKeeper {
        // 아직 실행되지 않은 request들 중 첫 번째 index
        uint256 index = increasePositionRequestKeysStart;
        uint256 length = increasePositionRequestKeys.length;

        // request 배열 읽기 시작 index가 배열 크기보다 크다면 종료
        if (index >= length) { return; }

        // 종료 인덱스가 배열 크기보다 크면
        // 배열의 크기로 종료 인덱스 변경
        if (_endIndex > length) {
            _endIndex = length;
        }

        // 시작 인덱스 ~ 종료 인덱스까지 request 실행 반복
        while (index < _endIndex) {
            bytes32 key = increasePositionRequestKeys[index];

            // position request 실행 요청
            try this.executeIncreasePosition(key, _executionFeeReceiver) returns (bool _wasExecuted) {
                if (!_wasExecuted) { break; }
            } catch {
                // 실행 실패시 request 내용 삭제하기
                try this.cancelIncreasePosition(key, _executionFeeReceiver) returns (bool _wasCancelled) {
                    if (!_wasCancelled) { break; }
                } catch {}
            }

            // request 인덱스 삭제
            delete increasePositionRequestKeys[index];
            index++;
        }

        increasePositionRequestKeysStart = index;
    }

    /**
     * @dev     시작 인덱스부터 종료 인덱스까지 포지션 크기 축소 (키퍼만 가능)
     * @param   _endIndex  .
     * @param   _executionFeeReceiver  .
     */
    function executeDecreasePositions(uint256 _endIndex, address payable _executionFeeReceiver) external override onlyPositionKeeper {
        uint256 index = decreasePositionRequestKeysStart;
        uint256 length = decreasePositionRequestKeys.length;

        if (index >= length) { return; }

        if (_endIndex > length) {
            _endIndex = length;
        }

        while (index < _endIndex) {
            bytes32 key = decreasePositionRequestKeys[index];

            // if the request was executed then delete the key from the array
            // if the request was not executed then break from the loop, this can happen if the
            // minimum number of blocks has not yet passed
            // an error could be thrown if the request is too old
            // in case an error was thrown, cancel the request
            try this.executeDecreasePosition(key, _executionFeeReceiver) returns (bool _wasExecuted) {
                if (!_wasExecuted) { break; }
            } catch {
                // wrap this call in a try catch to prevent invalid cancels from blocking the loop
                try this.cancelDecreasePosition(key, _executionFeeReceiver) returns (bool _wasCancelled) {
                    if (!_wasCancelled) { break; }
                } catch {}
            }

            delete decreasePositionRequestKeys[index];
            index++;
        }

        decreasePositionRequestKeysStart = index;
    }

    function createIncreasePosition(
        address[] memory _path,
        address _indexToken,
        uint256 _amountIn,
        uint256 _minOut,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _acceptablePrice,
        uint256 _executionFee,
        address _callbackTarget
    ) external payable nonReentrant returns (bytes32) {
        // 요청 실행 수수료가 최소 실행 수수료보다 커야함
        require(_executionFee >= minExecutionFee, "fee");
        // 함수를 실행하면서 넣은 ETH가 요청 실행 수수료 값과 동일한지 체크 
        require(msg.value == _executionFee, "val");
        // A -> B 또는 A -> B
        require(_path.length == 1 || _path.length == 2, "len");

        // ETH를 WETH로 변환
        _transferInETH();

        // 등록한 Router에서 Position Router로 A 토큰 전송
        if (_amountIn > 0) {
            IRouter(router).pluginTransfer(_path[0], msg.sender, address(this), _amountIn);
        }

        return _createIncreasePosition(
            msg.sender,
            _path,
            _indexToken,
            _amountIn,
            _minOut,
            _sizeDelta,
            _isLong,
            _acceptablePrice,
            _executionFee,
            false,
            _callbackTarget
        );
    }

    function createIncreasePositionETH(
        address[] memory _path,
        address _indexToken,
        uint256 _minOut,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _acceptablePrice,
        uint256 _executionFee,
        address _callbackTarget
    ) external payable nonReentrant returns (bytes32) {
        // 실행 수수료는 최소 실행 수수료보다 커야한다
        require(_executionFee >= minExecutionFee, "fee");
        // 실행 수수료만큼 ETH를 넣어야한다(다른 사람이 해당 포지션 관련 트랜잭션을 실행 수수료를 받고 자발적으로 실행시켜야하기 때문)
        require(msg.value >= _executionFee, "val");
        // swap은 A -> B, A -> B -> C만 가능
        require(_path.length == 1 || _path.length == 2, "len");
        // A가 WETH라면 ETH를 WETH로 바꾸고 레퍼럴 코드를 설정한다
        require(_path[0] == weth, "path");
        // msg.value 이더 WETH로 전환
        _transferInETH();
        // 수수료를 제외한 ETH의 양 계산
        uint256 amountIn = msg.value.sub(_executionFee);

        // 포지션 확장 요청 등록
        return _createIncreasePosition(
            msg.sender,
            _path,
            _indexToken,
            amountIn,
            _minOut,
            _sizeDelta,
            _isLong,
            _acceptablePrice,
            _executionFee,
            true,
            _callbackTarget
        );
    }

    function createDecreasePosition(
        address[] memory _path,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver,
        uint256 _acceptablePrice,
        uint256 _minOut,
        uint256 _executionFee,
        bool _withdrawETH,
        address _callbackTarget
    ) external payable nonReentrant returns (bytes32) {
        // 실행 수수료는 최소
        require(_executionFee >= minExecutionFee, "fee");
        // 실행 수수료만큼 ETH를 넣어야한다(다른 사람이 해당 포지션 관련 트랜잭션을 실행 수수료를 받고 자발적으로 실행시켜야하기 때문)
        require(msg.value == _executionFee, "val");
        // swap은 A -> B, A -> B -> C만 가능
        require(_path.length == 1 || _path.length == 2, "len");
        // ETH로 받고 싶은 경우 C가 WETH로 설정되어있어야한다
        if (_withdrawETH) {
            require(_path[_path.length - 1] == weth, "path");
        }
        // msg.value 이더 WETH로 전환
        _transferInETH();

        // 포지션 축소 요청 등록
        return _createDecreasePosition(
            msg.sender,
            _path,
            _indexToken,
            _collateralDelta,
            _sizeDelta,
            _isLong,
            _receiver,
            _acceptablePrice,
            _minOut,
            _executionFee,
            _withdrawETH,
            _callbackTarget
        );
    }

    function getRequestQueueLengths() external view override returns (uint256, uint256, uint256, uint256) {
        return (
            increasePositionRequestKeysStart,
            increasePositionRequestKeys.length,
            decreasePositionRequestKeysStart,
            decreasePositionRequestKeys.length
        );
    }

    function executeIncreasePosition(bytes32 _key, address payable _executionFeeReceiver) public nonReentrant returns (bool) {
        IncreasePositionRequest memory request = increasePositionRequests[_key];
        // if the request was already executed or cancelled, return true so that the executeIncreasePositions loop will continue executing the next request
        if (request.account == address(0)) { return true; }
        // executeIncreasePositions에서 실행되었는지, keeper가 실행시켰는지
        bool shouldExecute = _validateExecution(request.blockNumber, request.blockTime, request.account);
        if (!shouldExecute) { return false; }

        delete increasePositionRequests[_key];

        if (request.amountIn > 0) {
            uint256 amountIn = request.amountIn;

            // A -> B -> C 과정이라면 
            if (request.path.length > 1) {
                IERC20(request.path[0]).safeTransfer(vault, request.amountIn);
                // A -> B -> C swap을 실제로 실행 
                amountIn = _swap(request.path, request.minOut, address(this));
            }
            // depositFee를 제외한 토큰의 양
            uint256 afterFeeAmount = _collectFees(request.account, request.path, amountIn, request.indexToken, request.isLong, request.sizeDelta);
            // depositFee를 제외한 C 토큰 vault로 전송
            IERC20(request.path[request.path.length - 1]).safeTransfer(vault, afterFeeAmount);
        }

        // position router가 지정한 router의 pluginIncreasePosition 실행 -> router가 지정한 vault의 increasePosition 실행
        _increasePosition(request.account, request.path[request.path.length - 1], request.indexToken, request.sizeDelta, request.isLong, request.acceptablePrice);
        // 트랜잭션 실행 수수료를 WETH를 ETH로 변환하여 Receiver에게 전송
        _transferOutETHWithGasLimitFallbackToWeth(request.executionFee, _executionFeeReceiver);
        emit ExecuteIncreasePosition(
            request.account,
            request.path,
            request.indexToken,
            request.amountIn,
            request.minOut,
            request.sizeDelta,
            request.isLong,
            request.acceptablePrice,
            request.executionFee,
            block.number.sub(request.blockNumber),
            block.timestamp.sub(request.blockTime)
        );

        // 원할 경우 callbackTarget 컨트랙트에 _key를 msg.data로 하여 call할 수 있도록 함
        _callRequestCallback(request.callbackTarget, _key, true, true);

        return true;
    }

    function cancelIncreasePosition(bytes32 _key, address payable _executionFeeReceiver) public nonReentrant returns (bool) {
        // IncreasePositionRequest 데이터 가져와서 확인 시 account가 0인 경우 데이터가 없는 것이므로 종료 
        IncreasePositionRequest memory request = increasePositionRequests[_key];
        if (request.account == address(0)) { return true; }

        // executeIncreasePositions에서 실행되었는지, keeper가 실행시켰는지
        bool shouldCancel = _validateCancellation(request.blockNumber, request.blockTime, request.account);
        // 해당하지 않는다면 실패로 처리
        if (!shouldCancel) { return false; }

        // 저장되어있던 position request 삭제
        delete increasePositionRequests[_key];

        // WETH 담보가 있었다면
        if (request.hasCollateralInETH) {
            // ETH로 변환하여 account로 전송
            _transferOutETHWithGasLimitFallbackToWeth(request.amountIn, payable(request.account));
        } else {
            // 토큰이라면 A토큰으로 account에게 전송
            IERC20(request.path[0]).safeTransfer(request.account, request.amountIn);
        }

        // 트랜잭션 실행자에게 실행 수수료 전달
        _transferOutETHWithGasLimitFallbackToWeth(request.executionFee, _executionFeeReceiver);

        emit CancelIncreasePosition(
            request.account,
            request.path,
            request.indexToken,
            request.amountIn,
            request.minOut,
            request.sizeDelta,
            request.isLong,
            request.acceptablePrice,
            request.executionFee,
            block.number.sub(request.blockNumber),
            block.timestamp.sub(request.blockTime)
        );

        // 콜백이 있다면 콜백 실행
        _callRequestCallback(request.callbackTarget, _key, false, true);

        return true;
    }

    function executeDecreasePosition(bytes32 _key, address payable _executionFeeReceiver) public nonReentrant returns (bool) {
        // 요청 데이터 가져오기
        DecreasePositionRequest memory request = decreasePositionRequests[_key];
        // 주소가 0이라면, 즉 요청 데이터가 비어있다면 종료
        if (request.account == address(0)) { return true; }
        // executeDecreasePositions에서 실행되었는지, keeper가 실행시켰는지
        bool shouldExecute = _validateExecution(request.blockNumber, request.blockTime, request.account);
        // 해당하지않는다면 실패로 처리
        if (!shouldExecute) { return false; }
        // 요청 데이터 삭제
        delete decreasePositionRequests[_key];

        // position router가 지정한 router의 pluginDecreasePosition 실행 -> router가 지정한 vault의 decreasePosition 실행
        uint256 amountOut = _decreasePosition(request.account, request.path[0], request.indexToken, request.collateralDelta, request.sizeDelta, request.isLong, address(this), request.acceptablePrice);

        // 포지션을 감소시켰을 때
        if (amountOut > 0) {
            // A -> B나 A -> B -> C swap을 실제로 실행
            if (request.path.length > 1) {
                IERC20(request.path[0]).safeTransfer(vault, amountOut);
                amountOut = _swap(request.path, request.minOut, address(this));
            }

            // 요청이 ETH로 받는 것을 바란다면
            if (request.withdrawETH) {
                // WETH를 ETH로 변경하여 전달
                _transferOutETHWithGasLimitFallbackToWeth(amountOut, payable(request.receiver));
            } else {
                // 아니라면 토큰을 전달
                IERC20(request.path[request.path.length - 1]).safeTransfer(request.receiver, amountOut);
            }
        }

        // 트랜잭션 실행 수수료 실행자에게 전달
        _transferOutETHWithGasLimitFallbackToWeth(request.executionFee, _executionFeeReceiver);

        emit ExecuteDecreasePosition(
            request.account,
            request.path,
            request.indexToken,
            request.collateralDelta,
            request.sizeDelta,
            request.isLong,
            request.receiver,
            request.acceptablePrice,
            request.minOut,
            request.executionFee,
            block.number.sub(request.blockNumber),
            block.timestamp.sub(request.blockTime)
        );

        // 콜백이 있다면 콜백 실행
        _callRequestCallback(request.callbackTarget, _key, true, false);

        return true;
    }

    function cancelDecreasePosition(bytes32 _key, address payable _executionFeeReceiver) public nonReentrant returns (bool) {
        // 요청 가져오기
        DecreasePositionRequest memory request = decreasePositionRequests[_key];
        // 요청이 비어있다면 종료
        if (request.account == address(0)) { return true; }
        // executeDecreasePositions에서 실행되었는지, keeper가 실행시켰는지
        bool shouldCancel = _validateCancellation(request.blockNumber, request.blockTime, request.account);
        if (!shouldCancel) { return false; }

        delete decreasePositionRequests[_key];

       _transferOutETHWithGasLimitFallbackToWeth(request.executionFee, _executionFeeReceiver);

        emit CancelDecreasePosition(
            request.account,
            request.path,
            request.indexToken,
            request.collateralDelta,
            request.sizeDelta,
            request.isLong,
            request.receiver,
            request.acceptablePrice,
            request.minOut,
            request.executionFee,
            block.number.sub(request.blockNumber),
            block.timestamp.sub(request.blockTime)
        );

        _callRequestCallback(request.callbackTarget, _key, false, false);

        return true;
    }

    function getRequestKey(address _account, uint256 _index) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_account, _index));
    }

    function getIncreasePositionRequestPath(bytes32 _key) public view override returns (address[] memory) {
        IncreasePositionRequest memory request = increasePositionRequests[_key];
        return request.path;
    }

    function getDecreasePositionRequestPath(bytes32 _key) public view override returns (address[] memory) {
        DecreasePositionRequest memory request = decreasePositionRequests[_key];
        return request.path;
    }

    function _validateExecution(uint256 _positionBlockNumber, uint256 _positionBlockTime, address _account) internal view returns (bool) {
        if (_positionBlockTime.add(maxTimeDelay) <= block.timestamp) {
            revert("expired");
        }

        return _validateExecutionOrCancellation(_positionBlockNumber, _positionBlockTime, _account);
    }

    function _validateCancellation(uint256 _positionBlockNumber, uint256 _positionBlockTime, address _account) internal view returns (bool) {
        return _validateExecutionOrCancellation(_positionBlockNumber, _positionBlockTime, _account);
    }

    function _validateExecutionOrCancellation(uint256 _positionBlockNumber, uint256 _positionBlockTime, address _account) internal view returns (bool) {
        // 등록된 포지션 키퍼가 실행시켰거나, 스마트 컨트랙트 내부(executeIncreasePositions)에서 함수를 호출한 거라면 OK
        bool isKeeperCall = msg.sender == address(this) || isPositionKeeper[msg.sender];

        // in/decreasePosition을 하는 상황이 아니고, 포지션 키퍼가 실행한게 아니라면 revert
        if (!isLeverageEnabled && !isKeeperCall) {
            revert("403");
        }

        // 키퍼가 실행한게 맞다면
        if (isKeeperCall) {
            // 실행 블록 쿨다운이 끝난 이후 실행했다면 validate
            return _positionBlockNumber.add(minBlockDelayKeeper) <= block.number;
        }

        // 인수의 account는 키퍼의 주소면 안됨
        require(msg.sender == _account, "403");
        // 실행 시간 쿨다운이 끝나기 전에 실행했는지 체크 
        require(_positionBlockTime.add(minTimeDelayPublic) <= block.timestamp, "delay");

        return true;
    }

    function _createIncreasePosition(
        address _account,
        address[] memory _path,
        address _indexToken,
        uint256 _amountIn,
        uint256 _minOut,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _acceptablePrice,
        uint256 _executionFee,
        bool _hasCollateralInETH,
        address _callbackTarget
    ) internal returns (bytes32) {
        // 요청 생성
        IncreasePositionRequest memory request = IncreasePositionRequest(
            _account,
            _path,
            _indexToken,
            _amountIn,
            _minOut,
            _sizeDelta,
            _isLong,
            _acceptablePrice,
            _executionFee,
            block.number,
            block.timestamp,
            _hasCollateralInETH,
            _callbackTarget
        );

        // 요청 저장
        (uint256 index, bytes32 requestKey) = _storeIncreasePositionRequest(request);
        emit CreateIncreasePosition(
            _account,
            _path,
            _indexToken,
            _amountIn,
            _minOut,
            _sizeDelta,
            _isLong,
            _acceptablePrice,
            _executionFee,
            index,
            increasePositionRequestKeys.length - 1,
            block.number,
            block.timestamp,
            tx.gasprice
        );

        return requestKey;
    }

    /**
     * @dev     position request 매핑
     * @param   _request  .
     * @return  uint256  .
     * @return  bytes32  .
     */
    function _storeIncreasePositionRequest(IncreasePositionRequest memory _request) internal returns (uint256, bytes32) {
        address account = _request.account;
        uint256 index = increasePositionsIndex[account].add(1);
        increasePositionsIndex[account] = index;
        bytes32 key = getRequestKey(account, index);

        increasePositionRequests[key] = _request;
        increasePositionRequestKeys.push(key);

        return (index, key);
    }

    /**
     * @dev     position request 매핑
     * @param   _request  .
     * @return  uint256  .
     * @return  bytes32  .
     */
    function _storeDecreasePositionRequest(DecreasePositionRequest memory _request) internal returns (uint256, bytes32) {
        address account = _request.account;
        // position request 매핑 과정
        uint256 index = decreasePositionsIndex[account].add(1);
        decreasePositionsIndex[account] = index;
        // keccak256(abi.encodePacked(_account, _index))
        bytes32 key = getRequestKey(account, index);

        decreasePositionRequests[key] = _request;
        decreasePositionRequestKeys.push(key);

        return (index, key);
    }

    function _createDecreasePosition(
        address _account,
        address[] memory _path,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver,
        uint256 _acceptablePrice,
        uint256 _minOut,
        uint256 _executionFee,
        bool _withdrawETH,
        address _callbackTarget
    ) internal returns (bytes32) {
        // 포지션 축소 요청 생성
        DecreasePositionRequest memory request = DecreasePositionRequest(
            _account,
            _path,
            _indexToken,
            _collateralDelta,
            _sizeDelta,
            _isLong,
            _receiver,
            _acceptablePrice,
            _minOut,
            _executionFee,
            block.number,
            block.timestamp,
            _withdrawETH,
            _callbackTarget
        );

        // 포지션 축소 요청 등록
        (uint256 index, bytes32 requestKey) = _storeDecreasePositionRequest(request);
        emit CreateDecreasePosition(
            request.account,
            request.path,
            request.indexToken,
            request.collateralDelta,
            request.sizeDelta,
            request.isLong,
            request.receiver,
            request.acceptablePrice,
            request.minOut,
            request.executionFee,
            index,
            decreasePositionRequestKeys.length - 1,
            block.number,
            block.timestamp
        );
        return requestKey;
    }

    function _callRequestCallback(
        address _callbackTarget,
        bytes32 _key,
        bool _wasExecuted,
        bool _isIncrease
    ) internal {
        // 주소가 0이라면 종료
        if (_callbackTarget == address(0)) {
            return;
        }

        // 주소가 컨트랙트가 아니라면 종료
        if (!_callbackTarget.isContract()) {
            return;
        }

        uint256 _gasLimit = callbackGasLimit;
        // 콜백 컨트랙트가 지정한 가스 제한량이 있다면 사용
        uint256 _customCallbackGasLimit = customCallbackGasLimits[_callbackTarget];

        // 콜백 컨트랙트 가스 제한량이 정해진 가스 제한량보다 크다면
        if (_customCallbackGasLimit > _gasLimit) {
            // 콜백 컨트랙트 가스 제한량을 사용
            _gasLimit = _customCallbackGasLimit;
        }

        // 가스제한이 0이라면 종료
        if (_gasLimit == 0) {
            return;
        }

        // 콜백 실행
        bool success;
        try IPositionRouterCallbackReceiver(_callbackTarget).gmxPositionCallback{ gas: _gasLimit }(_key, _wasExecuted, _isIncrease) {
            success = true;
        } catch {}

        emit Callback(_callbackTarget, success, _gasLimit);
    }
}