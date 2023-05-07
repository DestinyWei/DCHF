// SPDX-License-Identifier: MIT

pragma solidity ^0.8.14;

import "./Interfaces/ITroveManager.sol";
import "./Dependencies/DfrancBase.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/Initializable.sol";
import "./Interfaces/ITroveManagerHelpers.sol";

/*
 * @notice Trove管理者合约
 *
 * @note 包含的内容如下:
 *		modifier troveIsActive(address _asset, address _borrower) 												检查Trove是否活跃
 *		function setAddresses(address _stabilityPoolManagerAddress, address _gasPoolAddress,
							  address _collSurplusPoolAddress, address _dchfTokenAddress,
							  address _sortedTrovesAddress, address _monStakingAddress,
							  address _dfrancParamsAddress, address _troveManagerHelpersAddress) 				初始化设置地址 1. 检查合约地址是否不为0地址以及检查调用的合约是否存在 2. 赋值
 *		function isContractTroveManager() 																		判断是否为Trove管理者合约(直接返回True)
 *		function liquidate(address _asset, address _borrower) 													单一清算函数.如果ICR低于最低抵押率,则关闭Trove
 *		function _liquidateNormalMode(address _asset, IActivePool _activePool, IDefaultPool _defaultPool,
									  address _borrower, uint256 _DCHFInStabPool) 								在正常模块中清算一个Trove
 *		function _liquidateRecoveryMode(address _asset, IActivePool _activePool, IDefaultPool _defaultPool,
										address _borrower, uint256 _ICR, uint256 _DCHFInStabPool,
										uint256 _TCR, uint256 _price) 											在恢复模块中清算一个Trove
 *		function _getOffsetAndRedistributionVals(uint256 _debt, uint256 _coll, uint256 _DCHFInStabPool) 		在完全清算中,获取要抵消的Trove的collateral和债务的值,以及要重新分配给活动Trove的collateral和债务的值
 *		function _getCappedOffsetVals(address _asset, uint256 _entireTroveDebt, uint256 _entireTroveColl,
									  uint256 _price) 															获取其抵消的collateral/债务和ETH气体补偿,并关闭Trove
 *		function liquidateTroves(address _asset, uint256 _n) 													清算一系列Trove.关闭最大数量的n个抵押不足的Troves,从系统中抵押率最低的那个开始,然后逐步向上移动
 *		function _getTotalsFromLiquidateTrovesSequence_RecoveryMode(address _asset,
									  ContractsCache memory _contractsCache, uint256 _price,
									  uint256 _DCHFInStabPool, uint256 _n) 										从处于恢复模式下的清算Troves序列中获取各种总和值
 *		function _getTotalsFromLiquidateTrovesSequence_NormalMode(address _asset, IActivePool _activePool,
									  IDefaultPool _defaultPool, uint256 _price, uint256 _DCHFInStabPool,
									  uint256 _n) 																从处于正常模式下的Troves序列中获取各种总和值
 *		function batchLiquidateTroves(address _asset, address[] memory _troveArray) 							批量清算给定的Trove数组
 *		function _getTotalFromBatchLiquidate_RecoveryMode(address _asset, IActivePool _activePool,
									  IDefaultPool _defaultPool, uint256 _price, uint256 _DCHFInStabPool,
									  address[] memory _troveArray) 											从处于恢复模式下的批量清算中获取各种总和值
 *		function _getTotalsFromBatchLiquidate_NormalMode(address _asset, IActivePool _activePool,
									  IDefaultPool _defaultPool, uint256 _price, uint256 _DCHFInStabPool,
									  address[] memory _troveArray) 											从处于正常模式下的批量清算中获取各种总和值
 *		function _addLiquidationValuesToTotals(LiquidationTotals memory oldTotals,
											   LiquidationValues memory singleLiquidation) 						将清算值添加到各自的运行总计中
 *		function _sendGasCompensation(address _asset, IActivePool _activePool, address _liquidator,
									  uint256 _DCHF, uint256 _ETH) 												发送gas补偿给清算者
 *		function _redeemCollateralFromTrove(address _asset, ContractsCache memory _contractsCache,
									  		address _borrower, uint256 _maxDCHFamount, uint256 _price,
									  		address _upperPartialRedemptionHint,
									  		address _lowerPartialRedemptionHint,
									  		uint256 _partialRedemptionHintNICR) 								从Trove中赎回抵押物
 *		function _redeemCloseTrove(address _asset, ContractsCache memory _contractsCache,
								   address _borrower, uint256 _DCHF, uint256 _ETH) 								赎回关闭了的Trove
 *		function _isValidFirstRedemptionHint(address _asset, ISortedTroves _sortedTroves,
											 address _firstRedemptionHint, uint256 _price) 						判断首次赎回提示是否有效
 *		function setRedemptionWhitelistStatus(bool _status) 													设置赎回白名单状态
 *		function addUserToWhitelistRedemption(address _user) 													添加用户到赎回白名单中
 *		function removeUserFromWhitelistRedemption(address _user) 												从赎回白名单中删除用户
 *		function redeemCollateral(address _asset, uint256 _DCHFamount, address _firstRedemptionHint,
								  address _upperPartialRedemptionHint, address _lowerPartialRedemptionHint,
								  uint256 _partialRedemptionHintNICR, uint256 _maxIterations,
								  uint256 _maxFeePercentage) 													赎回抵押物
 */
