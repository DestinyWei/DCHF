// SPDX-License-Identifier: MIT

pragma solidity ^0.8.14;
import "./Interfaces/IPriceFeed.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/BaseMath.sol";
import "./Dependencies/DfrancMath.sol";
import "./Dependencies/Initializable.sol";

/*
 * @notice 喂价合约(预言机)
 *
 * @note 包含的内容如下:
 *		modifier isController() 																			判断调用者是否为合约拥有者或管理员合约地址
 *		function setAddresses(address _adminContract) 														初始化设置地址 1. 检查合约地址是否不为0地址以及检查调用的合约是否存在 2. 赋值
 *		function setAdminContract(address _admin) 															设置管理员合约地址
 *		function addOracle(address _token,address _chainlinkOracle,address _chainlinkIndexOracle) 			添加预言机
 *		function getDirectPrice(address _asset) 															获取DCHF中_asset的直接价格
 *		function fetchPrice(address _token) 																获取_token的价格
 *		function _getIndexedPrice(uint256 _price, uint256 _index) 											获取Indexed价格
 *		function _getChainlinkResponses(AggregatorV3Interface _chainLinkOracle,
										AggregatorV3Interface _chainLinkIndexOracle) 						获取Chainlink响应
 *		function _chainlinkIsBroken(ChainlinkResponse memory _currentResponse,
									ChainlinkResponse memory _prevResponse) 								检查Chainlink是否故障
 *		function _badChainlinkResponse(ChainlinkResponse memory _response) 									判断是否为坏的Chainlink响应
 *		function _chainlinkIsFrozen(ChainlinkResponse memory _response) 									检查Chainlink是否被冻结
 *		function _chainlinkPriceChangeAboveMax(ChainlinkResponse memory _currentResponse,
											   ChainlinkResponse memory _prevResponse) 						判断Chainlink价格变化是否超过最大值
 *		function _scaleChainlinkPriceByDigits(uint256 _price, uint256 _answerDigits) 						缩放Chainlink的价格到DFranc的目标精度
 *		function _changeStatus(Status _status) 																改变Chainlink状态
 *		function _storeChainlinkIndex(address _token, ChainlinkResponse memory _chainlinkIndexResponse) 	保存Chainlink下标
 *		function _storeChainlinkPrice(address _token, ChainlinkResponse memory _chainlinkResponse) 			保存Chainlink价格
 *		function _storePrice(address _token, uint256 _currentPrice) 										保存价格
 *		function _storeIndex(address _token, uint256 _currentIndex) 										保存下标
 *		function _getCurrentChainlinkResponse(AggregatorV3Interface _priceAggregator) 						获取当前Chainlink响应
 *		function _getPrevChainlinkResponse(AggregatorV3Interface _priceAggregator,
										   uint80 _currentRoundId, uint8 _currentDecimals) 					获取上一次Chainlink的响应
 */
