// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IUniswapV3Pool.sol";
import "./interfaces/ISwapRouter.sol";
import "./libraries/LiquidityAmounts.sol";
import "./libraries/TickMath.sol";

interface IQuoter {
    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountOut);
}

contract UniV3Rebalancer is AutomationCompatibleInterface, ERC4626 {
    using SafeERC20 for IERC20;

    uint256 public lastRebalance;

    uint256 public immutable REBALANCE_PERCENTAGE;
    IUniswapV3Pool public immutable POOL;
    ISwapRouter public immutable SWAP_ROUTER;
    IQuoter public immutable QUOTER;
    IERC20 public immutable TOKEN0;
    IERC20 public immutable TOKEN1;

    uint256 private constant MIN_REBALANCE_FREQUENCY = 10 minutes;
    int24 private constant ALLOWED_TICK_DIFFERENCE = 5;

    int24 _currentLowerTick;
    int24 _currentUpperTick;

    address _protocol;
    uint256 _protocolT0;
    uint256 _protocolT1;
    uint8 _protocolFee = 5; // 0.5%

    event Rebalanced(
        int24 newLowerTick,
        int24 newUpperTick,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    constructor(
        string memory _name,
        string memory _symbol,
        IERC20 _asset,
        address _pool,
        address _swapRouter,
        address _quoter,
        uint256 _rebalancePercentage,
        address __protocol
    ) ERC4626(_asset) ERC20(_name, _symbol) {
        require(
            _rebalancePercentage > 0 && _rebalancePercentage < 1000,
            "Invalid rebalance percentage"
        );
        POOL = IUniswapV3Pool(_pool);
        SWAP_ROUTER = ISwapRouter(_swapRouter);
        QUOTER = IQuoter(_quoter);
        TOKEN0 = IERC20(IUniswapV3Pool(_pool).token0());
        TOKEN1 = IERC20(IUniswapV3Pool(_pool).token1());
        REBALANCE_PERCENTAGE = _rebalancePercentage;
        lastRebalance = block.timestamp;
        _protocol = __protocol;

        (, int24 _currentTick, , , , , ) = IUniswapV3Pool(_pool).slot0();
        (_currentLowerTick, _currentUpperTick) = _calculateTicks(_currentTick);
    }

    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata
    ) external {
        require(_msgSender() == address(POOL), "AUTH");

        if (amount0Owed > 0) {
            TOKEN0.safeTransfer(_msgSender(), amount0Owed);
        }
        if (amount1Owed > 0) {
            TOKEN1.safeTransfer(_msgSender(), amount1Owed);
        }
    }

    function totalAssets() public view virtual override returns (uint256) {
        uint128 _liquidity = _currentPosition(_currentLowerTick, _currentUpperTick);
        return uint256(_liquidity);
    }

    function totalToken0Assets() external view returns (uint256) {
        (uint160 _sqrtPriceX96, , , , , , ) = POOL.slot0();
        uint128 _liquidity = _currentPosition(_currentLowerTick, _currentUpperTick);
        (uint256 _amount0, ) = LiquidityAmounts.getAmountsForLiquidity(
            _sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(_currentLowerTick),
            TickMath.getSqrtRatioAtTick(_currentUpperTick),
            _liquidity
        );
        (uint256 _fee0, ) = _getPendingFees();
        return _amount0 + TOKEN0.balanceOf(address(this)) + _fee0 - _protocolT0;
    }

    function totalToken1Assets() external view returns (uint256) {
        (uint160 _sqrtPriceX96, , , , , , ) = POOL.slot0();
        uint128 _liquidity = _currentPosition(_currentLowerTick, _currentUpperTick);
        (, uint256 _amount1) = LiquidityAmounts.getAmountsForLiquidity(
            _sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(_currentLowerTick),
            TickMath.getSqrtRatioAtTick(_currentUpperTick),
            _liquidity
        );
        (, uint256 _fee1) = _getPendingFees();
        return _amount1 + TOKEN1.balanceOf(address(this)) + _fee1 - _protocolT1;
    }

    function currentPosition() external view returns (uint128, int24, int24, uint160, uint160) {
        bytes32 _positionKey = keccak256(
            abi.encodePacked(address(this), _currentLowerTick, _currentUpperTick)
        );
        (uint128 _liquidity, , , , ) = POOL.positions(_positionKey);
        return (
            _liquidity,
            _currentLowerTick,
            _currentUpperTick,
            TickMath.getSqrtRatioAtTick(_currentLowerTick),
            TickMath.getSqrtRatioAtTick(_currentUpperTick)
        );
    }

    function deposit(
        uint256 _liquidity,
        address _receiver
    ) public virtual override returns (uint256 _shares) {
        require(_liquidity > 0, "L");
        _shares = totalSupply() == 0 ? _liquidity : convertToShares(_liquidity);
        _deposit(_msgSender(), _receiver, _liquidity, _shares);
    }

    function redeem(
        uint256 _shares,
        address _receiver,
        address _owner
    ) public virtual override returns (uint256 _liquidity) {
        require(_shares > 0, "Z");

        _liquidity = convertToAssets(_shares);

        if (_msgSender() != _owner) {
            _spendAllowance(_owner, _msgSender(), _shares);
        }

        _withdraw(_msgSender(), _receiver, _owner, _liquidity, _shares);
    }

    function withdraw(
        uint256 _liquidity,
        address _receiver,
        address _owner
    ) public virtual override returns (uint256 _shares) {
        require(_liquidity > 0, "Z");

        _shares = convertToShares(_liquidity);

        if (_msgSender() != _owner) {
            _spendAllowance(_owner, _msgSender(), _shares);
        }

        _withdraw(_msgSender(), _receiver, _owner, _liquidity, _shares);
    }

    function convertToShares(
        uint256 _liquidity
    ) public view virtual override returns (uint256 _shares) {
        uint256 _supply = totalSupply();
        _shares = _supply == 0 ? _liquidity : (_liquidity * _supply) / totalAssets();
    }

    function convertToAssets(
        uint256 _shares
    ) public view virtual override returns (uint256 _assets) {
        uint256 _supply = totalSupply();
        return _supply == 0 ? _shares : (_shares * totalAssets()) / _supply;
    }

    function getLiquidityAndRequiredAmountsFromToken(
        uint256 _inputAmount,
        address _token
    ) external view returns (uint128 _liquidity, uint256 _amount0, uint256 _amount1) {
        require(address(_token) == address(TOKEN0) || address(_token) == address(TOKEN1), "T");
        (uint160 _sqrtPriceX96, int24 _currentTick, , , , , ) = POOL.slot0();
        (int24 _lowerTick, int24 _upperTick) = _calculateTicks(_currentTick);
        _liquidity = _token == address(TOKEN0)
            ? LiquidityAmounts.getLiquidityForAmount0(
                TickMath.getSqrtRatioAtTick(_lowerTick),
                TickMath.getSqrtRatioAtTick(_upperTick),
                _inputAmount
            )
            : LiquidityAmounts.getLiquidityForAmount1(
                TickMath.getSqrtRatioAtTick(_lowerTick),
                TickMath.getSqrtRatioAtTick(_upperTick),
                _inputAmount
            );
        (_amount0, _amount1) = LiquidityAmounts.getAmountsForLiquidity(
            _sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(_lowerTick),
            TickMath.getSqrtRatioAtTick(_upperTick),
            _liquidity
        );
    }

    function _deposit(
        address _caller,
        address _receiver,
        uint256 _liquidity,
        uint256 _shares
    ) internal virtual override {
        // Record initial token balances
        uint256 _initialToken0Balance = TOKEN0.balanceOf(address(this));
        uint256 _initialToken1Balance = TOKEN1.balanceOf(address(this));

        // Rebalance before depositing
        _rebalanceAtCurrentTick();

        (uint160 _sqrtPriceX96, int24 _currentTick, , , , , ) = POOL.slot0();
        (int24 _lowerTick, int24 _upperTick) = _calculateTicks(_currentTick);

        (uint256 _amount0, uint256 _amount1) = LiquidityAmounts.getAmountsForLiquidity(
            _sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(_lowerTick),
            TickMath.getSqrtRatioAtTick(_upperTick),
            uint128(_liquidity)
        );

        if (_caller != address(this)) {
            TOKEN0.safeTransferFrom(_caller, address(this), _amount0);
            TOKEN1.safeTransferFrom(_caller, address(this), _amount1);
        }

        // Add liquidity with assets
        (uint128 _liquidityAdded, , ) = _addLiquidity(
            _currentLowerTick,
            _currentUpperTick,
            _amount0,
            _amount1
        );

        require(_liquidityAdded > 0, "No liquidity added");

        _mint(_receiver, _shares);

        // Optionally refund extra tokens back to _caller
        _refundExtra(_caller, _initialToken0Balance, _initialToken1Balance);

        emit Deposit(_caller, _receiver, _liquidityAdded, _shares);
    }

    function _refundExtra(address _caller, uint256 _initT0Bal, uint256 _initT1Bal) internal {
        if (_caller == address(this)) {
            return;
        }
        // Calculate and refund any leftover tokens
        uint256 _leftoverToken0 = TOKEN0.balanceOf(address(this)) - _initT0Bal;
        uint256 _leftoverToken1 = TOKEN1.balanceOf(address(this)) - _initT1Bal;

        if (_leftoverToken0 > 0) {
            TOKEN0.safeTransfer(_caller, _leftoverToken0);
        }
        if (_leftoverToken1 > 0) {
            TOKEN1.safeTransfer(_caller, _leftoverToken1);
        }
    }

    function _withdraw(
        address _caller,
        address _receiver,
        address _owner,
        uint256 _liquidity,
        uint256 _shares
    ) internal virtual override {
        if (_caller != _owner) {
            _spendAllowance(_owner, _caller, _shares);
        }

        _burn(_owner, _shares);

        _removeLiquidity(uint128(_liquidity), _currentLowerTick, _currentUpperTick);

        uint256 _token0Remaining = TOKEN0.balanceOf(address(this)) - _protocolT0;
        uint256 _token0Refund = (_token0Remaining * (1000 - _protocolFee)) / 1000;
        _protocolT0 += _token0Remaining - _token0Refund;
        if (_token0Refund > 0) {
            TOKEN0.safeTransfer(_receiver, _token0Refund);
        }
        uint256 _token1Remaining = TOKEN1.balanceOf(address(this)) - _protocolT1;
        uint256 _token1Refund = (_token1Remaining * (1000 - _protocolFee)) / 1000;
        _protocolT1 += _token1Remaining - _token1Refund;
        if (_token1Refund > 0) {
            TOKEN1.safeTransfer(_receiver, _token1Refund);
        }

        // Rebalance after withdrawing
        _rebalanceAtCurrentTick();

        emit Withdraw(_caller, _receiver, _owner, _liquidity, _shares);
    }

    function depositFromToken(
        uint256 _assets,
        IERC20 _token
    ) external returns (uint128 _liquidity, uint256 _shares) {
        require(_assets > 0, "Cannot deposit 0 assets");
        require(address(_token) == address(TOKEN0) || address(_token) == address(TOKEN1), "T");

        _token.safeTransferFrom(_msgSender(), address(this), _assets);

        // Always swap half of the incoming token assets
        uint256 _amountToSwap = _token.balanceOf(address(this)) / 2;
        if (_amountToSwap > 0) {
            _swapTokens(_amountToSwap, address(_token) == address(TOKEN0));
        }

        uint256 _amount0 = TOKEN0.balanceOf(address(this));
        uint256 _amount1 = TOKEN1.balanceOf(address(this));

        (uint160 _sqrtPriceX96, int24 _currentTick, , , , , ) = POOL.slot0();
        (int24 _lowerTick, int24 _upperTick) = _calculateTicks(_currentTick);

        _liquidity = LiquidityAmounts.getLiquidityForAmounts(
            _sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(_lowerTick),
            TickMath.getSqrtRatioAtTick(_upperTick),
            _amount0,
            _amount1
        );

        _shares = totalSupply() == 0 ? _liquidity : convertToShares(_liquidity);

        _deposit(address(this), _msgSender(), _liquidity, _shares);

        // Check and refund any remaining assets
        uint256 _remainingToken0 = TOKEN0.balanceOf(address(this));
        uint256 _remainingToken1 = TOKEN1.balanceOf(address(this));

        if (_remainingToken0 > 0) {
            TOKEN0.safeTransfer(_msgSender(), _remainingToken0);
        }
        if (_remainingToken1 > 0) {
            TOKEN1.safeTransfer(_msgSender(), _remainingToken1);
        }
    }

    function _rebalanceAtCurrentTick() internal {
        (, int24 _currentTick, , , , , ) = POOL.slot0();
        _rebalance(_currentTick, _currentTick);
    }

    function checkUpkeep(
        bytes calldata /* checkData */
    ) external view override returns (bool _upkeepNeeded, bytes memory _performData) {
        (_upkeepNeeded, _performData) = _checkUpkeep();
    }

    function _checkUpkeep() internal view returns (bool _upkeepNeeded, bytes memory performData) {
        if (!_enoughTimeElapsed()) {
            return (false, performData);
        }
        uint128 _liquidity = _currentPosition(_currentLowerTick, _currentUpperTick);
        if (_liquidity == 0) {
            return (false, performData);
        }

        (, int24 currentTick, , , , , ) = POOL.slot0();
        _upkeepNeeded = currentTick < _currentLowerTick || currentTick > _currentUpperTick;
        performData = abi.encode(currentTick);
    }

    function performUpkeep(bytes calldata _performData) external override {
        require(_enoughTimeElapsed(), "M");

        (bool _upkeepNeeded, bytes memory _latestData) = _checkUpkeep();
        require(_upkeepNeeded, "Upkeep not needed");

        int24 _providedTick = abi.decode(_performData, (int24));
        int24 _currentTick = abi.decode(_latestData, (int24));
        _rebalance(_providedTick, _currentTick);
    }

    function _enoughTimeElapsed() internal view returns (bool) {
        return block.timestamp > lastRebalance + MIN_REBALANCE_FREQUENCY;
    }

    function _rebalance(int24 _providedTick, int24 _currentTick) internal {
        (int24 _newLowerTick, int24 _newUpperTick) = _calculateTicks(_currentTick);
        if (_currentLowerTick == _newLowerTick) {
            return;
        }

        uint128 _liquidity = _currentPosition(_currentLowerTick, _currentUpperTick);

        if (_liquidity > 0) {
            _removeLiquidity(_liquidity, _currentLowerTick, _currentUpperTick);
        }

        require(_abs(_currentTick - _providedTick) <= ALLOWED_TICK_DIFFERENCE, "D");

        uint256 _amount0 = TOKEN0.balanceOf(address(this));
        uint256 _amount1 = TOKEN1.balanceOf(address(this));

        (uint256 _swapAmount, bool _zeroForOne) = _calculateSwapAmount(_amount0, _amount1);
        if (_swapAmount > 0) {
            _swapTokens(_swapAmount, _zeroForOne);
        }

        _amount0 = TOKEN0.balanceOf(address(this));
        _amount1 = TOKEN1.balanceOf(address(this));
        if (_amount0 == 0 || _amount1 == 0) {
            return;
        }
        (uint128 _newLiquidity, uint256 _addedAmount0, uint256 _addedAmount1) = _addLiquidity(
            _newLowerTick,
            _newUpperTick,
            _amount0,
            _amount1
        );

        _currentLowerTick = _newLowerTick;
        _currentUpperTick = _newUpperTick;
        lastRebalance = block.timestamp;

        emit Rebalanced(_newLowerTick, _newUpperTick, _newLiquidity, _addedAmount0, _addedAmount1);
    }

    function calculateTicks(
        int24 _tick
    ) external view returns (int24 _lowerTick, int24 _upperTick) {
        return _calculateTicks(_tick);
    }

    function protocolCollect() external {
        if (_protocolT0 > 0) {
            TOKEN0.safeTransfer(_protocol, _protocolT0);
            _protocolT0 = 0;
        }
        if (_protocolT1 > 0) {
            TOKEN1.safeTransfer(_protocol, _protocolT1);
            _protocolT1 = 0;
        }
    }

    function _calculateTicks(
        int24 _currentTick
    ) internal view returns (int24 _lowerTick, int24 _upperTick) {
        int24 _tickSpacing = POOL.tickSpacing();
        uint160 _sqrtPriceX96 = TickMath.getSqrtRatioAtTick(_currentTick);
        uint160 _sqrtPriceRangeX96 = uint160((REBALANCE_PERCENTAGE * _sqrtPriceX96) / 1000);
        uint160 _sqrtPriceAX96 = _sqrtPriceX96 - _sqrtPriceRangeX96;
        uint160 _sqrtPriceBX96 = _sqrtPriceX96 + _sqrtPriceRangeX96;

        _lowerTick = TickMath.getTickAtSqrtRatio(_sqrtPriceAX96);
        _lowerTick -= _lowerTick % _tickSpacing;
        _upperTick = TickMath.getTickAtSqrtRatio(_sqrtPriceBX96);
        _upperTick -= _upperTick % _tickSpacing;

        _lowerTick = _lowerTick < TickMath.MIN_TICK ? TickMath.MIN_TICK : _lowerTick;
        _upperTick = _upperTick > TickMath.MAX_TICK ? TickMath.MAX_TICK : _upperTick;
    }

    function _currentPosition(
        int24 _tickLower,
        int24 _tickUpper
    ) internal view returns (uint128 _liquidity) {
        bytes32 _positionKey = keccak256(abi.encodePacked(address(this), _tickLower, _tickUpper));
        (_liquidity, , , , ) = POOL.positions(_positionKey);
    }

    function _addLiquidity(
        int24 _lowerTick,
        int24 _upperTick,
        uint256 _amount0Desired,
        uint256 _amount1Desired
    ) internal returns (uint128 _liquidity, uint256 _amount0, uint256 _amount1) {
        (uint160 _sqrtPriceX96, , , , , , ) = POOL.slot0();

        _liquidity = LiquidityAmounts.getLiquidityForAmounts(
            _sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(_lowerTick),
            TickMath.getSqrtRatioAtTick(_upperTick),
            _amount0Desired,
            _amount1Desired
        );

        (_amount0, _amount1) = POOL.mint(
            address(this),
            _lowerTick,
            _upperTick,
            _liquidity,
            abi.encode(_msgSender())
        );
    }

    function _removeLiquidity(
        uint128 _liquidity,
        int24 _tickLower,
        int24 _tickUpper
    ) internal returns (uint256 _amount0, uint256 _amount1) {
        (_amount0, _amount1) = POOL.burn(_tickLower, _tickUpper, _liquidity);

        (uint128 _collected0, uint128 _collected1) = POOL.collect(
            address(this),
            _tickLower,
            _tickUpper,
            type(uint128).max,
            type(uint128).max
        );

        _amount0 += _collected0;
        _amount1 += _collected1;
    }

    function _calculateSwapAmount(
        uint256 _amount0,
        uint256 _amount1
    ) internal view returns (uint256 _swapAmount, bool _zeroForOne) {
        (uint160 _sqrtPriceX96, , , , , , ) = POOL.slot0();
        uint256 _priceX96 = (uint256(_sqrtPriceX96) * uint256(_sqrtPriceX96)) / (1 << 96);
        uint256 _value0 = _amount0 * _priceX96;
        uint256 _value1 = _amount1 * (1 << 96);

        if (_value0 > _value1) {
            _swapAmount = (_value0 - _value1) / (2 * _priceX96);
            _zeroForOne = true;
        } else {
            _swapAmount = (_value1 - _value0) / (2 * (1 << 96));
            _zeroForOne = false;
        }
    }

    function _swapTokens(uint256 _amountIn, bool _zeroForOne) internal {
        IERC20 tokenIn = _zeroForOne ? TOKEN0 : TOKEN1;
        IERC20 tokenOut = _zeroForOne ? TOKEN1 : TOKEN0;

        tokenIn.safeIncreaseAllowance(address(SWAP_ROUTER), _amountIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            fee: POOL.fee(),
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: _amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        SWAP_ROUTER.exactInputSingle(params);
    }

    function _simulateSwap(uint256 amountIn, bool zeroForOne) internal returns (uint256 amountOut) {
        address tokenIn = zeroForOne ? address(TOKEN0) : address(TOKEN1);
        address tokenOut = zeroForOne ? address(TOKEN1) : address(TOKEN0);
        uint24 fee = POOL.fee();

        amountOut = QUOTER.quoteExactInputSingle(
            tokenIn,
            tokenOut,
            fee,
            amountIn,
            0 // We don't need to set a price limit for simulation
        );
    }

    function _getPendingFees() internal view returns (uint256 fee0, uint256 fee1) {
        (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, , ) = POOL.positions(
            keccak256(abi.encodePacked(address(this), _currentLowerTick, _currentUpperTick))
        );

        (, , uint256 feeGrowthOutside0LowerX128, uint256 feeGrowthOutside1LowerX128, , , , ) = POOL
            .ticks(_currentLowerTick);
        (, , uint256 feeGrowthOutside0UpperX128, uint256 feeGrowthOutside1UpperX128, , , , ) = POOL
            .ticks(_currentUpperTick);

        uint256 feeGrowthBelow0X128 = _currentLowerTick > TickMath.MIN_TICK
            ? feeGrowthOutside0LowerX128
            : 0;
        uint256 feeGrowthBelow1X128 = _currentLowerTick > TickMath.MIN_TICK
            ? feeGrowthOutside1LowerX128
            : 0;
        uint256 feeGrowthAbove0X128 = _currentUpperTick < TickMath.MAX_TICK
            ? feeGrowthOutside0UpperX128
            : 0;
        uint256 feeGrowthAbove1X128 = _currentUpperTick < TickMath.MAX_TICK
            ? feeGrowthOutside1UpperX128
            : 0;

        uint256 feeGrowthInside0X128 = POOL.feeGrowthGlobal0X128() -
            feeGrowthBelow0X128 -
            feeGrowthAbove0X128;
        uint256 feeGrowthInside1X128 = POOL.feeGrowthGlobal1X128() -
            feeGrowthBelow1X128 -
            feeGrowthAbove1X128;

        uint128 liquidity = _currentPosition(_currentLowerTick, _currentUpperTick);

        fee0 = (uint256(liquidity) * (feeGrowthInside0X128 - feeGrowthInside0LastX128)) >> 128;
        fee1 = (uint256(liquidity) * (feeGrowthInside1X128 - feeGrowthInside1LastX128)) >> 128;
    }

    function _sqrt(uint256 x) private pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function _abs(int24 x) private pure returns (int24) {
        return x >= 0 ? x : -x;
    }
}