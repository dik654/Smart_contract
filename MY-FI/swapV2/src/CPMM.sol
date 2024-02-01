// SPDX-License-Identifier: GLP v3.0
pragma solidity ^0.8.19;

import './interfaces/ICPMM.sol';
import "./interfaces/IERC20.sol";
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import "./utils/ERC20.sol";
import "./utils/ReentrancyGuard.sol";

contract CPMM is ReentrancyGuard, ICPMM, ERC20 {
    using UQ112x112 for uint224;

    uint256 public constant MINIMUM_LIQUIDITY = 10**3;

    uint112 private reserve0;
    uint112 private reserve1;
    uint32  private blockTimestampLast;

    address public factory;
    address public token0;
    address public token1;

    uint public price0CumulativeLast;
    uint public price1CumulativeLast;

    constructor() ERC20("CPMM", "CPMM"){
        factory = msg.sender;
    }

    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, "intialize: ONLY_FACTORY");
        token0 = _token0;
        token1 = _token1;
    }

    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function _update(uint256 _balance0, uint256 _balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(_balance0 <= type(uint112).max && _balance1 <= type(uint112).max, 'UniswapV2: OVERFLOW');
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast;
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;            
        }
        reserve0 = uint112(_balance0);
        reserve1 = uint112(_balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    function mint(address _to, uint256 _amount0, uint256 _amount1) external nonReentrant returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        IERC20(token0).transferFrom(tx.origin, address(this), _amount0);
        IERC20(token1).transferFrom(tx.origin, address(this), _amount1);

        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(_amount0 * _amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            liquidity = Math.min(_amount0 * _totalSupply / _reserve0, _amount0 * _totalSupply / _reserve1);
        }
        require(liquidity > 0, 'MINT:INSUFFICIENT_LIQUIDITY_MINTED');
        _mint(_to, liquidity);

        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), _reserve0, _reserve1);
        emit Mint(msg.sender, _amount0, _amount1);
    }

    function burn(address _to, uint256 amount) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        (bool success)= transferFrom(tx.origin, address(this), amount);
        require(success, "BURN:LIQUIDITY_INSERT_FAILED");
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        uint256 _totalSupply = totalSupply();
        amount0 = amount * balance0 / _totalSupply; 
        amount1 = amount * balance1 / _totalSupply;
        require(amount0 > 0 && amount1 > 0, 'BURN:INSUFFICIENT_LIQUIDITY_BURNED');
        _burn(address(this), amount);
        IERC20(token0).transfer(_to, amount0);
        IERC20(token0).transfer(_to, amount1);

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Burn(msg.sender, amount0, amount1, _to);
    }

    function swap(uint256 _amount0Out, uint256 _amount1Out, address _to, bytes calldata _data) external nonReentrant {
        require(_amount0Out > 0 || _amount1Out > 0, 'SWAP:INSUFFICIENT_OUTPUT_AMOUNT');
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        require(_amount0Out < _reserve0 && _amount1Out < _reserve1, 'SWAP:INSUFFICIENT_LIQUIDITY');
        
        uint256 balance0;
        uint256 balance1;
        {
            address _token0 = token0;
            address _token1 = token1;
            require(_to != _token0 && _to != _token1, 'SWAP:INVALID_TO');
            if (_amount0Out > 0) IERC20(_token0).transfer(_to, _amount0Out);
            if (_amount1Out > 0) IERC20(_token1).transfer(_to, _amount1Out);
            // if (data.length > 0) IFlashloan(_to).execute(msg.sender, _amount0Out, _amount1Out, _data);
            balance0 = IERC20(_token0).balanceOf(address(this));
            balance1 = IERC20(_token1).balanceOf(address(this));
        }
        uint256 amount0In = balance0 > _reserve0 - _amount0Out ? balance0 - (_reserve0 - _amount0Out) : 0;
        uint256 amount1In = balance1 > _reserve1 - _amount1Out ? balance1 - (_reserve1 - _amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'SWAP:INSUFFICIENT_INPUT_AMOUNT');
        { 
            uint256 balance0Adjusted = balance0 * 1000 - (amount0In * 3);
            uint256 balance1Adjusted = balance1 * 1000 - (amount1In * 3);
            require(balance0Adjusted * balance1Adjusted >= uint256(_reserve0) * _reserve1 * 1000**2, 'SWAP: ADJUSTED_K');
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, _amount0Out, _amount1Out, _to);
    }

    function skim(address _to) external nonReentrant {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        IERC20(_token0).transfer(_to, IERC20(_token0).balanceOf(address(this)) - reserve0);
        IERC20(_token1).transfer(_to, IERC20(_token1).balanceOf(address(this)) - reserve1);
    }

    function sync() external nonReentrant {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