contract PriceFeed is Ownable, CheckContract, BaseMath, Initializable, IPriceFeed {
	using SafeMath for uint256;

	string public constant NAME = "PriceFeed";

	// Use to convert a price answer to an 18-digit precision uint 用于将价格答案转换为 18 位精度 uint
	uint256 public constant TARGET_DIGITS = 18;

	// 过期时间
	uint256 public constant TIMEOUT = 4 hours;

	// Maximum deviation allowed between two consecutive Chainlink oracle prices. 18-digit precision.
	// 两个连续的Chainlink预言机价格之间允许的最大偏差, 18位精度
	uint256 public constant MAX_PRICE_DEVIATION_FROM_PREVIOUS_ROUND = 5e17; // 50%
	uint256 public constant MAX_PRICE_DIFFERENCE_BETWEEN_ORACLES = 5e16; // 5%

	bool public isInitialized;

	address public adminContract;

	IPriceFeed.Status public status;
	mapping(address => RegisterOracle) public registeredOracles;
	mapping(address => uint256) public lastGoodPrice;
	mapping(address => uint256) public lastGoodIndex;

	/*
	 * @note 判断调用者是否为合约拥有者或管理员合约地址
	 */
	modifier isController() {
		require(msg.sender == owner() || msg.sender == adminContract, "Invalid Permission");
		_;
	}

	/*
	 * @note 初始化设置地址
	 * 		 1. 检查合约地址是否不为0地址以及检查调用的合约是否存在
	 * 		 2. 赋值
	 */
	function setAddresses(address _adminContract) external initializer onlyOwner {
		require(!isInitialized, "Already initialized");
		checkContract(_adminContract);
		isInitialized = true;

		adminContract = _adminContract;
		status = Status.chainlinkWorking;
	}

	/*
	 * @note 设置管理员合约地址
	 */
	function setAdminContract(address _admin) external onlyOwner {
		require(_admin != address(0), "Admin address is zero");
		// 检查合约地址是否不为0地址以及检查调用的合约是否存在
		checkContract(_admin);
		adminContract = _admin;
	}

	/*
	 * @note 添加预言机
	 */
	function addOracle(
		address _token,
		address _chainlinkOracle,
		address _chainlinkIndexOracle
	) external override isController {
		AggregatorV3Interface priceOracle = AggregatorV3Interface(_chainlinkOracle);
		AggregatorV3Interface indexOracle = AggregatorV3Interface(_chainlinkIndexOracle);

		registeredOracles[_token] = RegisterOracle(priceOracle, indexOracle, true);

		(
			ChainlinkResponse memory chainlinkResponse,
			ChainlinkResponse memory prevChainlinkResponse,
			ChainlinkResponse memory chainlinkIndexResponse,
			ChainlinkResponse memory prevChainlinkIndexResponse
		) = _getChainlinkResponses(priceOracle, indexOracle);

		require(
			!_chainlinkIsBroken(chainlinkResponse, prevChainlinkResponse) &&
				!_chainlinkIsFrozen(chainlinkResponse),
			"PriceFeed: Chainlink must be working and current"
		);
		require(
			!_chainlinkIsBroken(chainlinkIndexResponse, prevChainlinkIndexResponse),
			"PriceFeed: Chainlink must be working and current"
		);

		_storeChainlinkPrice(_token, chainlinkResponse);
		_storeChainlinkIndex(_token, chainlinkIndexResponse);

		emit RegisteredNewOracle(_token, _chainlinkOracle, _chainlinkIndexOracle);
	}

	/*
	 * @note 获取DCHF中_asset的直接价格
	 */
	function getDirectPrice(address _asset) public view returns (uint256 _priceAssetInDCHF) {
		RegisterOracle memory oracle = registeredOracles[_asset];
		(
			ChainlinkResponse memory chainlinkResponse,
			,
			ChainlinkResponse memory chainlinkIndexResponse,

		) = _getChainlinkResponses(oracle.chainLinkOracle, oracle.chainLinkIndex);

		uint256 scaledChainlinkPrice = _scaleChainlinkPriceByDigits(
			uint256(chainlinkResponse.answer),
			chainlinkResponse.decimals
		);

		uint256 scaledChainlinkIndexPrice = _scaleChainlinkPriceByDigits(
			uint256(chainlinkIndexResponse.answer),
			chainlinkIndexResponse.decimals
		);

		_priceAssetInDCHF = scaledChainlinkPrice.mul(1 ether).div(scaledChainlinkIndexPrice);
	}

	/*
	 * @note 获取_token的价格
	 */
	function fetchPrice(address _token) external override returns (uint256) {
		RegisterOracle storage oracle = registeredOracles[_token];
		require(oracle.isRegistered, "Oracle is not registered!");

		(
			ChainlinkResponse memory chainlinkResponse,
			ChainlinkResponse memory prevChainlinkResponse,
			ChainlinkResponse memory chainlinkIndexResponse,
			ChainlinkResponse memory prevChainlinkIndexResponse
		) = _getChainlinkResponses(oracle.chainLinkOracle, oracle.chainLinkIndex);

		uint256 lastTokenGoodPrice = lastGoodPrice[_token];
		uint256 lastTokenGoodIndex = lastGoodIndex[_token];

		bool isChainlinkOracleBroken = _chainlinkIsBroken(
			chainlinkResponse,
			prevChainlinkResponse
		) || _chainlinkIsFrozen(chainlinkResponse);

		bool isChainlinkIndexBroken = _chainlinkIsBroken(
			chainlinkIndexResponse,
			prevChainlinkIndexResponse
		);

		if (status == Status.chainlinkWorking) {
			if (isChainlinkOracleBroken || isChainlinkIndexBroken) {
				if (!isChainlinkOracleBroken) {
					lastTokenGoodPrice = _storeChainlinkPrice(_token, chainlinkResponse);
				}

				if (!isChainlinkIndexBroken) {
					lastTokenGoodIndex = _storeChainlinkIndex(_token, chainlinkIndexResponse);
				}

				_changeStatus(Status.chainlinkUntrusted);
				return _getIndexedPrice(lastTokenGoodPrice, lastTokenGoodIndex);
			}

			// If Chainlink price has changed by > 50% between two consecutive rounds
			if (_chainlinkPriceChangeAboveMax(chainlinkResponse, prevChainlinkResponse)) {
				return _getIndexedPrice(lastTokenGoodPrice, lastTokenGoodIndex);
			}

			lastTokenGoodPrice = _storeChainlinkPrice(_token, chainlinkResponse);
			lastTokenGoodIndex = _storeChainlinkIndex(_token, chainlinkIndexResponse);

			return _getIndexedPrice(lastTokenGoodPrice, lastTokenGoodIndex);
		}

		if (status == Status.chainlinkUntrusted) {
			if (!isChainlinkOracleBroken && !isChainlinkIndexBroken) {
				_changeStatus(Status.chainlinkWorking);
			}

			if (!isChainlinkOracleBroken) {
				lastTokenGoodPrice = _storeChainlinkPrice(_token, chainlinkResponse);
			}

			if (!isChainlinkIndexBroken) {
				lastTokenGoodIndex = _storeChainlinkIndex(_token, chainlinkIndexResponse);
			}

			return _getIndexedPrice(lastTokenGoodPrice, lastTokenGoodIndex);
		}

		return _getIndexedPrice(lastTokenGoodPrice, lastTokenGoodIndex);
	}

	/*
	 * @note 获取Indexed价格
	 */
	function _getIndexedPrice(uint256 _price, uint256 _index) internal pure returns (uint256) {
		return _price.mul(1 ether).div(_index);
	}

	/*
	 * @note 获取Chainlink响应
	 */
	function _getChainlinkResponses(
		AggregatorV3Interface _chainLinkOracle,
		AggregatorV3Interface _chainLinkIndexOracle
	)
		internal
		view
		returns (
			ChainlinkResponse memory currentChainlink,
			ChainlinkResponse memory prevChainLink,
			ChainlinkResponse memory currentChainlinkIndex,
			ChainlinkResponse memory prevChainLinkIndex
		)
	{
		currentChainlink = _getCurrentChainlinkResponse(_chainLinkOracle);
		prevChainLink = _getPrevChainlinkResponse(
			_chainLinkOracle,
			currentChainlink.roundId,
			currentChainlink.decimals
		);

		if (address(_chainLinkIndexOracle) != address(0)) {
			currentChainlinkIndex = _getCurrentChainlinkResponse(_chainLinkIndexOracle);
			prevChainLinkIndex = _getPrevChainlinkResponse(
				_chainLinkIndexOracle,
				currentChainlinkIndex.roundId,
				currentChainlinkIndex.decimals
			);
		} else {
			currentChainlinkIndex = ChainlinkResponse(1, 1 ether, block.timestamp, true, 18);

			prevChainLinkIndex = currentChainlinkIndex;
		}

		return (currentChainlink, prevChainLink, currentChainlinkIndex, prevChainLinkIndex);
	}

	/*
	 * @note 检查Chainlink是否故障
	 */
	function _chainlinkIsBroken(
		ChainlinkResponse memory _currentResponse,
		ChainlinkResponse memory _prevResponse
	) internal view returns (bool) {
		return _badChainlinkResponse(_currentResponse) || _badChainlinkResponse(_prevResponse);
	}

	/*
	 * @note 判断是否为坏的Chainlink响应
	 */
	function _badChainlinkResponse(ChainlinkResponse memory _response)
		internal
		view
		returns (bool)
	{
		if (!_response.success) {
			return true;
		}
		if (_response.roundId == 0) {
			return true;
		}
		if (_response.timestamp == 0 || _response.timestamp > block.timestamp) {
			return true;
		}
		if (_response.answer <= 0) {
			return true;
		}

		return false;
	}

	/*
	 * @note 检查Chainlink是否被冻结
	 */
	function _chainlinkIsFrozen(ChainlinkResponse memory _response)
		internal
		view
		returns (bool)
	{
		return block.timestamp.sub(_response.timestamp) > TIMEOUT;
	}

	/*
	 * @note 判断Chainlink价格变化是否超过最大值
	 */
	function _chainlinkPriceChangeAboveMax(
		ChainlinkResponse memory _currentResponse,
		ChainlinkResponse memory _prevResponse
	) internal pure returns (bool) {
		uint256 currentScaledPrice = _scaleChainlinkPriceByDigits(
			uint256(_currentResponse.answer),
			_currentResponse.decimals
		);
		uint256 prevScaledPrice = _scaleChainlinkPriceByDigits(
			uint256(_prevResponse.answer),
			_prevResponse.decimals
		);

		uint256 minPrice = DfrancMath._min(currentScaledPrice, prevScaledPrice);
		uint256 maxPrice = DfrancMath._max(currentScaledPrice, prevScaledPrice);

		/*
		 * Use the larger price as the denominator:
		 * - If price decreased, the percentage deviation is in relation to the the previous price.
		 * - If price increased, the percentage deviation is in relation to the current price.
		 */
		uint256 percentDeviation = maxPrice.sub(minPrice).mul(DECIMAL_PRECISION).div(maxPrice);

		// Return true if price has more than doubled, or more than halved. 如果价格翻了两倍以上或减半以上,则返回 true
		return percentDeviation > MAX_PRICE_DEVIATION_FROM_PREVIOUS_ROUND;
	}

	/*
	 * @note 缩放Chainlink的价格到DFranc的目标精度
	 */
	function _scaleChainlinkPriceByDigits(uint256 _price, uint256 _answerDigits)
		internal
		pure
		returns (uint256)
	{
		uint256 price;
		if (_answerDigits >= TARGET_DIGITS) {
			// Scale the returned price value down to Dfranc's target precision
			price = _price.div(10**(_answerDigits - TARGET_DIGITS));
		} else if (_answerDigits < TARGET_DIGITS) {
			// Scale the returned price value up to Dfranc's target precision
			price = _price.mul(10**(TARGET_DIGITS - _answerDigits));
		}
		return price;
	}

	/*
	 * @note 改变Chainlink状态
	 */
	function _changeStatus(Status _status) internal {
		status = _status;
		emit PriceFeedStatusChanged(_status);
	}

	/*
	 * @note 保存Chainlink下标
	 */
	function _storeChainlinkIndex(
		address _token,
		ChainlinkResponse memory _chainlinkIndexResponse
	) internal returns (uint256) {
		uint256 scaledChainlinkIndex = _scaleChainlinkPriceByDigits(
			uint256(_chainlinkIndexResponse.answer),
			_chainlinkIndexResponse.decimals
		);

		_storeIndex(_token, scaledChainlinkIndex);
		return scaledChainlinkIndex;
	}

	/*
	 * @note 保存Chainlink价格
	 */
	function _storeChainlinkPrice(address _token, ChainlinkResponse memory _chainlinkResponse)
		internal
		returns (uint256)
	{
		uint256 scaledChainlinkPrice = _scaleChainlinkPriceByDigits(
			uint256(_chainlinkResponse.answer),
			_chainlinkResponse.decimals
		);

		_storePrice(_token, scaledChainlinkPrice);
		return scaledChainlinkPrice;
	}

	/*
	 * @note 保存价格
	 */
	function _storePrice(address _token, uint256 _currentPrice) internal {
		lastGoodPrice[_token] = _currentPrice;
		emit LastGoodPriceUpdated(_token, _currentPrice);
	}

	/*
	 * @note 保存下标
	 */
	function _storeIndex(address _token, uint256 _currentIndex) internal {
		lastGoodIndex[_token] = _currentIndex;
		emit LastGoodIndexUpdated(_token, _currentIndex);
	}

	// --- Oracle response wrapper functions ---

	/*
	 * @note 获取当前Chainlink响应
	 */
	function _getCurrentChainlinkResponse(AggregatorV3Interface _priceAggregator)
		internal
		view
		returns (ChainlinkResponse memory chainlinkResponse)
	{
		try _priceAggregator.decimals() returns (uint8 decimals) {
			chainlinkResponse.decimals = decimals;
		} catch {
			return chainlinkResponse;
		}

		try _priceAggregator.latestRoundData() returns (
			uint80 roundId,
			int256 answer,
			uint256, /* startedAt */
			uint256 timestamp,
			uint80 /* answeredInRound */
		) {
			chainlinkResponse.roundId = roundId;
			chainlinkResponse.answer = answer;
			chainlinkResponse.timestamp = timestamp;
			chainlinkResponse.success = true;
			return chainlinkResponse;
		} catch {
			return chainlinkResponse;
		}
	}

	/*
	 * @note 获取上一次Chainlink的响应
	 */
	function _getPrevChainlinkResponse(
		AggregatorV3Interface _priceAggregator,
		uint80 _currentRoundId,
		uint8 _currentDecimals
	) internal view returns (ChainlinkResponse memory prevChainlinkResponse) {
		if (_currentRoundId == 0) {
			return prevChainlinkResponse;
		}

		unchecked {
			try _priceAggregator.getRoundData(_currentRoundId - 1) returns (
				uint80 roundId,
				int256 answer,
				uint256, /* startedAt */
				uint256 timestamp,
				uint80 /* answeredInRound */
			) {
				prevChainlinkResponse.roundId = roundId;
				prevChainlinkResponse.answer = answer;
				prevChainlinkResponse.timestamp = timestamp;
				prevChainlinkResponse.decimals = _currentDecimals;
				prevChainlinkResponse.success = true;
				return prevChainlinkResponse;
			} catch {
				return prevChainlinkResponse;
			}
		}
	}
}
