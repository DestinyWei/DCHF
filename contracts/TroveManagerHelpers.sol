//SPDX-License-Identifier: MIT

pragma solidity ^0.8.14;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./Interfaces/ITroveManagerHelpers.sol";
import "./Dependencies/DfrancBase.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/Initializable.sol";
import "./TroveManager.sol";

/*
 * @notice Trove管理者助手合约
 *
 * @note 包含的内容如下:
 *		function _onlyBOorTM() 																						检查调用者地址是否为BorrowerOperations地址或TroveManager地址
 *		modifier onlyBOorTM() 																						检查调用者地址是否为BorrowerOperations地址或TroveManager地址
 *		function _onlyBorrowerOperations() 																			检查调用者地址是否为BorrowerOperations地址
 *		modifier onlyBorrowerOperations() 																			检查调用者地址是否为BorrowerOperations地址
 *		function _onlyTroveManager() 																				检查调用者地址是否为TroveManager地址
 *		modifier onlyTroveManager() 																				检查调用者地址是否为TroveManager地址
 *		modifier troveIsActive(address _asset, address _borrower) 													检查Trove是否活跃
 *		function setAddresses(address _borrowerOperationsAddress, address _dchfTokenAddress,
							  address _sortedTrovesAddress, address _dfrancParamsAddress,
							  address _troveManagerAddress) 														初始化设置地址 1. 检查合约地址是否不为0地址以及检查调用的合约是否存在 2. 赋值
 *		function getNominalICR(address _asset, address _borrower) 													返回给定Trove的个人名义抵押率(NICR),不带价格.将Trove从再分配中获取的待处理的collateral和债务奖励计入账户
 *		function getCurrentICR(address _asset, address _borrower, uint256 _price) 									返回给定Trove的个人抵押率(ICR).将Trove从再分配中获取的待处理的collateral和债务奖励计入账户
 *		function _getCurrentTroveAmounts(address _asset, address _borrower) 										获取当前Trove的collateral和DCHF债务
 *		function applyPendingRewards(address _asset, address _borrower) 											将借贷者从再分配中获得的collateral和debt奖励发送到他们的trove中
 *		function applyPendingRewards(address _asset, IActivePool _activePool,
									 IDefaultPool _defaultPool, address _borrower) 									将借贷者从再分配中获得的collateral和debt奖励发送到他们的trove中
 *		function _applyPendingRewards(address _asset, IActivePool _activePool,
									  IDefaultPool _defaultPool, address _borrower) 								将借贷者从再分配中获得的collateral和debt奖励发送到他们的trove中
 *		function updateTroveRewardSnapshots(address _asset, address _borrower) 										更新借贷者的L_ETH和L_DCHFDebt快照以反映当前价值
 *		function _updateTroveRewardSnapshots(address _asset, address _borrower) 									更新借贷者的L_ETH和L_DCHFDebt快照以反映当前价值
 *		function getPendingAssetReward(address _asset, address _borrower) 											获取借贷者待处理的累积ETH奖励,通过其stake(股份/权益比例)赚取
 *		function getPendingDCHFDebtReward(address _asset, address _borrower) 										获取借贷者待处理的累积DCHF奖励,通过其stake(股份/权益比例)赚取
 *		function hasPendingRewards(address _asset, address _borrower) 												判断借贷者是否有待处理的奖励
 *		function getEntireDebtAndColl(address _asset, address _borrower) 											获取全部debt和collateral(包括待处理的奖励)
 *		function removeStake(address _asset, address _borrower) 													移除_borrower对于_asset的stake(可理解为股份/权益比例)
 *		function _removeStake(address _asset, address _borrower) 													移除_borrower对于_asset的stake(可理解为股份/权益比例)
 *		function updateStakeAndTotalStakes(address _asset, address _borrower) 										根据借贷者的最新collateral的价值来更新他的stake(可理解为股份/权益比例)
 *		function _updateStakeAndTotalStakes(address _asset, address _borrower) 										根据借贷者的最新collateral的价值来更新他的stake(可理解为股份/权益比例)
 *		function _computeNewStake(address _asset, uint256 _coll) 													根据上次清算时的总stake和总collateral的快照计算新stake
 *		function redistributeDebtAndColl(address _asset, IActivePool _activePool,IDefaultPool _defaultPool,
 										 uint256 _debt, uint256 _coll) 												debt和collateral再分配
 *		function _redistributeDebtAndColl(address _asset, IActivePool _activePool,IDefaultPool _defaultPool,
 										  uint256 _debt,uint256 _coll) 												debt和collateral再分配
 *		function closeTrove(address _asset, address _borrower) 														关闭trove并将关闭状态标记为被owner关闭
 *		function closeTrove(address _asset, address _borrower, Status closedStatus) 								关闭trove并设置关闭状态
 *		function _closeTrove(address _asset, address _borrower, Status closedStatus) 								关闭trove并设置关闭状态
 *		function updateSystemSnapshots_excludeCollRemainder(address _asset, IActivePool _activePool,
															uint256 _collRemainder) 								更新系统快照除去剩余的collateral
 *		function _updateSystemSnapshots_excludeCollRemainder(address _asset, IActivePool _activePool,
															 uint256 _collRemainder) 								更新系统快照除去剩余的collateral
 *		function addTroveOwnerToArray(address _asset, address _borrower) 											将trove的拥有者添加到数组中并返回其在数组的下标
 *		function _addTroveOwnerToArray(address _asset, address _borrower) 											将trove的拥有者添加到数组中并返回其在数组的下标
 *		function _removeTroveOwner(address _asset, address _borrower, uint256 TroveOwnersArrayLength) 				移除trove的owner
 *		function getTCR(address _asset, uint256 _price) 															获取TCR(系统总抵押率)
 *		function checkRecoveryMode(address _asset, uint256 _price) 													检查是否处于恢复模式(TCR < CCR)
 *		function _checkPotentialRecoveryMode(address _asset, uint256 _entireSystemColl,
											 uint256 _entireSystemDebt, uint256 _price) 							检查是否处于恢复模式(TCR < CCR)
 *		function updateBaseRateFromRedemption(address _asset, uint256 _ETHDrawn, uint256 _price,
											  uint256 _totalDCHFSupply) 											从赎回中更新基本费率
 *		function _updateBaseRateFromRedemption(address _asset, uint256 _ETHDrawn, uint256 _price,
											   uint256 _totalDCHFSupply) 											从赎回中更新基本费率
 *		function getRedemptionRate(address _asset) 																	获取赎回费率
 *		function getRedemptionRateWithDecay(address _asset) 														获取衰减后的赎回费率
 *		function _calcRedemptionRate(address _asset, uint256 _baseRate) 											计算赎回费率
 *		function _getRedemptionFee(address _asset, uint256 _assetDraw) 												获取衰减费用
 *		function getRedemptionFeeWithDecay(address _asset, uint256 _assetDraw) 										获取衰减后的赎回费用
 *		function _calcRedemptionFee(uint256 _redemptionRate, uint256 _assetDraw) 									计算赎回费用
 *		function getBorrowingRate(address _asset) 																	获取借贷费率
 *		function getBorrowingRateWithDecay(address _asset) 															获取衰减后的借贷费率
 *		function _calcBorrowingRate(address _asset, uint256 _baseRate) 												计算借贷费率
 *		function getBorrowingFee(address _asset, uint256 _DCHFDebt) 												获取借贷费用
 *		function getBorrowingFeeWithDecay(address _asset, uint256 _DCHFDebt) 										获取衰变后的借贷费用
 *		function _calcBorrowingFee(uint256 _borrowingRate, uint256 _DCHFDebt) 										计算借贷费用
 *		function decayBaseRateFromBorrowing(address _asset) 														从借贷中衰减基本费率
 *		function _updateLastFeeOpTime(address _asset) 																仅当经过的时间大于等于衰减间隔时,才更新上次费用操作时间.这可以防止基本费率的下降
 *		function _calcDecayedBaseRate(address _asset) 																计算衰减之后的基本费率
 *		function _minutesPassedSinceLastFeeOp(address _asset) 														计算从最后一次费用操作到现在过去的时间(以分钟计数)
 *		function _requireDCHFBalanceCoversRedemption(IDCHFToken _dchfToken, address _redeemer, uint256 _amount) 	检查DCHF余额是否大于等于赎回数量
 *		function _requireMoreThanOneTroveInSystem(address _asset, uint256 TroveOwnersArrayLength) 					检查系统中至少有1个以上的trove
 *		function _requireAmountGreaterThanZero(uint256 _amount) 													检查_amount是否大于0
 *		function _requireTCRoverMCR(address _asset, uint256 _price) 												检查TCR(系统总抵押率)是否大于等于MCR(最小抵押率)
 *		function _requireValidMaxFeePercentage(address _asset, uint256 _maxFeePercentage) 							检查最高费用比例是否合法
 *		function isTroveActive(address _asset, address _borrower) 													检查Trove是否活跃
 *		function getTroveOwnersCount(address _asset) 																获取troveOwner列表的长度
 *		function getTroveFromTroveOwnersArray(address _asset, uint256 _index) 										根据_index从TroveOwners数组获取trove
 *		function getTrove(address _asset, address _borrower) 														获取Trove
 *		function getTroveStatus(address _asset, address _borrower) 													获取Trove的状态
 *		function getTroveStake(address _asset, address _borrower) 													获取Trove的stake
 *		function getTroveDebt(address _asset, address _borrower) 													获取Trove的debt
 *		function getTroveColl(address _asset, address _borrower) 													获取Trove的collateral
 *		function setTroveDeptAndColl(address _asset, address _borrower, uint256 _debt, uint256 _coll) 				设置Trove的debt和collateral
 *		function setTroveStatus(address _asset, address _borrower, uint256 _num) 									设置Trove的状态
 *		function decreaseTroveColl(address _asset, address _borrower, uint256 _collDecrease) 						减少Trove的collateral
 *		function increaseTroveDebt(address _asset, address _borrower, uint256 _debtIncrease) 						增加trove的debt
 *		function decreaseTroveDebt(address _asset, address _borrower, uint256 _debtDecrease) 						减少Trove的debt
 *		function increaseTroveColl(address _asset, address _borrower, uint256 _collIncrease) 						增加trove的collateral
 *		function movePendingTroveRewardsToActivePool(address _asset, IActivePool _activePool,
													 IDefaultPool _defaultPool, uint256 _DCHF,
													 uint256 _amount) 												将Trove待处理的从再分配得到的debt和collateral奖励中从Default Pool移动到Active Pool
 *		function _movePendingTroveRewardsToActivePool(address _asset, IActivePool _activePool,
													  IDefaultPool _defaultPool, uint256 _DCHF,
													  uint256 _amount) 												将Trove待处理的从再分配得到的debt和collateral奖励中从Default Pool移动到Active Pool
 *		function getRewardSnapshots(address _asset, address _troveOwner) 											获取奖励快照
 */
