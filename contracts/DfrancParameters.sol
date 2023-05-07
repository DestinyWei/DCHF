//SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./Dependencies/CheckContract.sol";
import "./Dependencies/Initializable.sol";
import "./Interfaces/IDfrancParameters.sol";

/*
 * @notice Dfranc参数,集合了所有合约的通用参数和function(核心合约)
 *
 * @note 包含的内容如下:
 *		function setAddresses(address _activePool, address _defaultPool,
							  address _priceFeed, address _adminContract) 							初始化设置地址
 *		function setAdminContract(address _admin) 													设置管理员合约地址
 *		function setPriceFeed(address _priceFeed) 													设置价格供应合约地址
 *		function sanitizeParameters(address _asset) 												重置_asset的公共参数为默认值
 *		function setAsDefault(address _asset) 														设置_asset的公共参数为默认值
 *		function setAsDefaultWithRemptionBlock(address _asset, uint256 blockInDays) 				设置默认公共参数并规定DCHF发行后的14天之后才可以进行赎回操作
 *		function _setAsDefault(address _asset) 														将_asset的相关公共参数设置为默认值
 *		function setCollateralParameters(address _asset, uint256 newMCR, uint256 newCCR,
										 uint256 gasCompensation, uint256 minNetDebt,
										 uint256 precentDivisor, uint256 borrowingFeeFloor,
										 uint256 maxBorrowingFee, uint256 redemptionFeeFloor) 		设置质押物的相关参数
 *		function setMCR(address _asset, uint256 newMCR) 											设置最小抵押率(最低101%,最高1000%)
 *		function setCCR(address _asset, uint256 newCCR) 											设置关键系统抵押率(最低101%,最高1000%)
 *		function setPercentDivisor(address _asset, uint256 precentDivisor) 							设置百分比除数(最低2,最高200)
 *		function setBorrowingFeeFloor(address _asset, uint256 borrowingFeeFloor) 					设置最低借贷费用比例(最低0%,最高10%)
 *		function setMaxBorrowingFee(address _asset, uint256 maxBorrowingFee) 						设置最高借贷费用(最低0.1%,最高10%)
 *		function setDCHFGasCompensation(address _asset, uint256 gasCompensation) 					设置DCHF的Gas补偿(最低1 ether,最高200 ether)
 *		function setMinNetDebt(address _asset, uint256 minNetDebt) 									设置单个trove最少需要持有的DCHF净债务
 *		function setRedemptionFeeFloor(address _asset, uint256 redemptionFeeFloor) 					设置赎回费用比例(最低0.1%,最高10%)
 *		function removeRedemptionBlock(address _asset) 												清除之前规定的DCHF发行后的多少天之后才可以进行赎回操作的数值
 *		modifier safeCheck(string memory parameter, address _asset,
						   uint256 enteredValue, uint256 min, uint256 max) 							安全检查,判断_asset的参数是否配置以及判断enteredValue的数值是否在min-max之间
 *
 */