contract TroveManager is DfrancBase, CheckContract, Initializable, ITroveManager {
	using SafeMath for uint256;
	string public constant NAME = "TroveManager";

	// --- Connected contract declarations ---

	ITroveManagerHelpers public troveManagerHelpers;

	IStabilityPoolManager public stabilityPoolManager;

	address gasPoolAddress;

	ICollSurplusPool collSurplusPool;

	IDCHFToken public override dchfToken;

	IMONStaking public override monStaking;

	// A doubly linked list of Troves, sorted by their sorted by their collateral ratios
	// Troves的双向链表,按抵押率排序
	ISortedTroves public sortedTroves;

	// --- Data structures ---

	bool public isInitialized;

	mapping(address => bool) public redemptionWhitelist;
	bool public isRedemptionWhitelisted;

	// Internal Function and Modifier onlyBorrowerOperations
	// @dev This workaround was needed in order to reduce bytecode size

	/*
	 * @note 检查Trove是否活跃
	 */
	modifier troveIsActive(address _asset, address _borrower) {
		require(troveManagerHelpers.isTroveActive(_asset, _borrower), "IT");
		_;
	}

	// --- Dependency setter ---

	/*
	 * @note 初始化设置地址
	 * 		 1. 检查合约地址是否不为0地址以及检查调用的合约是否存在
	 * 		 2. 赋值
	 */
	function setAddresses(
		address _stabilityPoolManagerAddress,
		address _gasPoolAddress,
		address _collSurplusPoolAddress,
		address _dchfTokenAddress,
		address _sortedTrovesAddress,
		address _monStakingAddress,
		address _dfrancParamsAddress,
		address _troveManagerHelpersAddress
	) external override initializer {
		require(!isInitialized, "AI");
		checkContract(_stabilityPoolManagerAddress);
		checkContract(_gasPoolAddress);
		checkContract(_collSurplusPoolAddress);
		checkContract(_dchfTokenAddress);
		checkContract(_sortedTrovesAddress);
		checkContract(_monStakingAddress);
		checkContract(_dfrancParamsAddress);
		checkContract(_troveManagerHelpersAddress);
		isInitialized = true;

		stabilityPoolManager = IStabilityPoolManager(_stabilityPoolManagerAddress);
		gasPoolAddress = _gasPoolAddress;
		collSurplusPool = ICollSurplusPool(_collSurplusPoolAddress);
		dchfToken = IDCHFToken(_dchfTokenAddress);
		sortedTroves = ISortedTroves(_sortedTrovesAddress);
		monStaking = IMONStaking(_monStakingAddress);
		troveManagerHelpers = ITroveManagerHelpers(_troveManagerHelpersAddress);

		setDfrancParameters(_dfrancParamsAddress);
	}

	// --- Trove Getter functions ---

	/*
	 * @note 判断是否为Trove管理者合约(直接返回True)
	 */
	function isContractTroveManager() public pure returns (bool) {
		return true;
	}

	// --- Trove Liquidation functions ---

	// Single liquidation function. Closes the trove if its ICR is lower than the minimum collateral ratio.
	/*
	 * @note 单一清算函数.如果ICR低于最低抵押率,则关闭Trove
	 */
	function liquidate(address _asset, address _borrower)
		external
		override
		troveIsActive(_asset, _borrower)
	{
		address[] memory borrowers = new address[](1);
		borrowers[0] = _borrower;
		batchLiquidateTroves(_asset, borrowers);
	}

	// --- Inner single liquidation functions ---

	// Liquidate one trove, in Normal Mode.
	/*
	 * @note 在正常模块中清算一个Trove
	 */
	function _liquidateNormalMode(
		address _asset,
		IActivePool _activePool,
		IDefaultPool _defaultPool,
		address _borrower,
		uint256 _DCHFInStabPool
	) internal returns (LiquidationValues memory singleLiquidation) {
		LocalVariables_InnerSingleLiquidateFunction memory vars;

		(
			singleLiquidation.entireTroveDebt,
			singleLiquidation.entireTroveColl,
			vars.pendingDebtReward,
			vars.pendingCollReward
		) = troveManagerHelpers.getEntireDebtAndColl(_asset, _borrower);

		troveManagerHelpers.movePendingTroveRewardsToActivePool(
			_asset,
			_activePool,
			_defaultPool,
			vars.pendingDebtReward,
			vars.pendingCollReward
		);
		troveManagerHelpers.removeStake(_asset, _borrower);

		singleLiquidation.collGasCompensation = _getCollGasCompensation(
			_asset,
			singleLiquidation.entireTroveColl
		);
		singleLiquidation.DCHFGasCompensation = dfrancParams.DCHF_GAS_COMPENSATION(_asset);
		uint256 collToLiquidate = singleLiquidation.entireTroveColl.sub(
			singleLiquidation.collGasCompensation
		);

		(
			singleLiquidation.debtToOffset,
			singleLiquidation.collToSendToSP,
			singleLiquidation.debtToRedistribute,
			singleLiquidation.collToRedistribute
		) = _getOffsetAndRedistributionVals(
			singleLiquidation.entireTroveDebt,
			collToLiquidate,
			_DCHFInStabPool
		);

		troveManagerHelpers.closeTrove(
			_asset,
			_borrower,
			ITroveManagerHelpers.Status.closedByLiquidation
		);
		emit TroveLiquidated(
			_asset,
			_borrower,
			singleLiquidation.entireTroveDebt,
			singleLiquidation.entireTroveColl,
			TroveManagerOperation.liquidateInNormalMode
		);
		emit TroveUpdated(_asset, _borrower, 0, 0, 0, TroveManagerOperation.liquidateInNormalMode);
		return singleLiquidation;
	}

	// Liquidate one trove, in Recovery Mode.
	/*
	 * @note 在恢复模块中清算一个Trove
	 */
	function _liquidateRecoveryMode(
		address _asset,
		IActivePool _activePool,
		IDefaultPool _defaultPool,
		address _borrower,
		uint256 _ICR,
		uint256 _DCHFInStabPool,
		uint256 _TCR,
		uint256 _price
	) internal returns (LiquidationValues memory singleLiquidation) {
		LocalVariables_InnerSingleLiquidateFunction memory vars;
		if (troveManagerHelpers.getTroveOwnersCount(_asset) <= 1) {
			return singleLiquidation;
		} // don't liquidate if last trove 如果只剩一个Trove,则不清算
		(
			singleLiquidation.entireTroveDebt,
			singleLiquidation.entireTroveColl,
			vars.pendingDebtReward,
			vars.pendingCollReward
		) = troveManagerHelpers.getEntireDebtAndColl(_asset, _borrower);

		singleLiquidation.collGasCompensation = _getCollGasCompensation(
			_asset,
			singleLiquidation.entireTroveColl
		);
		singleLiquidation.DCHFGasCompensation = dfrancParams.DCHF_GAS_COMPENSATION(_asset);
		vars.collToLiquidate = singleLiquidation.entireTroveColl.sub(
			singleLiquidation.collGasCompensation
		);

		// If ICR <= 100%, purely redistribute the Trove across all active Troves
		// 如果 ICR <= 100%,则纯粹将Trove再分配给所有Active Troves
		if (_ICR <= dfrancParams._100pct()) {
			troveManagerHelpers.movePendingTroveRewardsToActivePool(
				_asset,
				_activePool,
				_defaultPool,
				vars.pendingDebtReward,
				vars.pendingCollReward
			);
			troveManagerHelpers.removeStake(_asset, _borrower);

			singleLiquidation.debtToOffset = 0;
			singleLiquidation.collToSendToSP = 0;
			singleLiquidation.debtToRedistribute = singleLiquidation.entireTroveDebt;
			singleLiquidation.collToRedistribute = vars.collToLiquidate;

			troveManagerHelpers.closeTrove(
				_asset,
				_borrower,
				ITroveManagerHelpers.Status.closedByLiquidation
			);
			emit TroveLiquidated(
				_asset,
				_borrower,
				singleLiquidation.entireTroveDebt,
				singleLiquidation.entireTroveColl,
				TroveManagerOperation.liquidateInRecoveryMode
			);
			emit TroveUpdated(
				_asset,
				_borrower,
				0,
				0,
				0,
				TroveManagerOperation.liquidateInRecoveryMode
			);

			// If 100% < ICR < MCR, offset as much as possible, and redistribute the remainder
			// 如果 100% < ICR < MCR(110%),则尽可能多地抵消,然后才再分配剩余部分
		} else if ((_ICR > dfrancParams._100pct()) && (_ICR < dfrancParams.MCR(_asset))) {
			troveManagerHelpers.movePendingTroveRewardsToActivePool(
				_asset,
				_activePool,
				_defaultPool,
				vars.pendingDebtReward,
				vars.pendingCollReward
			);
			troveManagerHelpers.removeStake(_asset, _borrower);

			(
				singleLiquidation.debtToOffset,
				singleLiquidation.collToSendToSP,
				singleLiquidation.debtToRedistribute,
				singleLiquidation.collToRedistribute
			) = _getOffsetAndRedistributionVals(
				singleLiquidation.entireTroveDebt,
				vars.collToLiquidate,
				_DCHFInStabPool
			);

			troveManagerHelpers.closeTrove(
				_asset,
				_borrower,
				ITroveManagerHelpers.Status.closedByLiquidation
			);
			emit TroveLiquidated(
				_asset,
				_borrower,
				singleLiquidation.entireTroveDebt,
				singleLiquidation.entireTroveColl,
				TroveManagerOperation.liquidateInRecoveryMode
			);
			emit TroveUpdated(
				_asset,
				_borrower,
				0,
				0,
				0,
				TroveManagerOperation.liquidateInRecoveryMode
			);
			/*
			 * If 110% <= ICR < current TCR (accounting for the preceding liquidations in the current sequence)
			 * and there is DCHF in the Stability Pool, only offset, with no redistribution,
			 * but at a capped rate of 1.1 and only if the whole debt can be liquidated.
			 * The remainder due to the capped rate will be claimable as collateral surplus.
			 * 如果 110% <= ICR <当前 TCR(考虑当前序列中之前的清算),并且Stability Pool中有DCHF,则仅抵消,没有重新分配，
			 * 但上限为1.1,并且只有在整个债务可以清算的情况下.由于利率上限而产生的剩余部分将可作为抵押物盈余认领
			 */
		} else if (
			(_ICR >= dfrancParams.MCR(_asset)) &&
			(_ICR < _TCR) &&
			(singleLiquidation.entireTroveDebt <= _DCHFInStabPool)
		) {
			troveManagerHelpers.movePendingTroveRewardsToActivePool(
				_asset,
				_activePool,
				_defaultPool,
				vars.pendingDebtReward,
				vars.pendingCollReward
			);
			assert(_DCHFInStabPool != 0);

			troveManagerHelpers.removeStake(_asset, _borrower);
			singleLiquidation = _getCappedOffsetVals(
				_asset,
				singleLiquidation.entireTroveDebt,
				singleLiquidation.entireTroveColl,
				_price
			);

			troveManagerHelpers.closeTrove(
				_asset,
				_borrower,
				ITroveManagerHelpers.Status.closedByLiquidation
			);
			if (singleLiquidation.collSurplus > 0) {
				collSurplusPool.accountSurplus(_asset, _borrower, singleLiquidation.collSurplus);
			}

			emit TroveLiquidated(
				_asset,
				_borrower,
				singleLiquidation.entireTroveDebt,
				singleLiquidation.collToSendToSP,
				TroveManagerOperation.liquidateInRecoveryMode
			);
			emit TroveUpdated(
				_asset,
				_borrower,
				0,
				0,
				0,
				TroveManagerOperation.liquidateInRecoveryMode
			);
		} else {
			// if (_ICR >= MCR && ( _ICR >= _TCR || singleLiquidation.entireTroveDebt > _DCHFInStabPool))
			// 如果 ICR >= MCR 且 ( ICR >= TCR 或 Trove的所有debt > 在Stability Pool在中的DCHF
			LiquidationValues memory zeroVals;
			return zeroVals;
		}

		return singleLiquidation;
	}

	/* In a full liquidation, returns the values for a trove's coll and debt to be offset, and coll and debt to be
	 * redistributed to active troves.
	 */
	/*
	 * @note 在完全清算中,获取要抵消的Trove的collateral和债务的值,以及要重新分配给活动Trove的collateral和债务的值
	 */
	function _getOffsetAndRedistributionVals(
		uint256 _debt,
		uint256 _coll,
		uint256 _DCHFInStabPool
	)
		internal
		pure
		returns (
			uint256 debtToOffset,
			uint256 collToSendToSP,
			uint256 debtToRedistribute,
			uint256 collToRedistribute
		)
	{
		if (_DCHFInStabPool > 0) {
			/*
			 * Offset as much debt & collateral as possible against the Stability Pool, and redistribute the remainder
			 * between all active troves.
			 * Stability Pool抵消尽可能多的债务和抵押物,并在所有Active Troves之间再分配剩余部分
			 *
			 *  If the trove's debt is larger than the deposited DCHF in the Stability Pool:
			 *  如果Trove的债务大于Stability Pool中存入的DCHF:
			 *
			 *  - Offset an amount of the trove's debt equal to the DCHF in the Stability Pool
			 *  - Send a fraction of the trove's collateral to the Stability Pool, equal to the fraction of its offset debt
			 *  - 抵消Trove债务中等于Stability Pool中的DCHF的金额
			 *  - 将Trove抵押物的一小部分发送到Stability Pool,等于其抵消债务的一小部分
			 *
			 */
			debtToOffset = DfrancMath._min(_debt, _DCHFInStabPool);
			collToSendToSP = _coll.mul(debtToOffset).div(_debt);
			debtToRedistribute = _debt.sub(debtToOffset);
			collToRedistribute = _coll.sub(collToSendToSP);
		} else {
			debtToOffset = 0;
			collToSendToSP = 0;
			debtToRedistribute = _debt;
			collToRedistribute = _coll;
		}
	}

	/*
	 *  Get its offset coll/debt and ETH gas comp, and close the trove.
	 */
	/*
	 * @note 获取其抵消的collateral/债务和ETH气体补偿,并关闭Trove
	 */
	function _getCappedOffsetVals(
		address _asset,
		uint256 _entireTroveDebt,
		uint256 _entireTroveColl,
		uint256 _price
	) internal view returns (LiquidationValues memory singleLiquidation) {
		singleLiquidation.entireTroveDebt = _entireTroveDebt;
		singleLiquidation.entireTroveColl = _entireTroveColl;
		uint256 cappedCollPortion = _entireTroveDebt.mul(dfrancParams.MCR(_asset)).div(_price);

		singleLiquidation.collGasCompensation = _getCollGasCompensation(_asset, cappedCollPortion);
		singleLiquidation.DCHFGasCompensation = dfrancParams.DCHF_GAS_COMPENSATION(_asset);

		singleLiquidation.debtToOffset = _entireTroveDebt;
		singleLiquidation.collToSendToSP = cappedCollPortion.sub(
			singleLiquidation.collGasCompensation
		);
		singleLiquidation.collSurplus = _entireTroveColl.sub(cappedCollPortion);
		singleLiquidation.debtToRedistribute = 0;
		singleLiquidation.collToRedistribute = 0;
	}

	/*
	 * Liquidate a sequence of troves. Closes a maximum number of n under-collateralized Troves,
	 * starting from the one with the lowest collateral ratio in the system, and moving upwards
	 */
	/*
	 * @note 清算一系列Trove.关闭最大数量的n个抵押不足的Troves,从系统中抵押率最低的那个开始,然后逐步向上移动
	 */
	function liquidateTroves(address _asset, uint256 _n) external override {
		ContractsCache memory contractsCache = ContractsCache(
			dfrancParams.activePool(),
			dfrancParams.defaultPool(),
			IDCHFToken(address(0)),
			IMONStaking(address(0)),
			sortedTroves,
			ICollSurplusPool(address(0)),
			address(0)
		);
		IStabilityPool stabilityPoolCached = stabilityPoolManager.getAssetStabilityPool(_asset);

		LocalVariables_OuterLiquidationFunction memory vars;

		LiquidationTotals memory totals;

		vars.price = dfrancParams.priceFeed().fetchPrice(_asset);
		vars.DCHFInStabPool = stabilityPoolCached.getTotalDCHFDeposits();
		vars.recoveryModeAtStart = troveManagerHelpers.checkRecoveryMode(_asset, vars.price);

		// Perform the appropriate liquidation sequence - tally the values and obtain their totals
		// 执行适当的清算顺序 - 对这些值进行计数并获得其总数
		if (vars.recoveryModeAtStart) {
			totals = _getTotalsFromLiquidateTrovesSequence_RecoveryMode(
				_asset,
				contractsCache,
				vars.price,
				vars.DCHFInStabPool,
				_n
			);
		} else {
			// if !vars.recoveryModeAtStart
			totals = _getTotalsFromLiquidateTrovesSequence_NormalMode(
				_asset,
				contractsCache.activePool,
				contractsCache.defaultPool,
				vars.price,
				vars.DCHFInStabPool,
				_n
			);
		}

		require(totals.totalDebtInSequence > 0, "0L");

		// Move liquidated ETH and DCHF to the appropriate pools
		// 将清算后的ETH和DCHF转移到适当的Pool中
		stabilityPoolCached.offset(totals.totalDebtToOffset, totals.totalCollToSendToSP);
		troveManagerHelpers.redistributeDebtAndColl(
			_asset,
			contractsCache.activePool,
			contractsCache.defaultPool,
			totals.totalDebtToRedistribute,
			totals.totalCollToRedistribute
		);
		if (totals.totalCollSurplus > 0) {
			contractsCache.activePool.sendAsset(
				_asset,
				address(collSurplusPool),
				totals.totalCollSurplus
			);
		}

		// Update system snapshots 更新系统快照
		troveManagerHelpers.updateSystemSnapshots_excludeCollRemainder(
			_asset,
			contractsCache.activePool,
			totals.totalCollGasCompensation
		);

		vars.liquidatedDebt = totals.totalDebtInSequence;
		vars.liquidatedColl = totals.totalCollInSequence.sub(totals.totalCollGasCompensation).sub(
			totals.totalCollSurplus
		);
		emit Liquidation(
			_asset,
			vars.liquidatedDebt,
			vars.liquidatedColl,
			totals.totalCollGasCompensation,
			totals.totalDCHFGasCompensation
		);

		// Send gas compensation to caller 发送gas补偿给调用者
		_sendGasCompensation(
			_asset,
			contractsCache.activePool,
			msg.sender,
			totals.totalDCHFGasCompensation,
			totals.totalCollGasCompensation
		);
	}

	/*
	 * This function is used when the liquidateTroves sequence starts during Recovery Mode. However, it
	 * handle the case where the system *leaves* Recovery Mode, part way through the liquidation sequence
	 */
	/*
	 * @note 从处于恢复模式下的清算Troves序列中获取各种总和值
	 *		 当清算Troves序列在恢复模式下启动时使用此函数.但是,它会处理系统在清算序列的中途退出恢复模式的情况
	 */
	function _getTotalsFromLiquidateTrovesSequence_RecoveryMode(
		address _asset,
		ContractsCache memory _contractsCache,
		uint256 _price,
		uint256 _DCHFInStabPool,
		uint256 _n
	) internal returns (LiquidationTotals memory totals) {
		LocalVariables_AssetBorrowerPrice memory assetVars = LocalVariables_AssetBorrowerPrice(
			_asset,
			address(0),
			_price
		);

		LocalVariables_LiquidationSequence memory vars;
		LiquidationValues memory singleLiquidation;

		vars.remainingDCHFInStabPool = _DCHFInStabPool;
		vars.backToNormalMode = false;
		vars.entireSystemDebt = getEntireSystemDebt(assetVars._asset);
		vars.entireSystemColl = getEntireSystemColl(assetVars._asset);

		vars.user = _contractsCache.sortedTroves.getLast(assetVars._asset);
		address firstUser = _contractsCache.sortedTroves.getFirst(assetVars._asset);
		for (vars.i = 0; vars.i < _n && vars.user != firstUser; vars.i++) {
			// we need to cache it, because current user is likely going to be deleted
			// 我们需要缓存它,因为当前用户可能会被删除
			address nextUser = _contractsCache.sortedTroves.getPrev(assetVars._asset, vars.user);

			vars.ICR = troveManagerHelpers.getCurrentICR(
				assetVars._asset,
				vars.user,
				assetVars._price
			);

			if (!vars.backToNormalMode) {
				// Break the loop if ICR is greater than MCR and Stability Pool is empty
				// 如果 ICR 大于 MCR 且Stability Pool为空,则退出循环
				if (vars.ICR >= dfrancParams.MCR(_asset) && vars.remainingDCHFInStabPool == 0) {
					break;
				}

				uint256 TCR = DfrancMath._computeCR(
					vars.entireSystemColl,
					vars.entireSystemDebt,
					assetVars._price
				);

				singleLiquidation = _liquidateRecoveryMode(
					assetVars._asset,
					_contractsCache.activePool,
					_contractsCache.defaultPool,
					vars.user,
					vars.ICR,
					vars.remainingDCHFInStabPool,
					TCR,
					assetVars._price
				);

				// Update aggregate trackers
				vars.remainingDCHFInStabPool = vars.remainingDCHFInStabPool.sub(
					singleLiquidation.debtToOffset
				);
				vars.entireSystemDebt = vars.entireSystemDebt.sub(singleLiquidation.debtToOffset);
				vars.entireSystemColl = vars
					.entireSystemColl
					.sub(singleLiquidation.collToSendToSP)
					.sub(singleLiquidation.collGasCompensation)
					.sub(singleLiquidation.collSurplus);

				// Add liquidation values to their respective running totals
				// 将清算值添加到各自的运行总计中
				totals = _addLiquidationValuesToTotals(totals, singleLiquidation);

				vars.backToNormalMode = !troveManagerHelpers._checkPotentialRecoveryMode(
					_asset,
					vars.entireSystemColl,
					vars.entireSystemDebt,
					assetVars._price
				);
			} else if (vars.backToNormalMode && vars.ICR < dfrancParams.MCR(_asset)) {
				singleLiquidation = _liquidateNormalMode(
					assetVars._asset,
					_contractsCache.activePool,
					_contractsCache.defaultPool,
					vars.user,
					vars.remainingDCHFInStabPool
				);

				vars.remainingDCHFInStabPool = vars.remainingDCHFInStabPool.sub(
					singleLiquidation.debtToOffset
				);

				// Add liquidation values to their respective running totals
				// 将清算值添加到各自的运行总计中
				totals = _addLiquidationValuesToTotals(totals, singleLiquidation);
			} else break; // break if the loop reaches a Trove with ICR >= MCR

			vars.user = nextUser;
		}
	}

	/*
	 * @note 从处于正常模式下的Troves序列中获取各种总和值
	 */
	function _getTotalsFromLiquidateTrovesSequence_NormalMode(
		address _asset,
		IActivePool _activePool,
		IDefaultPool _defaultPool,
		uint256 _price,
		uint256 _DCHFInStabPool,
		uint256 _n
	) internal returns (LiquidationTotals memory totals) {
		LocalVariables_LiquidationSequence memory vars;
		LiquidationValues memory singleLiquidation;
		ISortedTroves sortedTrovesCached = sortedTroves;

		vars.remainingDCHFInStabPool = _DCHFInStabPool;

		for (vars.i = 0; vars.i < _n; vars.i++) {
			vars.user = sortedTrovesCached.getLast(_asset);
			vars.ICR = troveManagerHelpers.getCurrentICR(_asset, vars.user, _price);

			if (vars.ICR < dfrancParams.MCR(_asset)) {
				singleLiquidation = _liquidateNormalMode(
					_asset,
					_activePool,
					_defaultPool,
					vars.user,
					vars.remainingDCHFInStabPool
				);

				vars.remainingDCHFInStabPool = vars.remainingDCHFInStabPool.sub(
					singleLiquidation.debtToOffset
				);

				// Add liquidation values to their respective running totals
				// 将清算值添加到各自的运行总计中
				totals = _addLiquidationValuesToTotals(totals, singleLiquidation);
			} else break; // break if the loop reaches a Trove with ICR >= MCR
		}
	}

	/*
	 * Attempt to liquidate a custom list of troves provided by the caller.
	 */
	/*
	 * @note 批量清算给定的Trove数组
	 */
	function batchLiquidateTroves(address _asset, address[] memory _troveArray) public override {
		require(_troveArray.length != 0, "CA");

		IActivePool activePoolCached = dfrancParams.activePool();
		IDefaultPool defaultPoolCached = dfrancParams.defaultPool();
		IStabilityPool stabilityPoolCached = stabilityPoolManager.getAssetStabilityPool(_asset);

		LocalVariables_OuterLiquidationFunction memory vars;
		LiquidationTotals memory totals;

		vars.DCHFInStabPool = stabilityPoolCached.getTotalDCHFDeposits();
		vars.price = dfrancParams.priceFeed().fetchPrice(_asset);

		vars.recoveryModeAtStart = _checkRecoveryMode(_asset, vars.price);

		// Perform the appropriate liquidation sequence - tally values and obtain their totals.
		// 执行适当的清算顺序 - 对这些值进行计数并获得其总数
		if (vars.recoveryModeAtStart) {
			totals = _getTotalFromBatchLiquidate_RecoveryMode(
				_asset,
				activePoolCached,
				defaultPoolCached,
				vars.price,
				vars.DCHFInStabPool,
				_troveArray
			);
		} else {
			//  if !vars.recoveryModeAtStart
			totals = _getTotalsFromBatchLiquidate_NormalMode(
				_asset,
				activePoolCached,
				defaultPoolCached,
				vars.price,
				vars.DCHFInStabPool,
				_troveArray
			);
		}

		require(totals.totalDebtInSequence > 0, "0L");

		// Move liquidated ETH and DCHF to the appropriate pools
		// 将清算后的ETH和DCHF转移到适当的Pool中
		stabilityPoolCached.offset(totals.totalDebtToOffset, totals.totalCollToSendToSP);
		troveManagerHelpers.redistributeDebtAndColl(
			_asset,
			activePoolCached,
			defaultPoolCached,
			totals.totalDebtToRedistribute,
			totals.totalCollToRedistribute
		);
		if (totals.totalCollSurplus > 0) {
			activePoolCached.sendAsset(_asset, address(collSurplusPool), totals.totalCollSurplus);
		}

		// Update system snapshots 更新系统快照
		troveManagerHelpers.updateSystemSnapshots_excludeCollRemainder(
			_asset,
			activePoolCached,
			totals.totalCollGasCompensation
		);

		vars.liquidatedDebt = totals.totalDebtInSequence;
		vars.liquidatedColl = totals.totalCollInSequence.sub(totals.totalCollGasCompensation).sub(
			totals.totalCollSurplus
		);
		emit Liquidation(
			_asset,
			vars.liquidatedDebt,
			vars.liquidatedColl,
			totals.totalCollGasCompensation,
			totals.totalDCHFGasCompensation
		);

		// Send gas compensation to caller 发送gas补偿给调用者
		_sendGasCompensation(
			_asset,
			activePoolCached,
			msg.sender,
			totals.totalDCHFGasCompensation,
			totals.totalCollGasCompensation
		);
	}

	/*
	 * This function is used when the batch liquidation sequence starts during Recovery Mode. However, it
	 * handle the case where the system *leaves* Recovery Mode, part way through the liquidation sequence
	 */
	/*
	 * @note 从处于恢复模式下的批量清算中获取各种总和值
	 *		 当批量清算序列在恢复模式下启动时使用此函数.但是,它会处理系统在清算序列的中途退出恢复模式的情况
	 */
	function _getTotalFromBatchLiquidate_RecoveryMode(
		address _asset,
		IActivePool _activePool,
		IDefaultPool _defaultPool,
		uint256 _price,
		uint256 _DCHFInStabPool,
		address[] memory _troveArray
	) internal returns (LiquidationTotals memory totals) {
		LocalVariables_LiquidationSequence memory vars;
		LiquidationValues memory singleLiquidation;

		vars.remainingDCHFInStabPool = _DCHFInStabPool;
		vars.backToNormalMode = false;
		vars.entireSystemDebt = getEntireSystemDebt(_asset);
		vars.entireSystemColl = getEntireSystemColl(_asset);

		for (vars.i = 0; vars.i < _troveArray.length; vars.i++) {
			vars.user = _troveArray[vars.i];
			// Skip non-active troves 跳过不Active的Trove
			if (troveManagerHelpers.getTroveStatus(_asset, vars.user) != 1) {
				continue;
			}

			vars.ICR = troveManagerHelpers.getCurrentICR(_asset, vars.user, _price);

			if (!vars.backToNormalMode) {
				// Skip this trove if ICR is greater than MCR and Stability Pool is empty
				// 如果 ICR 大于 MCR 且Stability Pool为空,则跳过此Trove
				if (vars.ICR >= dfrancParams.MCR(_asset) && vars.remainingDCHFInStabPool == 0) {
					continue;
				}

				uint256 TCR = DfrancMath._computeCR(
					vars.entireSystemColl,
					vars.entireSystemDebt,
					_price
				);

				singleLiquidation = _liquidateRecoveryMode(
					_asset,
					_activePool,
					_defaultPool,
					vars.user,
					vars.ICR,
					vars.remainingDCHFInStabPool,
					TCR,
					_price
				);

				// Update aggregate trackers
				vars.remainingDCHFInStabPool = vars.remainingDCHFInStabPool.sub(
					singleLiquidation.debtToOffset
				);
				vars.entireSystemDebt = vars.entireSystemDebt.sub(singleLiquidation.debtToOffset);
				vars.entireSystemColl = vars
					.entireSystemColl
					.sub(singleLiquidation.collToSendToSP)
					.sub(singleLiquidation.collGasCompensation)
					.sub(singleLiquidation.collSurplus);

				// Add liquidation values to their respective running totals
				// 将清算值添加到各自的运行总计中
				totals = _addLiquidationValuesToTotals(totals, singleLiquidation);

				vars.backToNormalMode = !troveManagerHelpers._checkPotentialRecoveryMode(
					_asset,
					vars.entireSystemColl,
					vars.entireSystemDebt,
					_price
				);
			} else if (vars.backToNormalMode && vars.ICR < dfrancParams.MCR(_asset)) {
				singleLiquidation = _liquidateNormalMode(
					_asset,
					_activePool,
					_defaultPool,
					vars.user,
					vars.remainingDCHFInStabPool
				);
				vars.remainingDCHFInStabPool = vars.remainingDCHFInStabPool.sub(
					singleLiquidation.debtToOffset
				);

				// Add liquidation values to their respective running totals
				// 将清算值添加到各自的运行总计中
				totals = _addLiquidationValuesToTotals(totals, singleLiquidation);
			} else continue; // In Normal Mode skip troves with ICR >= MCR 当处于正常模式下跳过ICR >= MCR的Trove
		}
	}

	/*
	 * @note 从处于正常模式下的批量清算中获取各种总和值
	 */
	function _getTotalsFromBatchLiquidate_NormalMode(
		address _asset,
		IActivePool _activePool,
		IDefaultPool _defaultPool,
		uint256 _price,
		uint256 _DCHFInStabPool,
		address[] memory _troveArray
	) internal returns (LiquidationTotals memory totals) {
		LocalVariables_LiquidationSequence memory vars;
		LiquidationValues memory singleLiquidation;

		vars.remainingDCHFInStabPool = _DCHFInStabPool;

		for (vars.i = 0; vars.i < _troveArray.length; vars.i++) {
			vars.user = _troveArray[vars.i];
			vars.ICR = troveManagerHelpers.getCurrentICR(_asset, vars.user, _price);

			if (vars.ICR < dfrancParams.MCR(_asset)) {
				singleLiquidation = _liquidateNormalMode(
					_asset,
					_activePool,
					_defaultPool,
					vars.user,
					vars.remainingDCHFInStabPool
				);
				vars.remainingDCHFInStabPool = vars.remainingDCHFInStabPool.sub(
					singleLiquidation.debtToOffset
				);

				// Add liquidation values to their respective running totals
				// 将清算值添加到各自的运行总计中
				totals = _addLiquidationValuesToTotals(totals, singleLiquidation);
			}
		}
	}

	// --- Liquidation helper functions ---

	/*
	 * @note 将清算值添加到各自的运行总计中
	 */
	function _addLiquidationValuesToTotals(
		LiquidationTotals memory oldTotals,
		LiquidationValues memory singleLiquidation
	) internal pure returns (LiquidationTotals memory newTotals) {
		// Tally all the values with their respective running totals
		// 将所有值与其各自的运行总计进行计数
		newTotals.totalCollGasCompensation = oldTotals.totalCollGasCompensation.add(
			singleLiquidation.collGasCompensation
		);
		newTotals.totalDCHFGasCompensation = oldTotals.totalDCHFGasCompensation.add(
			singleLiquidation.DCHFGasCompensation
		);
		newTotals.totalDebtInSequence = oldTotals.totalDebtInSequence.add(
			singleLiquidation.entireTroveDebt
		);
		newTotals.totalCollInSequence = oldTotals.totalCollInSequence.add(
			singleLiquidation.entireTroveColl
		);
		newTotals.totalDebtToOffset = oldTotals.totalDebtToOffset.add(
			singleLiquidation.debtToOffset
		);
		newTotals.totalCollToSendToSP = oldTotals.totalCollToSendToSP.add(
			singleLiquidation.collToSendToSP
		);
		newTotals.totalDebtToRedistribute = oldTotals.totalDebtToRedistribute.add(
			singleLiquidation.debtToRedistribute
		);
		newTotals.totalCollToRedistribute = oldTotals.totalCollToRedistribute.add(
			singleLiquidation.collToRedistribute
		);
		newTotals.totalCollSurplus = oldTotals.totalCollSurplus.add(singleLiquidation.collSurplus);

		return newTotals;
	}

	/*
	 * @note 发送gas补偿给清算者
	 */
	function _sendGasCompensation(
		address _asset,
		IActivePool _activePool,
		address _liquidator,
		uint256 _DCHF,
		uint256 _ETH
	) internal {
		if (_DCHF > 0) {
			dchfToken.returnFromPool(gasPoolAddress, _liquidator, _DCHF);
		}

		if (_ETH > 0) {
			_activePool.sendAsset(_asset, _liquidator, _ETH);
		}
	}

	// --- Redemption functions ---

	// Redeem as much collateral as possible from _borrower's Trove in exchange for DCHF up to _maxDCHFamount
	/*
	 * @note 从Trove中赎回抵押物
	 *		 从_borrower(借贷者)的Trove中赎回尽可能多的抵押物,以换取高达_maxDCHFamount的DCHF
	 */
	function _redeemCollateralFromTrove(
		address _asset,
		ContractsCache memory _contractsCache,
		address _borrower,
		uint256 _maxDCHFamount,
		uint256 _price,
		address _upperPartialRedemptionHint,
		address _lowerPartialRedemptionHint,
		uint256 _partialRedemptionHintNICR
	) internal returns (SingleRedemptionValues memory singleRedemption) {
		LocalVariables_AssetBorrowerPrice memory vars = LocalVariables_AssetBorrowerPrice(
			_asset,
			_borrower,
			_price
		);

		// Determine the remaining amount (lot) to be redeemed, capped by the entire debt of the Trove minus the liquidation reserve
		// 确定要赎回的剩余金额(手数),上限为Trove的全部债务减去清算准备金
		singleRedemption.DCHFLot = DfrancMath._min(
			_maxDCHFamount,
			troveManagerHelpers.getTroveDebt(vars._asset, vars._borrower).sub(
				dfrancParams.DCHF_GAS_COMPENSATION(_asset)
			)
		);

		// Get the ETHLot of equivalent value in USD
		// 获取等值美元的ETHLot
		singleRedemption.ETHLot = singleRedemption.DCHFLot.mul(DECIMAL_PRECISION).div(_price);

		// Decrease the debt and collateral of the current Trove according to the DCHF lot and corresponding ETH to send
		// 根据DCHF手数和相应发送的ETH减少当前Trove的债务和抵押物
		uint256 newDebt = (troveManagerHelpers.getTroveDebt(vars._asset, vars._borrower)).sub(
			singleRedemption.DCHFLot
		);
		uint256 newColl = (troveManagerHelpers.getTroveColl(vars._asset, vars._borrower)).sub(
			singleRedemption.ETHLot
		);

		if (newDebt == dfrancParams.DCHF_GAS_COMPENSATION(_asset)) {
			// No debt left in the Trove (except for the liquidation reserve), therefore the trove gets closed
			// Trove中没有债务(清算准备金除外),因此Trove被关闭
			troveManagerHelpers.removeStake(vars._asset, vars._borrower);
			troveManagerHelpers.closeTrove(
				vars._asset,
				vars._borrower,
				ITroveManagerHelpers.Status.closedByRedemption
			);
			_redeemCloseTrove(
				vars._asset,
				_contractsCache,
				vars._borrower,
				dfrancParams.DCHF_GAS_COMPENSATION(vars._asset),
				newColl
			);
			emit TroveUpdated(
				vars._asset,
				vars._borrower,
				0,
				0,
				0,
				TroveManagerOperation.redeemCollateral
			);
		} else {
			uint256 newNICR = DfrancMath._computeNominalCR(newColl, newDebt);

			/*
			 * If the provided hint is out of date, we bail since trying to reinsert without a good hint will almost
			 * certainly result in running out of gas.
			 * 如果提供的提示已过时,我们将放弃,因为尝试在没有良好提示的情况下重新插入几乎肯定会导致gas耗尽
			 *
			 * If the resultant net debt of the partial is less than the minimum, net debt we bail.
			 * 如果由此产生的部分净债务低于最小净债务,我们就放弃净债务
			 */
			if (
				newNICR != _partialRedemptionHintNICR ||
				_getNetDebt(vars._asset, newDebt) < dfrancParams.MIN_NET_DEBT(vars._asset)
			) {
				singleRedemption.cancelledPartial = true;
				return singleRedemption;
			}

			_contractsCache.sortedTroves.reInsert(
				vars._asset,
				vars._borrower,
				newNICR,
				_upperPartialRedemptionHint,
				_lowerPartialRedemptionHint
			);

			troveManagerHelpers.setTroveDeptAndColl(vars._asset, vars._borrower, newDebt, newColl);
			troveManagerHelpers.updateStakeAndTotalStakes(vars._asset, vars._borrower);

			emit TroveUpdated(
				vars._asset,
				vars._borrower,
				newDebt,
				newColl,
				troveManagerHelpers.getTroveStake(vars._asset, vars._borrower),
				TroveManagerOperation.redeemCollateral
			);
		}

		return singleRedemption;
	}

	/*
	 * Called when a full redemption occurs, and closes the trove.
	 * The redeemer swaps (debt - liquidation reserve) DCHF for (debt - liquidation reserve) worth of ETH, so the DCHF liquidation reserve left corresponds to the remaining debt.
	 * In order to close the trove, the DCHF liquidation reserve is burned, and the corresponding debt is removed from the active pool.
	 * The debt recorded on the trove's struct is zero'd elswhere, in _closeTrove.
	 * Any surplus ETH left in the trove, is sent to the Coll surplus pool, and can be later claimed by the borrower.
	 * 在发生完全赎回时调用,并关闭Trove
	 * 赎回者将(债务 - 清算准备金)价值的DCHF交换为(债务 - 清算准备金)价值的ETH，因此剩余的DCHF清算准备金对应于剩余的债务
	 * 为了关闭Trove,DCHF清算准备金被销毁,相应的债务从Active Pool中移除
	 * 在Trove的结构上记录的债务是零，在_closeTrove
	 * 任何剩余的ETH都会被发送到CollSurplus Pool,借贷者稍后可以认领
	 */
	/*
	 * @note 赎回关闭了的Trove
	 */
	function _redeemCloseTrove(
		address _asset,
		ContractsCache memory _contractsCache,
		address _borrower,
		uint256 _DCHF,
		uint256 _ETH
	) internal {
		_contractsCache.dchfToken.burn(gasPoolAddress, _DCHF);
		// Update Active Pool DCHF, and send ETH to account
		// 更新Active Pool中的DCHF，并将ETH发送到账户
		_contractsCache.activePool.decreaseDCHFDebt(_asset, _DCHF);

		// send ETH from Active Pool to CollSurplus Pool
		// 从Active Pool中发送ETH到CollSurplus Pool
		_contractsCache.collSurplusPool.accountSurplus(_asset, _borrower, _ETH);
		_contractsCache.activePool.sendAsset(
			_asset,
			address(_contractsCache.collSurplusPool),
			_ETH
		);
	}

	/*
	 * @note 判断首次赎回提示是否有效
	 */
	function _isValidFirstRedemptionHint(
		address _asset,
		ISortedTroves _sortedTroves,
		address _firstRedemptionHint,
		uint256 _price
	) internal view returns (bool) {
		if (
			_firstRedemptionHint == address(0) ||
			!_sortedTroves.contains(_asset, _firstRedemptionHint) ||
			troveManagerHelpers.getCurrentICR(_asset, _firstRedemptionHint, _price) <
			dfrancParams.MCR(_asset)
		) {
			return false;
		}

		address nextTrove = _sortedTroves.getNext(_asset, _firstRedemptionHint);
		return
			nextTrove == address(0) ||
			troveManagerHelpers.getCurrentICR(_asset, nextTrove, _price) < dfrancParams.MCR(_asset);
	}

	/*
	 * @note 设置赎回白名单状态
	 */
	function setRedemptionWhitelistStatus(bool _status) external onlyOwner {
		isRedemptionWhitelisted = _status;
	}

	/*
	 * @note 添加用户到赎回白名单中
	 */
	function addUserToWhitelistRedemption(address _user) external onlyOwner {
		redemptionWhitelist[_user] = true;
	}

	/*
	 * @note 从赎回白名单中删除用户
	 */
	function removeUserFromWhitelistRedemption(address _user) external onlyOwner {
		delete redemptionWhitelist[_user];
	}

	/* Send _DCHFamount DCHF to the system and redeem the corresponding amount of collateral from as many Troves as are needed to fill the redemption
	 * request.  Applies pending rewards to a Trove before reducing its debt and coll.
	 * 将_DCHFamount数量的DCHF发送到系统中,并从满足赎回请求所需的任意数量的Troves中赎回相应数量的抵押物.在减少债务和抵押物之前将待处理奖励应用于Trove.
	 *
	 * Note that if _amount is very large, this function can run out of gas, specially if traversed troves are small. This can be easily avoided by
	 * splitting the total _amount in appropriate chunks and calling the function multiple times.
	 * 请注意,如果_amount非常大,此函数可能会耗尽gas,特别是如果遍历的Trove很小.通过将总_amount拆分为适当的块并多次调用函数,可以轻松避免这种情况.
	 *
	 * Param `_maxIterations` can also be provided, so the loop through Troves is capped (if it’s zero, it will be ignored).This makes it easier to
	 * avoid OOG for the frontend, as only knowing approximately the average cost of an iteration is enough, without needing to know the “topology”
	 * of the trove list. It also avoids the need to set the cap in stone in the contract, nor doing gas calculations, as both gas price and opcode
	 * costs can vary.
	 * 也可以提供参数“_maxIterations”,因此通过Troves的循环是有上限的(如果为零,它将被忽略).这使得前端避免OOG变得更加容易,因为只知道迭代的大致平均成本就足够了,
	 * 而不需要知道Trove列表的“拓扑”.它还避免了在合同中设定上限的需要,也避免了做gas费的计算,因为gas价格和操作码成本可能会有所不同.
	 *
	 * All Troves that are redeemed from -- with the likely exception of the last one -- will end up with no debt left, therefore they will be closed.
	 * If the last Trove does have some remaining debt, it has a finite ICR, and the reinsertion could be anywhere in the list, therefore it requires a hint.
	 * A frontend should use getRedemptionHints() to calculate what the ICR of this Trove will be after redemption, and pass a hint for its position
	 * in the sortedTroves list along with the ICR value that the hint was found for.
	 * 所有被赎回的宝藏 -- 可能除了最后一个 -- 最终将没有债务,因此它们将被关闭.
	 * 如果最后一个Trove确实有一些剩余的债务,它有一个有限的ICR,并且可能重新插入在列表中的任何地方,因此它需要一个提示.
	 * 前端应该使用getRedemptionHints()来计算此Trove在赎回后的ICR是多少,并传递其在sortedTroves列表中的位置提示以及找到该提示的ICR值.
	 *
	 * If another transaction modifies the list between calling getRedemptionHints() and passing the hints to redeemCollateral(), it
	 * is very likely that the last (partially) redeemed Trove would end up with a different ICR than what the hint is for. In this case the
	 * redemption will stop after the last completely redeemed Trove and the sender will keep the remaining DCHF amount, which they can attempt
	 * to redeem later.
	 * 如果另一笔交易在调用getRedemptionHints()和将提示传递给redeemCollateral()之间修改列表,那么最后(部分)赎回的Trove将以与提示不同的ICR结束.
	 * 在这种情况下,赎回将在最后一次完全赎回的Trove后停止,发送者将保留剩余的DCHF金额,他们可以稍后尝试赎回.
	 */
	/*
	 * @note 赎回抵押物
	 */
	function redeemCollateral(
		address _asset,
		uint256 _DCHFamount,
		address _firstRedemptionHint,
		address _upperPartialRedemptionHint,
		address _lowerPartialRedemptionHint,
		uint256 _partialRedemptionHintNICR,
		uint256 _maxIterations,
		uint256 _maxFeePercentage
	) external override {
		if (isRedemptionWhitelisted) {
			require(redemptionWhitelist[msg.sender], "NW");
		}

		require(block.timestamp >= dfrancParams.redemptionBlock(_asset), "BR");

		ContractsCache memory contractsCache = ContractsCache(
			dfrancParams.activePool(),
			dfrancParams.defaultPool(),
			dchfToken,
			monStaking,
			sortedTroves,
			collSurplusPool,
			gasPoolAddress
		);
		RedemptionTotals memory totals;

		troveManagerHelpers._requireValidMaxFeePercentage(_asset, _maxFeePercentage);
		totals.price = dfrancParams.priceFeed().fetchPrice(_asset);
		troveManagerHelpers._requireTCRoverMCR(_asset, totals.price);
		troveManagerHelpers._requireAmountGreaterThanZero(_DCHFamount);
		troveManagerHelpers._requireDCHFBalanceCoversRedemption(
			contractsCache.dchfToken,
			msg.sender,
			_DCHFamount
		);

		totals.totalDCHFSupplyAtStart = getEntireSystemDebt(_asset);
		totals.remainingDCHF = _DCHFamount;
		address currentBorrower;

		if (
			_isValidFirstRedemptionHint(
				_asset,
				contractsCache.sortedTroves,
				_firstRedemptionHint,
				totals.price
			)
		) {
			currentBorrower = _firstRedemptionHint;
		} else {
			currentBorrower = contractsCache.sortedTroves.getLast(_asset);
			// Find the first trove with ICR >= MCR
			// 找到第一个ICR >= MCR的Trove
			while (
				currentBorrower != address(0) &&
				troveManagerHelpers.getCurrentICR(_asset, currentBorrower, totals.price) <
				dfrancParams.MCR(_asset)
			) {
				currentBorrower = contractsCache.sortedTroves.getPrev(_asset, currentBorrower);
			}
		}

		// Loop through the Troves starting from the one with lowest collateral ratio until _amount of DCHF is exchanged for collateral
		// 从抵押率最低的那个Trove开始循环,直到_amount个DCHF被交换为抵押品
		if (_maxIterations == 0) {
			_maxIterations = type(uint256).max;
		}
		while (currentBorrower != address(0) && totals.remainingDCHF > 0 && _maxIterations > 0) {
			_maxIterations--;
			// Save the address of the Trove preceding the current one, before potentially modifying the list
			// 在可能修改列表之前,将Trove的地址保存在当前Trove的地址之前
			address nextUserToCheck = contractsCache.sortedTroves.getPrev(_asset, currentBorrower);

			troveManagerHelpers.applyPendingRewards(
				_asset,
				contractsCache.activePool,
				contractsCache.defaultPool,
				currentBorrower
			);

			SingleRedemptionValues memory singleRedemption = _redeemCollateralFromTrove(
				_asset,
				contractsCache,
				currentBorrower,
				totals.remainingDCHF,
				totals.price,
				_upperPartialRedemptionHint,
				_lowerPartialRedemptionHint,
				_partialRedemptionHintNICR
			);

			// Partial redemption was cancelled (out-of-date hint, or new net debt < minimum), therefore we could not redeem from the last Trove
			// 部分赎回被取消(过时的提示,或新的净债务<最低),因此我们无法从最后一个Trove赎回
			if (singleRedemption.cancelledPartial) break;

			totals.totalDCHFToRedeem = totals.totalDCHFToRedeem.add(singleRedemption.DCHFLot);
			totals.totalAssetDrawn = totals.totalAssetDrawn.add(singleRedemption.ETHLot);

			totals.remainingDCHF = totals.remainingDCHF.sub(singleRedemption.DCHFLot);
			currentBorrower = nextUserToCheck;
		}
		require(totals.totalAssetDrawn > 0, "UR");

		// Decay the baseRate due to time passed, and then increase it according to the size of this redemption.
		// 随着时间流逝而衰减基本费率,然后根据本次赎回的大小增加它.
		// Use the saved total DCHF supply value, from before it was reduced by the redemption.
		// 使用节省的DCHF总供应价值,从赎回减少之前开始.
		troveManagerHelpers.updateBaseRateFromRedemption(
			_asset,
			totals.totalAssetDrawn,
			totals.price,
			totals.totalDCHFSupplyAtStart
		);

		// Calculate the ETH fee 计算ETH费用
		totals.ETHFee = troveManagerHelpers._getRedemptionFee(_asset, totals.totalAssetDrawn);

		_requireUserAcceptsFee(totals.ETHFee, totals.totalAssetDrawn, _maxFeePercentage);

		// Send the ETH fee to the MON staking contract 发送ETH费用到MON质押合约
		contractsCache.activePool.sendAsset(
			_asset,
			address(contractsCache.monStaking),
			totals.ETHFee
		);
		contractsCache.monStaking.increaseF_Asset(_asset, totals.ETHFee);

		totals.ETHToSendToRedeemer = totals.totalAssetDrawn.sub(totals.ETHFee);

		emit Redemption(
			_asset,
			_DCHFamount,
			totals.totalDCHFToRedeem,
			totals.totalAssetDrawn,
			totals.ETHFee
		);

		// Burn the total DCHF that is cancelled with debt, and send the redeemed ETH to msg.sender
		// 销毁用于抵消债务的总DCHF,并将赎回的ETH发送到msg.sender
		contractsCache.dchfToken.burn(msg.sender, totals.totalDCHFToRedeem);
		// Update Active Pool DCHF, and send ETH to account
		// 更新Active Pool中的DCHF,然后发送ETH到账户上
		contractsCache.activePool.decreaseDCHFDebt(_asset, totals.totalDCHFToRedeem);
		contractsCache.activePool.sendAsset(_asset, msg.sender, totals.ETHToSendToRedeemer);
	}
}