contract TroveManagerHelpers is
	DfrancBase,
	CheckContract,
	Initializable,
	ITroveManagerHelpers
{
	using SafeMath for uint256;
	string public constant NAME = "TroveManagerHelpers";

	// --- Connected contract declarations ---

	address public borrowerOperationsAddress;
	address public troveManagerAddress;

	IDCHFToken public dchfToken;

	// A doubly linked list of Troves, sorted by their sorted by their collateral ratios
	// Troves的双向链表,按抵押率排序
	ISortedTroves public sortedTroves;

	// --- Data structures ---

	uint256 public constant SECONDS_IN_ONE_MINUTE = 60;
	/*
	 * Half-life of 12h. 12h = 720 min
	 * (1/2) = d^720 => d = (1/2)^(1/720)
	 */
	uint256 public constant MINUTE_DECAY_FACTOR = 999037758833783000; // 分钟衰减因子

	/*
	 * BETA: 18 digit decimal. Parameter by which to divide the redeemed fraction, in order to calc the new base rate from a redemption.
	 * Corresponds to (1 / ALPHA) in the white paper.
	 */
	// BETA:18位十进制.用于除以赎回部分的参数,以便从赎回中计算新的基本利率.对应于白皮书中的(1 ALPHA)
	uint256 public constant BETA = 2;

	mapping(address => uint256) public baseRate;

	// The timestamp of the latest fee operation (redemption or new DCHF issuance)
	// 最新费用操作(赎回或新发行DCHF)的时间戳
	mapping(address => uint256) public lastFeeOperationTime;

	mapping(address => mapping(address => Trove)) public Troves; // owner地址 -> asset地址 -> Trove

	mapping(address => uint256) public totalStakes;

	// Snapshot of the value of totalStakes, taken immediately after the latest liquidation
	// 总stake价值的快照,在最近一次清算后立即拍摄
	mapping(address => uint256) public totalStakesSnapshot;

	// Snapshot of the total collateral across the ActivePool and DefaultPool, immediately after the latest liquidation.
	// 在最近一次清算后立即跨ActivePool和DefaultPool的总抵押品的快照
	mapping(address => uint256) public totalCollateralSnapshot;

	/*
	 * L_ETH and L_DCHFDebt track the sums of accumulated liquidation rewards per unit staked. During its lifetime, each stake earns:
	 * L_ETH和L_DCHFDebt跟踪每单位stake的累计清算奖励的总和.在其生命周期内,每个stake都获得:
	 *
	 * An ETH gain of ( stake * [L_ETH - L_ETH(0)] )
	 * A DCHFDebt increase  of ( stake * [L_DCHFDebt - L_DCHFDebt(0)] )
	 *
	 * Where L_ETH(0) and L_DCHFDebt(0) are snapshots of L_ETH and L_DCHFDebt for the active Trove taken at the instant the stake was made
	 * 其中L_ETH(0)和L_DCHFDebt(0)是在质押时拍摄的active Trove的L_ETH和L_DCHFDebt快照
	 */
	mapping(address => uint256) public L_ASSETS;
	mapping(address => uint256) public L_DCHFDebts;

	// Map addresses with active troves to their RewardSnapshot
	mapping(address => mapping(address => RewardSnapshot)) private rewardSnapshots; // Trove地址 -> RewardSnapshot

	// Array of all active trove addresses - used to to compute an approximate hint off-chain, for the sorted list insertion
	// 所有活跃trove地址的数组 - 用于计算链下近似提示，用于排序列表插入
	mapping(address => address[]) public TroveOwners; // trove地址 -> owner地址

	// Error trackers for the trove redistribution calculation
	// 用于Trove再分配计算的错误跟踪器
	mapping(address => uint256) public lastETHError_Redistribution;
	mapping(address => uint256) public lastDCHFDebtError_Redistribution;

	bool public isInitialized;

	// Internal Function and Modifier onlyBorrowerOperations
	// @dev This workaround was needed in order to reduce bytecode size

	/*
	 * @note 检查调用者地址是否为BorrowerOperations地址或TroveManager地址
	 */
	function _onlyBOorTM() private view {
		require(
			msg.sender == borrowerOperationsAddress || msg.sender == troveManagerAddress,
			"WA"
		);
	}

	/*
	 * @note 检查调用者地址是否为BorrowerOperations地址或TroveManager地址
	 */
	modifier onlyBOorTM() {
		_onlyBOorTM();
		_;
	}

	/*
	 * @note 检查调用者地址是否为BorrowerOperations地址
	 */
	function _onlyBorrowerOperations() private view {
		require(msg.sender == borrowerOperationsAddress, "WA");
	}

	/*
	 * @note 检查调用者地址是否为BorrowerOperations地址
	 */
	modifier onlyBorrowerOperations() {
		_onlyBorrowerOperations();
		_;
	}

	/*
	 * @note 检查调用者地址是否为TroveManager地址
	 */
	function _onlyTroveManager() private view {
		require(msg.sender == troveManagerAddress, "WA");
	}

	/*
	 * @note 检查调用者地址是否为TroveManager地址
	 */
	modifier onlyTroveManager() {
		_onlyTroveManager();
		_;
	}

	/*
	 * @note 检查Trove是否活跃
	 */
	modifier troveIsActive(address _asset, address _borrower) {
		require(isTroveActive(_asset, _borrower), "IT");
		_;
	}

	// --- Dependency setter ---

	/*
	 * @note 初始化设置地址
	 * 		 1. 检查合约地址是否不为0地址以及检查调用的合约是否存在
	 * 		 2. 赋值
	 */
	function setAddresses(
		address _borrowerOperationsAddress,
		address _dchfTokenAddress,
		address _sortedTrovesAddress,
		address _dfrancParamsAddress,
		address _troveManagerAddress
	) external initializer {
		require(!isInitialized, "AI");
		checkContract(_borrowerOperationsAddress);
		checkContract(_dchfTokenAddress);
		checkContract(_sortedTrovesAddress);
		checkContract(_dfrancParamsAddress);
		checkContract(_troveManagerAddress);
		isInitialized = true;

		borrowerOperationsAddress = _borrowerOperationsAddress;
		dchfToken = IDCHFToken(_dchfTokenAddress);
		sortedTroves = ISortedTroves(_sortedTrovesAddress);
		troveManagerAddress = _troveManagerAddress;

		setDfrancParameters(_dfrancParamsAddress);
	}

	// --- Helper functions ---

	// Return the nominal collateral ratio (ICR) of a given Trove, without the price. Takes a trove's pending coll and debt rewards from redistributions into account.
	/*
	 * @note 返回给定Trove的个人名义抵押率(NICR),不带价格.将Trove从再分配中获取的待处理的collateral和债务奖励计入账户
	 */
	function getNominalICR(address _asset, address _borrower)
		public
		view
		override
		returns (uint256)
	{
		(uint256 currentAsset, uint256 currentDCHFDebt) = _getCurrentTroveAmounts(
			_asset,
			_borrower
		);

		uint256 NICR = DfrancMath._computeNominalCR(currentAsset, currentDCHFDebt);
		return NICR;
	}

	// Return the current collateral ratio (ICR) of a given Trove. Takes a trove's pending coll and debt rewards from redistributions into account.
	/*
	 * @note 返回给定Trove的个人抵押率(ICR).将Trove从再分配中获取的待处理的collateral和债务奖励计入账户
	 */
	function getCurrentICR(
		address _asset,
		address _borrower,
		uint256 _price
	) public view override returns (uint256) {
		(uint256 currentAsset, uint256 currentDCHFDebt) = _getCurrentTroveAmounts(
			_asset,
			_borrower
		);

		uint256 ICR = DfrancMath._computeCR(currentAsset, currentDCHFDebt, _price);
		return ICR;
	}

	/*
	 * @note 获取当前Trove的collateral和DCHF债务
	 */
	function _getCurrentTroveAmounts(address _asset, address _borrower)
		internal
		view
		returns (uint256, uint256)
	{
		uint256 pendingAssetReward = getPendingAssetReward(_asset, _borrower);
		uint256 pendingDCHFDebtReward = getPendingDCHFDebtReward(_asset, _borrower);

		uint256 currentAsset = Troves[_borrower][_asset].coll.add(pendingAssetReward);
		uint256 currentDCHFDebt = Troves[_borrower][_asset].debt.add(pendingDCHFDebtReward);

		return (currentAsset, currentDCHFDebt);
	}

	/*
	 * @note 将借贷者从再分配中获得的collateral和debt奖励发送到他们的trove中
	 */
	function applyPendingRewards(address _asset, address _borrower)
		external
		override
		onlyBorrowerOperations
	{
		return
			_applyPendingRewards(
				_asset,
				dfrancParams.activePool(),
				dfrancParams.defaultPool(),
				_borrower
			);
	}

	/*
	 * @note 将借贷者从再分配中获得的collateral和debt奖励发送到他们的trove中
	 */
	function applyPendingRewards(
		address _asset,
		IActivePool _activePool,
		IDefaultPool _defaultPool,
		address _borrower
	) external override onlyTroveManager {
		_applyPendingRewards(_asset, _activePool, _defaultPool, _borrower);
	}

	// Add the borrowers's coll and debt rewards earned from redistributions, to their Trove
	/*
	 * @note 将借贷者从再分配中获得的collateral和debt奖励发送到他们的trove中
	 */
	function _applyPendingRewards(
		address _asset,
		IActivePool _activePool,
		IDefaultPool _defaultPool,
		address _borrower
	) internal {
		if (!hasPendingRewards(_asset, _borrower)) {
			return;
		}

		assert(isTroveActive(_asset, _borrower));

		// Compute pending rewards 计算待处理的奖励
		uint256 pendingAssetReward = getPendingAssetReward(_asset, _borrower);
		uint256 pendingDCHFDebtReward = getPendingDCHFDebtReward(_asset, _borrower);

		// Apply pending rewards to trove's state
		Troves[_borrower][_asset].coll = Troves[_borrower][_asset].coll.add(pendingAssetReward);
		Troves[_borrower][_asset].debt = Troves[_borrower][_asset].debt.add(pendingDCHFDebtReward);

		_updateTroveRewardSnapshots(_asset, _borrower);

		// Transfer from DefaultPool to ActivePool
		_movePendingTroveRewardsToActivePool(
			_asset,
			_activePool,
			_defaultPool,
			pendingDCHFDebtReward,
			pendingAssetReward
		);

		emit TroveUpdated(
			_asset,
			_borrower,
			Troves[_borrower][_asset].debt,
			Troves[_borrower][_asset].coll,
			Troves[_borrower][_asset].stake,
			TroveManagerOperation.applyPendingRewards
		);
	}

	// Update borrower's snapshots of L_ETH and L_DCHFDebt to reflect the current values
	/*
	 * @note 更新借贷者的L_ETH和L_DCHFDebt快照以反映当前价值
	 */
	function updateTroveRewardSnapshots(address _asset, address _borrower)
		external
		override
		onlyBorrowerOperations
	{
		return _updateTroveRewardSnapshots(_asset, _borrower);
	}

	/*
	 * @note 更新借贷者的L_ETH和L_DCHFDebt快照以反映当前价值
	 */
	function _updateTroveRewardSnapshots(address _asset, address _borrower) internal {
		rewardSnapshots[_borrower][_asset].asset = L_ASSETS[_asset];
		rewardSnapshots[_borrower][_asset].DCHFDebt = L_DCHFDebts[_asset];
		emit TroveSnapshotsUpdated(_asset, L_ASSETS[_asset], L_DCHFDebts[_asset]);
	}

	// Get the borrower's pending accumulated ETH reward, earned by their stake
	/*
	 * @note 获取借贷者待处理的累积ETH奖励,通过其stake(股份/权益比例)赚取
	 */
	function getPendingAssetReward(address _asset, address _borrower)
		public
		view
		override
		returns (uint256)
	{
		uint256 snapshotAsset = rewardSnapshots[_borrower][_asset].asset;
		uint256 rewardPerUnitStaked = L_ASSETS[_asset].sub(snapshotAsset);

		if (rewardPerUnitStaked == 0 || !isTroveActive(_asset, _borrower)) {
			return 0;
		}

		uint256 stake = Troves[_borrower][_asset].stake;

		uint256 pendingAssetReward = stake.mul(rewardPerUnitStaked).div(DECIMAL_PRECISION);

		return pendingAssetReward;
	}

	// Get the borrower's pending accumulated DCHF reward, earned by their stake
	/*
	 * @note 获取借贷者待处理的累积DCHF奖励,通过其stake(股份/权益比例)赚取
	 */
	function getPendingDCHFDebtReward(address _asset, address _borrower)
		public
		view
		override
		returns (uint256)
	{
		uint256 snapshotDCHFDebt = rewardSnapshots[_borrower][_asset].DCHFDebt;
		uint256 rewardPerUnitStaked = L_DCHFDebts[_asset].sub(snapshotDCHFDebt);

		if (rewardPerUnitStaked == 0 || !isTroveActive(_asset, _borrower)) {
			return 0;
		}

		uint256 stake = Troves[_borrower][_asset].stake;

		uint256 pendingDCHFDebtReward = stake.mul(rewardPerUnitStaked).div(DECIMAL_PRECISION);

		return pendingDCHFDebtReward;
	}

	/*
	 * @note 判断借贷者是否有待处理的奖励
	 */
	function hasPendingRewards(address _asset, address _borrower)
		public
		view
		override
		returns (bool)
	{
		if (!isTroveActive(_asset, _borrower)) {
			return false;
		}

		return (rewardSnapshots[_borrower][_asset].asset < L_ASSETS[_asset]);
	}

	/*
	 * @note 获取全部debt和collateral(包括待处理的奖励)
	 */
	function getEntireDebtAndColl(address _asset, address _borrower)
		public
		view
		override
		returns (
			uint256 debt,
			uint256 coll,
			uint256 pendingDCHFDebtReward,
			uint256 pendingAssetReward
		)
	{
		debt = Troves[_borrower][_asset].debt;
		coll = Troves[_borrower][_asset].coll;

		pendingDCHFDebtReward = getPendingDCHFDebtReward(_asset, _borrower);
		pendingAssetReward = getPendingAssetReward(_asset, _borrower);

		debt = debt.add(pendingDCHFDebtReward);
		coll = coll.add(pendingAssetReward);
	}

	/*
	 * @note 移除_borrower对于_asset的stake(可理解为股份/权益比例)
	 */
	function removeStake(address _asset, address _borrower) external override onlyBOorTM {
		return _removeStake(_asset, _borrower);
	}

	/*
	 * @note 移除_borrower对于_asset的stake(可理解为股份/权益比例)
	 */
	function _removeStake(address _asset, address _borrower) internal {
		//add access control
		uint256 stake = Troves[_borrower][_asset].stake;
		totalStakes[_asset] = totalStakes[_asset].sub(stake);
		Troves[_borrower][_asset].stake = 0;
	}

	/*
	 * @note 根据借贷者的最新collateral的价值来更新他的stake(可理解为股份/权益比例)
	 */
	function updateStakeAndTotalStakes(address _asset, address _borrower)
		external
		override
		onlyBOorTM
		returns (uint256)
	{
		return _updateStakeAndTotalStakes(_asset, _borrower);
	}

	// Update borrower's stake based on their latest collateral value
	/*
	 * @note 根据借贷者的最新collateral的价值来更新他的stake(可理解为股份/权益比例)
	 */
	function _updateStakeAndTotalStakes(address _asset, address _borrower)
		internal
		returns (uint256)
	{
		uint256 newStake = _computeNewStake(_asset, Troves[_borrower][_asset].coll);
		uint256 oldStake = Troves[_borrower][_asset].stake;
		Troves[_borrower][_asset].stake = newStake;

		totalStakes[_asset] = totalStakes[_asset].sub(oldStake).add(newStake);
		emit TotalStakesUpdated(_asset, totalStakes[_asset]);

		return newStake;
	}

	// Calculate a new stake based on the snapshots of the totalStakes and totalCollateral taken at the last liquidation
	/*
	 * @note 根据上次清算时的总stake和总collateral的快照计算新stake
	 */
	function _computeNewStake(address _asset, uint256 _coll) internal view returns (uint256) {
		uint256 stake;
		if (totalCollateralSnapshot[_asset] == 0) {
			stake = _coll;
		} else {
			/*
			 * The following assert() holds true because:
			 * - The system always contains >= 1 trove
			 * - When we close or liquidate a trove, we redistribute the pending rewards, so if all troves were closed/liquidated,
			 * rewards would’ve been emptied and totalCollateralSnapshot would be zero too.
			 * 以下assert()成立,因为:
			 * - 系统始终包含至少一个Trove
			 * - 当我们关闭或清算一个Trove时,我们会再分配待处理的奖励,所以如果所有Trove都被清算,奖励将被清空,totalCollateralSnapshot也将为零
			 */
			assert(totalStakesSnapshot[_asset] > 0);
			stake = _coll.mul(totalStakesSnapshot[_asset]).div(totalCollateralSnapshot[_asset]);
		}
		return stake;
	}

	/*
	 * @note debt和collateral再分配
	 */
	function redistributeDebtAndColl(
		address _asset,
		IActivePool _activePool,
		IDefaultPool _defaultPool,
		uint256 _debt,
		uint256 _coll
	) external override onlyTroveManager {
		_redistributeDebtAndColl(_asset, _activePool, _defaultPool, _debt, _coll);
	}

	/*
	 * @note debt和collateral再分配
	 */
	function _redistributeDebtAndColl(
		address _asset,
		IActivePool _activePool,
		IDefaultPool _defaultPool,
		uint256 _debt,
		uint256 _coll
	) internal {
		if (_debt == 0) {
			return;
		}

		/*
		 * Add distributed coll and debt rewards-per-unit-staked to the running totals. Division uses a "feedback"
		 * error correction, to keep the cumulative error low in the running totals L_ETH and L_DCHFDebt:
		 * 将抵押物和债务再分配中的每单位质押奖励添加到运行总计中.除法使用“反馈”纠错,以保持运行总计L_ETH和L_DCHFDebt中的累积误差较低:
		 *
		 * 1) Form numerators which compensate for the floor division errors that occurred the last time this
		 * function was called.
		 * 2) Calculate "per-unit-staked" ratios.
		 * 3) Multiply each ratio back by its denominator, to reveal the current floor division error.
		 * 4) Store these errors for use in the next correction when this function is called.
		 * 5) Note: static analysis tools complain about this "division before multiplication", however, it is intended.
		 *
		 * 1) 形成一个numerator,用于补偿上次调用此函数时发生的floor(个人理解为地板价)除法误差
		 * 2) 计算“每单位stake”比率
		 * 3) 将比率乘以其分母,以显示当前的floor(个人理解为地板价)除法误差
		 * 4) 存储此错误,以便在调用此函数时用于下一次更正
		 * 5) 注意:静态分析工具抱怨这种“除法后乘法”,但是这是有意的
		 */
		uint256 ETHNumerator = _coll.mul(DECIMAL_PRECISION).add(
			lastETHError_Redistribution[_asset]
		);
		uint256 DCHFDebtNumerator = _debt.mul(DECIMAL_PRECISION).add(
			lastDCHFDebtError_Redistribution[_asset]
		);

		// Get the per-unit-staked terms
		uint256 ETHRewardPerUnitStaked = ETHNumerator.div(totalStakes[_asset]);
		uint256 DCHFDebtRewardPerUnitStaked = DCHFDebtNumerator.div(totalStakes[_asset]);

		lastETHError_Redistribution[_asset] = ETHNumerator.sub(
			ETHRewardPerUnitStaked.mul(totalStakes[_asset])
		);
		lastDCHFDebtError_Redistribution[_asset] = DCHFDebtNumerator.sub(
			DCHFDebtRewardPerUnitStaked.mul(totalStakes[_asset])
		);

		// Add per-unit-staked terms to the running totals
		L_ASSETS[_asset] = L_ASSETS[_asset].add(ETHRewardPerUnitStaked);
		L_DCHFDebts[_asset] = L_DCHFDebts[_asset].add(DCHFDebtRewardPerUnitStaked);

		emit LTermsUpdated(_asset, L_ASSETS[_asset], L_DCHFDebts[_asset]);

		_activePool.decreaseDCHFDebt(_asset, _debt);
		_defaultPool.increaseDCHFDebt(_asset, _debt);
		_activePool.sendAsset(_asset, address(_defaultPool), _coll);
	}

	/*
	 * @note 关闭trove并将关闭状态标记为被owner关闭
	 */
	function closeTrove(address _asset, address _borrower)
		external
		override
		onlyBorrowerOperations
	{
		return _closeTrove(_asset, _borrower, Status.closedByOwner);
	}

	/*
	 * @note 关闭trove并设置关闭状态
	 */
	function closeTrove(
		address _asset,
		address _borrower,
		Status closedStatus
	) external override onlyTroveManager {
		_closeTrove(_asset, _borrower, closedStatus);
	}

	/*
	 * @note 关闭trove并设置关闭状态
	 */
	function _closeTrove(
		// access control
		address _asset,
		address _borrower,
		Status closedStatus
	) internal {
		// 检查trove是否已被关闭
		assert(closedStatus != Status.nonExistent && closedStatus != Status.active);

		uint256 TroveOwnersArrayLength = TroveOwners[_asset].length;
		// 检查系统中至少有1个以上的trove
		_requireMoreThanOneTroveInSystem(_asset, TroveOwnersArrayLength);

		// 清空collateral和debt并标记关闭的状态
		Troves[_borrower][_asset].status = closedStatus;
		Troves[_borrower][_asset].coll = 0;
		Troves[_borrower][_asset].debt = 0;

		// 清空rewardSnapshots(奖励快照)中的collateral和DCHF债务
		rewardSnapshots[_borrower][_asset].asset = 0;
		rewardSnapshots[_borrower][_asset].DCHFDebt = 0;

		_removeTroveOwner(_asset, _borrower, TroveOwnersArrayLength);
		// 从sortedTrove列表中移除该trove
		sortedTroves.remove(_asset, _borrower);
	}

	/*
	 * @note 更新系统快照除去剩余的collateral
	 */
	function updateSystemSnapshots_excludeCollRemainder(
		address _asset,
		IActivePool _activePool,
		uint256 _collRemainder
	) external override onlyTroveManager {
		_updateSystemSnapshots_excludeCollRemainder(_asset, _activePool, _collRemainder);
	}

	/*
	 * @note 更新系统快照除去剩余的collateral
	 */
	function _updateSystemSnapshots_excludeCollRemainder(
		address _asset,
		IActivePool _activePool,
		uint256 _collRemainder
	) internal {
		totalStakesSnapshot[_asset] = totalStakes[_asset];

		uint256 activeColl = _activePool.getAssetBalance(_asset);
		uint256 liquidatedColl = dfrancParams.defaultPool().getAssetBalance(_asset);
		totalCollateralSnapshot[_asset] = activeColl.sub(_collRemainder).add(liquidatedColl);

		emit SystemSnapshotsUpdated(
			_asset,
			totalStakesSnapshot[_asset],
			totalCollateralSnapshot[_asset]
		);
	}

	/*
	 * @note 将trove的拥有者添加到数组中并返回其在数组的下标
	 */
	function addTroveOwnerToArray(address _asset, address _borrower)
		external
		override
		onlyBorrowerOperations
		returns (uint256 index)
	{
		return _addTroveOwnerToArray(_asset, _borrower);
	}

	/*
	 * @note 将trove的拥有者添加到数组中并返回其在数组的下标
	 */
	function _addTroveOwnerToArray(address _asset, address _borrower)
		internal
		returns (uint128 index)
	{
		TroveOwners[_asset].push(_borrower);

		index = uint128(TroveOwners[_asset].length.sub(1));
		Troves[_borrower][_asset].arrayIndex = index;

		return index;
	}

	/*
	 * @note 移除trove的owner
	 */
	function _removeTroveOwner(
		address _asset,
		address _borrower,
		uint256 TroveOwnersArrayLength
	) internal {
		Status troveStatus = Troves[_borrower][_asset].status;
		// 判断该trove是否已经被关闭
		assert(troveStatus != Status.nonExistent && troveStatus != Status.active);

		uint128 index = Troves[_borrower][_asset].arrayIndex;
		uint256 length = TroveOwnersArrayLength;
		uint256 idxLast = length.sub(1); // 获取在mapping中最后一个trove的位置

		// 防溢出
		assert(index <= idxLast);

		// 获取trove的owner
		address addressToMove = TroveOwners[_asset][idxLast];

		// 把最后一个trove替换到要删除的trove的位置
		TroveOwners[_asset][index] = addressToMove;
		Troves[addressToMove][_asset].arrayIndex = index;
		emit TroveIndexUpdated(_asset, addressToMove, index);

		TroveOwners[_asset].pop();
	}

	/*
	 * @note 获取TCR(系统总抵押率)
	 */
	function getTCR(address _asset, uint256 _price) external view override returns (uint256) {
		return _getTCR(_asset, _price);
	}

	/*
	 * @note 检查是否处于恢复模式(TCR < CCR)
	 */
	function checkRecoveryMode(address _asset, uint256 _price)
		external
		view
		override
		returns (bool)
	{
		return _checkRecoveryMode(_asset, _price);
	}

	/*
	 * @note 检查是否处于恢复模式(TCR < CCR)
	 */
	function _checkPotentialRecoveryMode(
		address _asset,
		uint256 _entireSystemColl,
		uint256 _entireSystemDebt,
		uint256 _price
	) public view override returns (bool) {
		uint256 TCR = DfrancMath._computeCR(_entireSystemColl, _entireSystemDebt, _price);

		return TCR < dfrancParams.CCR(_asset);
	}

	/*
	 * @note 从赎回中更新基本费率
	 */
	function updateBaseRateFromRedemption(
		address _asset,
		uint256 _ETHDrawn,
		uint256 _price,
		uint256 _totalDCHFSupply
	) external override onlyTroveManager returns (uint256) {
		return _updateBaseRateFromRedemption(_asset, _ETHDrawn, _price, _totalDCHFSupply);
	}

	/*
	 * @note 从赎回中更新基本费率
	 */
	function _updateBaseRateFromRedemption(
		address _asset,
		uint256 _ETHDrawn,
		uint256 _price,
		uint256 _totalDCHFSupply
	) internal returns (uint256) {
		uint256 decayedBaseRate = _calcDecayedBaseRate(_asset);

		uint256 redeemedDCHFFraction = _ETHDrawn.mul(_price).div(_totalDCHFSupply);

		uint256 newBaseRate = decayedBaseRate.add(redeemedDCHFFraction.div(BETA));
		newBaseRate = DfrancMath._min(newBaseRate, DECIMAL_PRECISION);
		assert(newBaseRate > 0);

		baseRate[_asset] = newBaseRate;
		emit BaseRateUpdated(_asset, newBaseRate);

		_updateLastFeeOpTime(_asset);

		return newBaseRate;
	}

	/*
	 * @note 获取赎回费率
	 */
	function getRedemptionRate(address _asset) public view override returns (uint256) {
		return _calcRedemptionRate(_asset, baseRate[_asset]);
	}

	/*
	 * @note 获取衰减后的赎回费率
	 */
	function getRedemptionRateWithDecay(address _asset) public view override returns (uint256) {
		return _calcRedemptionRate(_asset, _calcDecayedBaseRate(_asset));
	}

	/*
	 * @note 计算赎回费率
	 */
	function _calcRedemptionRate(address _asset, uint256 _baseRate)
		internal
		view
		returns (uint256)
	{
		return
			DfrancMath._min(
				dfrancParams.REDEMPTION_FEE_FLOOR(_asset).add(_baseRate),
				DECIMAL_PRECISION
			);
	}

	/*
	 * @note 获取衰减费用
	 */
	function _getRedemptionFee(address _asset, uint256 _assetDraw)
		public
		view
		override
		returns (uint256)
	{
		return _calcRedemptionFee(getRedemptionRate(_asset), _assetDraw);
	}

	/*
	 * @note 获取衰减后的赎回费用
	 */
	function getRedemptionFeeWithDecay(address _asset, uint256 _assetDraw)
		external
		view
		override
		returns (uint256)
	{
		return _calcRedemptionFee(getRedemptionRateWithDecay(_asset), _assetDraw);
	}

	/*
	 * @note 计算赎回费用
	 */
	function _calcRedemptionFee(uint256 _redemptionRate, uint256 _assetDraw)
		internal
		pure
		returns (uint256)
	{
		uint256 redemptionFee = _redemptionRate.mul(_assetDraw).div(DECIMAL_PRECISION);
		require(redemptionFee < _assetDraw, "FE");
		return redemptionFee;
	}

	/*
	 * @note 获取借贷费率
	 */
	function getBorrowingRate(address _asset) public view override returns (uint256) {
		return _calcBorrowingRate(_asset, baseRate[_asset]);
	}

	/*
	 * @note 获取衰减后的借贷费率
	 */
	function getBorrowingRateWithDecay(address _asset) public view override returns (uint256) {
		return _calcBorrowingRate(_asset, _calcDecayedBaseRate(_asset));
	}

	/*
	 * @note 计算借贷费率
	 */
	function _calcBorrowingRate(address _asset, uint256 _baseRate)
		internal
		view
		returns (uint256)
	{
		return
			DfrancMath._min(
				dfrancParams.BORROWING_FEE_FLOOR(_asset).add(_baseRate),
				dfrancParams.MAX_BORROWING_FEE(_asset)
			);
	}

	/*
	 * @note 获取借贷费用
	 */
	function getBorrowingFee(address _asset, uint256 _DCHFDebt)
		external
		view
		override
		returns (uint256)
	{
		return _calcBorrowingFee(getBorrowingRate(_asset), _DCHFDebt);
	}

	/*
	 * @note 获取衰变后的借贷费用
	 */
	function getBorrowingFeeWithDecay(address _asset, uint256 _DCHFDebt)
		external
		view
		returns (uint256)
	{
		return _calcBorrowingFee(getBorrowingRateWithDecay(_asset), _DCHFDebt);
	}

	/*
	 * @note 计算借贷费用
	 */
	function _calcBorrowingFee(uint256 _borrowingRate, uint256 _DCHFDebt)
		internal
		pure
		returns (uint256)
	{
		return _borrowingRate.mul(_DCHFDebt).div(DECIMAL_PRECISION);
	}

	/*
	 * @note 从借贷中衰减基本费率
	 */
	function decayBaseRateFromBorrowing(address _asset)
		external
		override
		onlyBorrowerOperations
	{
		// 计算衰减之后的基本费率
		uint256 decayedBaseRate = _calcDecayedBaseRate(_asset);
		assert(decayedBaseRate <= DECIMAL_PRECISION);

		baseRate[_asset] = decayedBaseRate;
		emit BaseRateUpdated(_asset, decayedBaseRate);

		_updateLastFeeOpTime(_asset);
	}

	// Update the last fee operation time only if time passed >= decay interval. This prevents base rate griefing.
	/*
	 * @note 仅当经过的时间大于等于衰减间隔时,才更新上次费用操作时间.这可以防止基本费率的下降
	 */
	function _updateLastFeeOpTime(address _asset) internal {
		uint256 timePassed = block.timestamp.sub(lastFeeOperationTime[_asset]);

		if (timePassed >= SECONDS_IN_ONE_MINUTE) {
			lastFeeOperationTime[_asset] = block.timestamp;
			emit LastFeeOpTimeUpdated(_asset, block.timestamp);
		}
	}

	/*
	 * @note 计算衰减之后的基本费率
	 */
	function _calcDecayedBaseRate(address _asset) public view returns (uint256) {
		uint256 minutesPassed = _minutesPassedSinceLastFeeOp(_asset);
		// 计算衰减因子
		uint256 decayFactor = DfrancMath._decPow(MINUTE_DECAY_FACTOR, minutesPassed);

		return baseRate[_asset].mul(decayFactor).div(DECIMAL_PRECISION); // 基本费率 * 衰减因子 / 小数精度
	}

	/*
	 * @note 计算从最后一次费用操作到现在过去的时间(以分钟计数)
	 */
	function _minutesPassedSinceLastFeeOp(address _asset) internal view returns (uint256) {
		return (block.timestamp.sub(lastFeeOperationTime[_asset])).div(SECONDS_IN_ONE_MINUTE); // (当前时间戳 - 最后一次fee操作的时间) / 60(秒->分钟)
	}

	/*
	 * @note 检查DCHF余额是否大于等于赎回数量
	 */
	function _requireDCHFBalanceCoversRedemption(
		IDCHFToken _dchfToken,
		address _redeemer,
		uint256 _amount
	) public view override {
		require(_dchfToken.balanceOf(_redeemer) >= _amount, "RR");
	}

	/*
	 * @note 检查系统中至少有1个以上的trove
	 */
	function _requireMoreThanOneTroveInSystem(address _asset, uint256 TroveOwnersArrayLength)
		internal
		view
	{
		require(TroveOwnersArrayLength > 1 && sortedTroves.getSize(_asset) > 1, "OO");
	}

	/*
	 * @note 检查_amount是否大于0
	 */
	function _requireAmountGreaterThanZero(uint256 _amount) public pure override {
		require(_amount > 0, "AG");
	}

	/*
	 * @note 检查TCR(系统总抵押率)是否大于等于MCR(最小抵押率)
	 */
	function _requireTCRoverMCR(address _asset, uint256 _price) external view override {
		require(_getTCR(_asset, _price) >= dfrancParams.MCR(_asset), "CR");
	}

	/*
	 * @note 检查最高费用比例是否合法
	 */
	function _requireValidMaxFeePercentage(address _asset, uint256 _maxFeePercentage)
		public
		view
		override
	{
		require(
			_maxFeePercentage >= dfrancParams.REDEMPTION_FEE_FLOOR(_asset) &&
				_maxFeePercentage <= DECIMAL_PRECISION,
			"MF"
		);
	}

	/*
	 * @note 检查Trove是否活跃
	 */
	function isTroveActive(address _asset, address _borrower)
		public
		view
		override
		returns (bool)
	{
		return this.getTroveStatus(_asset, _borrower) == uint256(Status.active);
	}

	// --- Trove owners getters ---

	/*
	 * @note 获取troveOwner列表的长度
	 */
	function getTroveOwnersCount(address _asset) external view override returns (uint256) {
		return TroveOwners[_asset].length;
	}

	/*
	 * @note 根据_index从TroveOwners数组获取trove
	 */
	function getTroveFromTroveOwnersArray(address _asset, uint256 _index)
		external
		view
		override
		returns (address)
	{
		return TroveOwners[_asset][_index];
	}

	// --- Trove property getters ---

	/*
	 * @note 获取Trove
	 */
	function getTrove(address _asset, address _borrower)
		external
		view
		override
		returns (
			address,
			uint256,
			uint256,
			uint256,
			Status,
			uint128
		)
	{
		Trove memory _trove = Troves[_borrower][_asset];
		return (
			_trove.asset,
			_trove.debt,
			_trove.coll,
			_trove.stake,
			_trove.status,
			_trove.arrayIndex
		);
	}

	/*
	 * @note 获取Trove的状态
	 */
	function getTroveStatus(address _asset, address _borrower)
		external
		view
		override
		returns (uint256)
	{
		return uint256(Troves[_borrower][_asset].status);
	}

	/*
	 * @note 获取Trove的stake
	 */
	function getTroveStake(address _asset, address _borrower)
		external
		view
		override
		returns (uint256)
	{
		return Troves[_borrower][_asset].stake;
	}

	/*
	 * @note 获取Trove的debt
	 */
	function getTroveDebt(address _asset, address _borrower)
		external
		view
		override
		returns (uint256)
	{
		return Troves[_borrower][_asset].debt;
	}

	/*
	 * @note 获取Trove的collateral
	 */
	function getTroveColl(address _asset, address _borrower)
		external
		view
		override
		returns (uint256)
	{
		return Troves[_borrower][_asset].coll;
	}

	// --- Trove property setters, called by TroveManager ---
	/*
	 * @note 设置Trove的debt和collateral
	 */
	function setTroveDeptAndColl(
		address _asset,
		address _borrower,
		uint256 _debt,
		uint256 _coll
	) external override onlyTroveManager {
		Troves[_borrower][_asset].debt = _debt;
		Troves[_borrower][_asset].coll = _coll;
	}

	// --- Trove property setters, called by BorrowerOperations ---

	/*
	 * @note 设置Trove的状态
	 */
	function setTroveStatus(
		address _asset,
		address _borrower,
		uint256 _num
	) external override onlyBorrowerOperations {
		Troves[_borrower][_asset].asset = _asset;
		Troves[_borrower][_asset].status = Status(_num);
	}

	/*
	 * @note 减少Trove的collateral
	 */
	function decreaseTroveColl(
		address _asset,
		address _borrower,
		uint256 _collDecrease
	) external override onlyBorrowerOperations returns (uint256) {
		uint256 newColl = Troves[_borrower][_asset].coll.sub(_collDecrease);
		Troves[_borrower][_asset].coll = newColl;
		return newColl;
	}

	/*
	 * @note 增加trove的debt
	 */
	function increaseTroveDebt(
		address _asset,
		address _borrower,
		uint256 _debtIncrease
	) external override onlyBorrowerOperations returns (uint256) {
		uint256 newDebt = Troves[_borrower][_asset].debt.add(_debtIncrease);
		Troves[_borrower][_asset].debt = newDebt;
		return newDebt;
	}

	/*
	 * @note 减少Trove的debt
	 */
	function decreaseTroveDebt(
		address _asset,
		address _borrower,
		uint256 _debtDecrease
	) external override onlyBorrowerOperations returns (uint256) {
		uint256 newDebt = Troves[_borrower][_asset].debt.sub(_debtDecrease);
		Troves[_borrower][_asset].debt = newDebt;
		return newDebt;
	}

	/*
	 * @note 增加trove的collateral
	 */
	function increaseTroveColl(
		address _asset,
		address _borrower,
		uint256 _collIncrease
	) external override onlyBorrowerOperations returns (uint256) {
		uint256 newColl = Troves[_borrower][_asset].coll.add(_collIncrease);
		Troves[_borrower][_asset].coll = newColl;
		return newColl;
	}

	/*
	 * @note 将Trove待处理的从再分配得到的debt和collateral奖励中从Default Pool移动到Active Pool
	 */
	function movePendingTroveRewardsToActivePool(
		address _asset,
		IActivePool _activePool,
		IDefaultPool _defaultPool,
		uint256 _DCHF,
		uint256 _amount
	) external override onlyTroveManager {
		_movePendingTroveRewardsToActivePool(_asset, _activePool, _defaultPool, _DCHF, _amount);
	}

	// Move a Trove's pending debt and collateral rewards from distributions, from the Default Pool to the Active Pool
	/*
	 * @note 将Trove待处理的从再分配得到的debt和collateral奖励中从Default Pool移动到Active Pool
	 */
	function _movePendingTroveRewardsToActivePool(
		address _asset,
		IActivePool _activePool,
		IDefaultPool _defaultPool,
		uint256 _DCHF,
		uint256 _amount
	) internal {
		_defaultPool.decreaseDCHFDebt(_asset, _DCHF);
		_activePool.increaseDCHFDebt(_asset, _DCHF);
		_defaultPool.sendAssetToActivePool(_asset, _amount);
	}

	/*
	 * @note 获取奖励快照
	 */
	function getRewardSnapshots(address _asset, address _troveOwner)
		external
		view
		override
		returns (uint256 asset, uint256 DCHFDebt)
	{
		RewardSnapshot memory _rewardSnapshot = rewardSnapshots[_asset][_troveOwner];
		return (_rewardSnapshot.asset, _rewardSnapshot.DCHFDebt);
	}
}