contract DfrancParameters is IDfrancParameters, Ownable, CheckContract, Initializable {
	string public constant NAME = "DfrancParameters";

	uint256 public constant override DECIMAL_PRECISION = 1 ether; // 小数点精度
	uint256 public constant override _100pct = 1 ether; // 1e18 == 100%

	uint256 public constant REDEMPTION_BLOCK_DAY = 14; // 规定DCHF发行后的多少天之后才可以进行赎回操作

	uint256 public constant MCR_DEFAULT = 1100000000000000000; // 110%
	uint256 public constant CCR_DEFAULT = 1500000000000000000; // 150%
	uint256 public constant PERCENT_DIVISOR_DEFAULT = 100; // dividing by 100 yields 0.5%

	uint256 public constant BORROWING_FEE_FLOOR_DEFAULT = (DECIMAL_PRECISION / 1000) * 5; // 0.5% 默认最低借贷费用比例
	uint256 public constant MAX_BORROWING_FEE_DEFAULT = (DECIMAL_PRECISION / 100) * 5; // 5% 默认最高借贷费用比例

	uint256 public constant DCHF_GAS_COMPENSATION_DEFAULT = 200 ether; // DCHF gas默认费用补偿
	uint256 public constant MIN_NET_DEBT_DEFAULT = 2000 ether; // 最低净债务
	uint256 public constant REDEMPTION_FEE_FLOOR_DEFAULT = (DECIMAL_PRECISION / 1000) * 5; // 0.5% 默认赎回费用比例

	// Minimum collateral ratio for individual troves 单个trove的抵押率
	mapping(address => uint256) public override MCR;
	// Critical system collateral ratio. If the system's total collateral ratio (TCR) falls below the CCR, Recovery Mode is triggered. 关键系统抵押率
	mapping(address => uint256) public override CCR;

	mapping(address => uint256) public override DCHF_GAS_COMPENSATION; // Amount of DCHF to be locked in gas pool on opening troves 运行中的trove被锁定在Gas Pool中的DCHF数量
	mapping(address => uint256) public override MIN_NET_DEBT; // Minimum amount of net DCHF debt a trove must have 单个trove最少需要持有的DCHF净债务
	mapping(address => uint256) public override PERCENT_DIVISOR; // dividing by 200 yields 0.5% 百分比除数(除以200得到0.5%)
	mapping(address => uint256) public override BORROWING_FEE_FLOOR; // 最低借贷费用比例
	mapping(address => uint256) public override REDEMPTION_FEE_FLOOR; // 最低赎回费用比例
	mapping(address => uint256) public override MAX_BORROWING_FEE; // 最高借贷费用比例
	mapping(address => uint256) public override redemptionBlock;

	mapping(address => bool) internal hasCollateralConfigured; // 是否有配置了的抵押物

	IActivePool public override activePool;
	IDefaultPool public override defaultPool;
	IPriceFeed public override priceFeed;
	address public adminContract;

	bool public isInitialized;

	/*
	 * @note 判断调用者是否为合约拥有者或管理员合约地址
	 */
	modifier isController() {
		require(msg.sender == owner() || msg.sender == adminContract, "Invalid Permissions");
		_;
	}

	/*
	 * @note 初始化设置地址
	 * 		 1. 检查合约地址是否不为0地址以及检查调用的合约是否存在
	 * 		 2. 赋值
	 */
	function setAddresses(
		address _activePool,
		address _defaultPool,
		address _priceFeed,
		address _adminContract
	) external override initializer onlyOwner {
		require(!isInitialized, "Already initalized");
		checkContract(_activePool);
		checkContract(_defaultPool);
		checkContract(_priceFeed);
		checkContract(_adminContract);
		isInitialized = true;

		adminContract = _adminContract;
		activePool = IActivePool(_activePool);
		defaultPool = IDefaultPool(_defaultPool);
		priceFeed = IPriceFeed(_priceFeed);
	}

	/*
	 * @note 设置管理员合约地址
	 */
	function setAdminContract(address _admin) external onlyOwner {
		require(_admin != address(0), "admin address is zero");
		checkContract(_admin);
		adminContract = _admin;
	}

	/*
	 * @note 设置价格供应合约地址
	 */
	function setPriceFeed(address _priceFeed) external override onlyOwner {
		checkContract(_priceFeed);
		priceFeed = IPriceFeed(_priceFeed);

		emit PriceFeedChanged(_priceFeed);
	}

	/*
	 * @note 重置_asset的公共参数为默认值
	 */
	function sanitizeParameters(address _asset) external {
		if (!hasCollateralConfigured[_asset]) {
			_setAsDefault(_asset);
		}
	}

	/*
	 * @note 设置_asset的公共参数为默认值
	 */
	function setAsDefault(address _asset) external onlyOwner {
		_setAsDefault(_asset);
	}

	/*
	 * @note 设置默认公共参数并规定DCHF发行后的14天之后才可以进行赎回操作
	 */
	function setAsDefaultWithRemptionBlock(address _asset, uint256 blockInDays)
		external
		isController
	{
		if (blockInDays > 14) {
			blockInDays = REDEMPTION_BLOCK_DAY;
		}

		if (redemptionBlock[_asset] == 0) {
			redemptionBlock[_asset] = block.timestamp + (blockInDays * 1 days);
		}

		_setAsDefault(_asset);
	}

	/*
	 * @note 将_asset的相关公共参数设置为默认值
	 */
	function _setAsDefault(address _asset) private {
		hasCollateralConfigured[_asset] = true;

		MCR[_asset] = MCR_DEFAULT;
		CCR[_asset] = CCR_DEFAULT;
		DCHF_GAS_COMPENSATION[_asset] = DCHF_GAS_COMPENSATION_DEFAULT;
		MIN_NET_DEBT[_asset] = MIN_NET_DEBT_DEFAULT;
		PERCENT_DIVISOR[_asset] = PERCENT_DIVISOR_DEFAULT;
		BORROWING_FEE_FLOOR[_asset] = BORROWING_FEE_FLOOR_DEFAULT;
		MAX_BORROWING_FEE[_asset] = MAX_BORROWING_FEE_DEFAULT;
		REDEMPTION_FEE_FLOOR[_asset] = REDEMPTION_FEE_FLOOR_DEFAULT;
	}

	/*
	 * @note 设置质押物的相关参数
	 */
	function setCollateralParameters(
		address _asset,
		uint256 newMCR,
		uint256 newCCR,
		uint256 gasCompensation,
		uint256 minNetDebt,
		uint256 precentDivisor,
		uint256 borrowingFeeFloor,
		uint256 maxBorrowingFee,
		uint256 redemptionFeeFloor
	) external onlyOwner {
		hasCollateralConfigured[_asset] = true;

		setMCR(_asset, newMCR);
		setCCR(_asset, newCCR);
		setDCHFGasCompensation(_asset, gasCompensation);
		setMinNetDebt(_asset, minNetDebt);
		setPercentDivisor(_asset, precentDivisor);
		setMaxBorrowingFee(_asset, maxBorrowingFee);
		setBorrowingFeeFloor(_asset, borrowingFeeFloor);
		setRedemptionFeeFloor(_asset, redemptionFeeFloor);
	}

	/*
	 * @note 设置最小抵押率(最低101%,最高1000%)
	 */
	function setMCR(address _asset, uint256 newMCR)
		public
		override
		onlyOwner
		safeCheck("MCR", _asset, newMCR, 1010000000000000000, 10000000000000000000) /// 101% - 1000%
	{
		uint256 oldMCR = MCR[_asset];
		MCR[_asset] = newMCR;

		emit MCRChanged(oldMCR, newMCR);
	}

	/*
	 * @note 设置关键系统抵押率(最低101%,最高1000%)
	 */
	function setCCR(address _asset, uint256 newCCR)
		public
		override
		onlyOwner
		safeCheck("CCR", _asset, newCCR, 1010000000000000000, 10000000000000000000) /// 101% - 1000%
	{
		uint256 oldCCR = CCR[_asset];
		CCR[_asset] = newCCR;

		emit CCRChanged(oldCCR, newCCR);
	}

	/*
	 * @note 设置百分比除数(最低2,最高200)
	 */
	function setPercentDivisor(address _asset, uint256 precentDivisor)
		public
		override
		onlyOwner
		safeCheck("Percent Divisor", _asset, precentDivisor, 2, 200)
	{
		uint256 oldPercent = PERCENT_DIVISOR[_asset];
		PERCENT_DIVISOR[_asset] = precentDivisor;

		emit PercentDivisorChanged(oldPercent, precentDivisor);
	}

	/*
	 * @note 设置最低借贷费用比例(最低0%,最高10%)
	 */
	function setBorrowingFeeFloor(address _asset, uint256 borrowingFeeFloor)
		public
		override
		onlyOwner
		safeCheck("Borrowing Fee Floor", _asset, borrowingFeeFloor, 0, 1000) /// 0% - 10%
	{
		uint256 oldBorrowing = BORROWING_FEE_FLOOR[_asset];
		uint256 newBorrowingFee = (DECIMAL_PRECISION / 10000) * borrowingFeeFloor;

		BORROWING_FEE_FLOOR[_asset] = newBorrowingFee;
		require(MAX_BORROWING_FEE[_asset] > BORROWING_FEE_FLOOR[_asset], "Wrong inputs");

		emit BorrowingFeeFloorChanged(oldBorrowing, newBorrowingFee);
	}

	/*
	 * @note 设置最高借贷费用(最低0.1%,最高10%)
	 */
	function setMaxBorrowingFee(address _asset, uint256 maxBorrowingFee)
		public
		override
		onlyOwner
		safeCheck("Max Borrowing Fee", _asset, maxBorrowingFee, 0, 1000) /// 0% - 10%
	{
		uint256 oldMaxBorrowingFee = MAX_BORROWING_FEE[_asset];
		uint256 newMaxBorrowingFee = (DECIMAL_PRECISION / 10000) * maxBorrowingFee;

		MAX_BORROWING_FEE[_asset] = newMaxBorrowingFee;
		require(MAX_BORROWING_FEE[_asset] > BORROWING_FEE_FLOOR[_asset], "Wrong inputs");

		emit MaxBorrowingFeeChanged(oldMaxBorrowingFee, newMaxBorrowingFee);
	}

	/*
	 * @note 设置DCHF的Gas补偿(最低1 ether,最高200 ether)
	 */
	function setDCHFGasCompensation(address _asset, uint256 gasCompensation)
		public
		override
		onlyOwner
		safeCheck("Gas Compensation", _asset, gasCompensation, 1 ether, 200 ether)
	{
		uint256 oldGasComp = DCHF_GAS_COMPENSATION[_asset];
		DCHF_GAS_COMPENSATION[_asset] = gasCompensation;

		emit GasCompensationChanged(oldGasComp, gasCompensation);
	}

	/*
	 * @note 设置单个trove最少需要持有的DCHF净债务
	 */
	function setMinNetDebt(address _asset, uint256 minNetDebt)
		public
		override
		onlyOwner
		safeCheck("Min Net Debt", _asset, minNetDebt, 0, 10000 ether)
	{
		uint256 oldMinNet = MIN_NET_DEBT[_asset];
		MIN_NET_DEBT[_asset] = minNetDebt;

		emit MinNetDebtChanged(oldMinNet, minNetDebt);
	}

	/*
	 * @note 设置赎回费用比例(最低0.1%,最高10%)
	 */
	function setRedemptionFeeFloor(address _asset, uint256 redemptionFeeFloor)
		public
		override
		onlyOwner
		safeCheck("Redemption Fee Floor", _asset, redemptionFeeFloor, 10, 1000) /// 0.10% - 10%
	{
		uint256 oldRedemptionFeeFloor = REDEMPTION_FEE_FLOOR[_asset];
		uint256 newRedemptionFeeFloor = (DECIMAL_PRECISION / 10000) * redemptionFeeFloor;

		REDEMPTION_FEE_FLOOR[_asset] = newRedemptionFeeFloor;
		emit RedemptionFeeFloorChanged(oldRedemptionFeeFloor, newRedemptionFeeFloor);
	}

	/*
	 * @note 清除之前规定的DCHF发行后的多少天之后才可以进行赎回操作的数值
	 */
	function removeRedemptionBlock(address _asset) external override onlyOwner {
		redemptionBlock[_asset] = block.timestamp;

		emit RedemptionBlockRemoved(_asset);
	}

	/*
	 * @note 安全检查,判断_asset的参数是否配置以及判断enteredValue的数值是否在min-max之间
	 */
	modifier safeCheck(
		string memory parameter,
		address _asset,
		uint256 enteredValue,
		uint256 min,
		uint256 max
	) {
		require(
			hasCollateralConfigured[_asset],
			"Collateral is not configured, use setAsDefault or setCollateralParameters"
		);

		if (enteredValue < min || enteredValue > max) {
			revert SafeCheckError(parameter, enteredValue, min, max);
		}
		_;
	}
}
