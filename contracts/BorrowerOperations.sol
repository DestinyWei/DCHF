// SPDX-License-Identifier: MIT

pragma solidity ^0.8.14;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./Interfaces/IBorrowerOperations.sol";
import "./Interfaces/ITroveManager.sol";
import "./Interfaces/ITroveManagerHelpers.sol";
import "./Interfaces/IDCHFToken.sol";
import "./Interfaces/ICollSurplusPool.sol";
import "./Interfaces/ISortedTroves.sol";
import "./Interfaces/IMONStaking.sol";
import "./Interfaces/IStabilityPoolManager.sol";
import "./Dependencies/DfrancBase.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/SafetyTransfer.sol";
import "./Dependencies/Initializable.sol";

/*
 * @notice 借贷者操作合约(核心合约)
 *
 * @note 包含的内容如下:
 *		function setAddresses(address _troveManagerAddress, address _troveManagerHelpersAddress,
							  address _stabilityPoolManagerAddress, address _gasPoolAddress,
							  address _collSurplusPoolAddress, address _sortedTrovesAddress,
							  address _dchfTokenAddress, address _MONStakingAddress,
							  address _dfrancParamsAddress) 											初始化设置地址
 *		function isContractBorrowerOps() returns (bool) 												是否为借贷者操作合约的getter函数
 *		function openTrove(address _asset, uint256 _tokenAmount, uint256 _maxFeePercentage,
						   uint256 _DCHFamount, address _upperHint, address _lowerHint) 				打开trove
 *		function addColl(address _asset, uint256 _assetSent, address _upperHint,
 						 address _lowerHint) 															将ETH作为抵押物发送给trove
 *		function moveETHGainToTrove(address _asset, uint256 _amountMoved, address _borrower,
									address _upperHint, address _lowerHint) 							将ETH作为抵押物发送到trove,仅由Stability Pool调用
 *		function withdrawColl(address _asset, uint256 _collWithdrawal,
 							  address _upperHint, address _lowerHint) 									从trove中提取ETH抵押物
 *		function withdrawDCHF(address _asset, uint256 _maxFeePercentage, uint256 _DCHFamount,
							  address _upperHint, address _lowerHint) 									从trove中提取DCHF token,即向owner发行新的DCHF token,并相应地增加trove的债务
 *		function repayDCHF(address _asset, uint256 _DCHFamount, address _upperHint,
						   address _lowerHint) 															将DCHF token偿还给trove,即销毁偿还的DCHF token并相应地减少trove的债务
 *		function adjustTrove(address _asset, uint256 _assetSent, uint256 _maxFeePercentage,
							 uint256 _collWithdrawal, uint256 _DCHFChange, bool _isDebtIncrease,
							 address _upperHint, address _lowerHint) 									调整trove,既可以调整debt,又可以充值新的collateral或取出collateral
 *		function _adjustTrove(address _asset, uint256 _assetSent, address _borrower,
							  uint256 _collWithdrawal, uint256 _DCHFChange, bool _isDebtIncrease,
							  address _upperHint, address _lowerHint, uint256 _maxFeePercentage) 		调整trove,既可以调整debt,又可以充值新的collateral或取出collateral
 *		function closeTrove(address _asset) 															关闭trove
 *		function claimCollateral(address _asset) 														在恢复模式下通过ICR>MCR从赎回或清算中认领剩余抵押品
 *		function _triggerBorrowingFee(address _asset, ITroveManager _troveManager,
									  ITroveManagerHelpers _troveManagerHelpers,
									  IDCHFToken _DCHFToken, uint256 _DCHFamount,
									  uint256 _maxFeePercentage) returns (uint256) 						计算借贷费用
 *		function _getCollChange(uint256 _collReceived, uint256 _requestedCollWithdrawal)
 								returns (uint256 collChange, bool isCollIncrease) 						根据交易中是否发送了ETH来获取collateral的变化量(充值/提取)
 *		function _updateTroveFromAdjustment(address _asset, ITroveManager _troveManager,
											ITroveManagerHelpers _troveManagerHelpers,
											address _borrower, uint256 _collChange,
											bool _isCollIncrease, uint256 _debtChange,
											bool _isDebtIncrease) returns (uint256, uint256) 			跟增加或减少来更新trove的collateral和debt
 *		function _moveTokensAndETHfromAdjustment(address _asset, IActivePool _activePool,
												 IDCHFToken _DCHFToken, address _borrower,
												 uint256 _collChange, bool _isCollIncrease,
												 uint256 _DCHFChange, bool _isDebtIncrease,
												 uint256 _netDebtChange) 								根据调整来移动(发行/偿还)DCHF代币债务和(充值/提取)ETH抵押物
 *		function _activePoolAddColl(address _asset, IActivePool _activePool, uint256 _amount) 			发送ETH到Active Pool中并增加其记录的ETH余额
 *		function _withdrawDCHF(address _asset, IActivePool _activePool, IDCHFToken _DCHFToken,
							   address _account, uint256 _DCHFamount, uint256 _netDebtIncrease) 		发行指定数量的DCHF给_account并增加总活跃债务(_netDebtIncrease可能包括DCHFFee)
 *		function _repayDCHF(address _asset, IActivePool _activePool, IDCHFToken _DCHFToken,
							address _account, uint256 _DCHF) 											从_account中销毁指定数量的DCHF并减少总活跃债务
 *		function _requireSingularCollChange(uint256 _collWithdrawal, uint256 _amountSent) 				判断充值collateral和提取collateral是否同时进行(不允许同时)
 *		function _requireNonZeroAdjustment(uint256 _collWithdrawal, uint256 _DCHFChange,
										   uint256 _assetSent) 											要求必须有collateral变化或者debt变化
 *		function _requireTroveisActive(address _asset, ITroveManagerHelpers _troveManagerHelpers,
									   address _borrower) 												检查trove是否存在且处于活跃状态
 *		function _requireTroveisNotActive(address _asset, ITroveManager _troveManager,
										  ITroveManagerHelpers _troveManagerHelpers,
										  address _borrower) 											检查trove是否处于不活跃状态
 *		function _requireNonZeroDebtChange(uint256 _DCHFChange) 										判断当debt上升时非零debt是否发生变化
 *		function _requireNotInRecoveryMode(address _asset, uint256 _price) 								检查该操作是否处于恢复模式下,处于恢复模式时该操作不允许被执行
 *		function _requireNoCollWithdrawal(uint256 _collWithdrawal) 										处于恢复模式时不允许抵押物提取
 *		function _requireValidAdjustmentInCurrentMode(address _asset, bool _isRecoveryMode,
													  uint256 _collWithdrawal, bool _isDebtIncrease,
													  LocalVariables_adjustTrove memory _vars) 			检查此次调整是否满足当前系统模式的所有条件
 *		function _requireICRisAboveMCR(address _asset, uint256 _newICR) 								检查新的ICR是否大于MCR(即会导致ICR<MCR的操作将不被允许,否则会被清算)
 *		function _requireICRisAboveCCR(address _asset, uint256 _newICR) 								检查新的ICR是否大于等于CCR,否则无法执行该操作
 *		function _requireNewICRisAboveOldICR(uint256 _newICR, uint256 _oldICR) 							检查新的ICR是否大于旧的ICR(在恢复模式下不能降低trove的ICR)
 *		function _requireNewTCRisAboveCCR(address _asset, uint256 _newTCR) 								检查新的TCR是否大于CCR(即会导致TCR<CCR的操作将不被允许,否则会进入恢复模式)
 *		function _requireAtLeastMinNetDebt(address _asset, uint256 _netDebt) 							检查净债务是否大于等于最小净债务
 *		function _requireValidDCHFRepayment(address _asset, uint256 _currentDebt,
											uint256 _debtRepayment) 									检查偿还的DCHF数量是否小于等于trove的债务
 *		function _requireCallerIsStabilityPool() 														检查调用者是否为Stability Pool
 *		function _requireSufficientDCHFBalance(IDCHFToken _DCHFToken, address _borrower,
											   uint256 _debtRepayment) 									检查是否有足够的DCHF余额偿还债务
 *		function _requireValidMaxFeePercentage(address _asset, uint256 _maxFeePercentage,
											   bool _isRecoveryMode) 									检查最高费用比例是否合法
 *		function _getNewNominalICRFromTroveChange(uint256 _coll, uint256 _debt, uint256 _collChange,
												  bool _isCollIncrease, uint256 _debtChange,
												  bool _isDebtIncrease) returns (uint256) 				计算新的NICR(个人名义抵押率),考虑collateral和debt的变化
 *		function _getNewICRFromTroveChange(uint256 _coll, uint256 _debt, uint256 _collChange,
										   bool _isCollIncrease, uint256 _debtChange,
										   bool _isDebtIncrease, uint256 _price) returns (uint256) 		计算新的ICR(个人抵押率),考虑collateral和debt的变化
 *		function _getNewTroveAmounts(uint256 _coll, uint256 _debt, uint256 _collChange,
									 bool _isCollIncrease, uint256 _debtChange,
									 bool _isDebtIncrease) returns (uint256, uint256) 					获取trove调整之后collateral和debt的数量
 *		function _getNewTCRFromTroveChange(address _asset, uint256 _collChange, bool _isCollIncrease,
										   uint256 _debtChange, bool _isDebtIncrease,
										   uint256 _price) returns (uint256) 							当trove发生变化时获取新的TCR(系统总抵押率)
 *		function getCompositeDebt(address _asset, uint256 _debt) returns (uint256) 						获取复合债务(提取债务+gas赔偿),用于计算ICR(个人抵押率)
 *		function getMethodValue(address _asset, uint256 _amount, bool canBeZero) returns (uint256) 		获取方法值
 */
contract BorrowerOperations is DfrancBase, CheckContract, IBorrowerOperations, Initializable {
	using SafeMath for uint256;
	using SafeERC20 for IERC20;

	string public constant NAME = "BorrowerOperations";

	// --- Connected contract declarations ---

	ITroveManager public troveManager;

	ITroveManagerHelpers public troveManagerHelpers;

	IStabilityPoolManager stabilityPoolManager;

	address gasPoolAddress;

	ICollSurplusPool collSurplusPool;

	IMONStaking public MONStaking;
	address public MONStakingAddress;

	IDCHFToken public DCHFToken;

	// A doubly linked list of Troves, sorted by their collateral ratios
	ISortedTroves public sortedTroves;

	bool public isInitialized;

	/* --- Variable container structs  ---

    Used to hold, return and assign variables inside a function, in order to avoid the error:
    "CompilerError: Stack too deep". */

	struct LocalVariables_adjustTrove {
		address asset;
		uint256 price;
		uint256 collChange;
		uint256 netDebtChange;
		bool isCollIncrease;
		uint256 debt;
		uint256 coll;
		uint256 oldICR;
		uint256 newICR;
		uint256 newTCR;
		uint256 DCHFFee;
		uint256 newDebt;
		uint256 newColl;
		uint256 stake;
	}

	struct LocalVariables_openTrove {
		address asset;
		uint256 price;
		uint256 DCHFFee;
		uint256 netDebt;
		uint256 compositeDebt;
		uint256 ICR;
		uint256 NICR;
		uint256 stake;
		uint256 arrayIndex;
	}

	struct ContractsCache {
		ITroveManager troveManager;
		ITroveManagerHelpers troveManagerHelpers;
		IActivePool activePool;
		IDCHFToken DCHFToken;
	}

	enum BorrowerOperation {
		openTrove,
		closeTrove,
		adjustTrove
	}

	event TroveUpdated(
		address indexed _asset,
		address indexed _borrower,
		uint256 _debt,
		uint256 _coll,
		uint256 stake,
		BorrowerOperation operation
	);

	// --- Dependency setters ---

	/*
	 * @note 初始化设置地址
	 * 		 1. 检查合约地址是否不为0地址以及检查调用的合约是否存在
	 * 		 2. 赋值
	 */
	function setAddresses(
		address _troveManagerAddress,
		address _troveManagerHelpersAddress,
		address _stabilityPoolManagerAddress,
		address _gasPoolAddress,
		address _collSurplusPoolAddress,
		address _sortedTrovesAddress,
		address _dchfTokenAddress,
		address _MONStakingAddress,
		address _dfrancParamsAddress
	) external override initializer onlyOwner {
		require(!isInitialized, "Already initialized");
		checkContract(_troveManagerAddress);
		checkContract(_troveManagerHelpersAddress);
		checkContract(_stabilityPoolManagerAddress);
		checkContract(_gasPoolAddress);
		checkContract(_collSurplusPoolAddress);
		checkContract(_sortedTrovesAddress);
		checkContract(_dchfTokenAddress);
		checkContract(_MONStakingAddress);
		checkContract(_dfrancParamsAddress);
		isInitialized = true;

		troveManager = ITroveManager(_troveManagerAddress);
		troveManagerHelpers = ITroveManagerHelpers(_troveManagerHelpersAddress);
		stabilityPoolManager = IStabilityPoolManager(_stabilityPoolManagerAddress);
		gasPoolAddress = _gasPoolAddress;
		collSurplusPool = ICollSurplusPool(_collSurplusPoolAddress);
		sortedTroves = ISortedTroves(_sortedTrovesAddress);
		DCHFToken = IDCHFToken(_dchfTokenAddress);
		MONStakingAddress = _MONStakingAddress;
		MONStaking = IMONStaking(_MONStakingAddress);

		setDfrancParameters(_dfrancParamsAddress);

		emit TroveManagerAddressChanged(_troveManagerAddress);
		emit StabilityPoolAddressChanged(_stabilityPoolManagerAddress);
		emit GasPoolAddressChanged(_gasPoolAddress);
		emit CollSurplusPoolAddressChanged(_collSurplusPoolAddress);
		emit SortedTrovesAddressChanged(_sortedTrovesAddress);
		emit DCHFTokenAddressChanged(_dchfTokenAddress);
		emit MONStakingAddressChanged(_MONStakingAddress);
	}

	// --- Borrower Trove Operations Getter functions ---

	/*
	 * @note 是否为借贷者操作合约的getter函数
	 */
	function isContractBorrowerOps() public pure returns (bool) {
		return true;
	}

	// --- Borrower Trove Operations ---

	/*
	 * @note 打开trove
	 */
	function openTrove(
		address _asset,
		uint256 _tokenAmount,
		uint256 _maxFeePercentage,
		uint256 _DCHFamount,
		address _upperHint,
		address _lowerHint
	) external payable override {
		// 重置_asset的公共参数为默认值
		dfrancParams.sanitizeParameters(_asset);

		ContractsCache memory contractsCache = ContractsCache(
			troveManager,
			troveManagerHelpers,
			dfrancParams.activePool(),
			DCHFToken
		);
		LocalVariables_openTrove memory vars;
		vars.asset = _asset;

		_tokenAmount = getMethodValue(vars.asset, _tokenAmount, false);
		// 预言机获取该asset的价格
		vars.price = dfrancParams.priceFeed().fetchPrice(vars.asset);

		// 检查系统是否处于恢复模式
		bool isRecoveryMode = _checkRecoveryMode(vars.asset, vars.price);

		// 检查最高费用比例是否合法
		_requireValidMaxFeePercentage(vars.asset, _maxFeePercentage, isRecoveryMode);
		// 检查trove是否处于不活跃状态
		_requireTroveisNotActive(
			vars.asset,
			contractsCache.troveManager,
			contractsCache.troveManagerHelpers,
			msg.sender
		);

		vars.netDebt = _DCHFamount;

		// 判断是否处于正常状态
		if (!isRecoveryMode) {
			vars.DCHFFee = _triggerBorrowingFee(
				vars.asset,
				contractsCache.troveManager,
				contractsCache.troveManagerHelpers,
				contractsCache.DCHFToken,
				_DCHFamount,
				_maxFeePercentage
			);
			vars.netDebt = vars.netDebt.add(vars.DCHFFee);
		}
		// 检查净债务是否大于等于最小净债务
		_requireAtLeastMinNetDebt(vars.asset, vars.netDebt);

		// ICR is based on the composite debt, i.e. the requested DCHF amount + DCHF borrowing fee + DCHF gas comp.
		// ICR是基于复合债务的,即要求的DCHF数量 + DCHF借贷费用 + DCHF gas补偿
		// 获取复合债务(提取债务+gas赔偿),用于计算ICR(个人抵押率)
		vars.compositeDebt = _getCompositeDebt(vars.asset, vars.netDebt);
		assert(vars.compositeDebt > 0);

		// 分别计算ICR和NICR
		vars.ICR = DfrancMath._computeCR(_tokenAmount, vars.compositeDebt, vars.price);
		vars.NICR = DfrancMath._computeNominalCR(_tokenAmount, vars.compositeDebt);

		// 判断是否处于恢复模式
		if (isRecoveryMode) {
			// 检查新的ICR是否大于等于CCR,否则无法执行该操作
			_requireICRisAboveCCR(vars.asset, vars.ICR);
		} else {
			// 检查新的ICR是否大于MCR(即会导致ICR<MCR的操作将不被允许,否则会被清算)
			_requireICRisAboveMCR(vars.asset, vars.ICR);
			// 当trove发生变化时获取新的TCR(系统总抵押率)
			uint256 newTCR = _getNewTCRFromTroveChange(
				vars.asset,
				_tokenAmount,
				true,
				vars.compositeDebt,
				true,
				vars.price
			); // bools: coll increase, debt increase 两个布尔值表示collateral增加,debt增加
			// 检查新的TCR是否大于CCR(即会导致TCR<CCR的操作将不被允许,否则会进入恢复模式)
			_requireNewTCRisAboveCCR(vars.asset, newTCR);
		}

		// Set the trove struct's properties
		// 设置trove结构体属性值
		contractsCache.troveManagerHelpers.setTroveStatus(vars.asset, msg.sender, 1);
		// 增加trove的collateral
		contractsCache.troveManagerHelpers.increaseTroveColl(vars.asset, msg.sender, _tokenAmount);
		// 增加trove的debt
		contractsCache.troveManagerHelpers.increaseTroveDebt(
			vars.asset,
			msg.sender,
			vars.compositeDebt
		);

		// 更新借贷者的L_ETH和L_DCHFDebt快照以反映当前价值
		contractsCache.troveManagerHelpers.updateTroveRewardSnapshots(vars.asset, msg.sender);
		// 据借贷者的最新collateral的价值来更新他的stake(可理解为股份/权益比例)
		vars.stake = contractsCache.troveManagerHelpers.updateStakeAndTotalStakes(
			vars.asset,
			msg.sender
		);

		// 将trove添加到sortTrove列表中
		sortedTroves.insert(vars.asset, msg.sender, vars.NICR, _upperHint, _lowerHint);
		// 将trove的拥有者添加到数组中并返回其在数组的下标
		vars.arrayIndex = contractsCache.troveManagerHelpers.addTroveOwnerToArray(
			vars.asset,
			msg.sender
		);
		emit TroveCreated(vars.asset, msg.sender, vars.arrayIndex);

		// Move the ether to the Active Pool, and mint the DCHFAmount to the borrower
		// 发送ETH到Active Pool中并增加其记录的ETH余额
		_activePoolAddColl(vars.asset, contractsCache.activePool, _tokenAmount);
		// 发行_DCHFAmount数量的DCHF给调用者并增加总活跃债务(_netDebtIncrease可能包括DCHFFee)
		_withdrawDCHF(
			vars.asset,
			contractsCache.activePool,
			contractsCache.DCHFToken,
			msg.sender,
			_DCHFamount,
			vars.netDebt
		);
		// Move the DCHF gas compensation to the Gas Pool
		// 将DCHF gas补偿费用移动到Gas Pool中
		_withdrawDCHF(
			vars.asset,
			contractsCache.activePool,
			contractsCache.DCHFToken,
			gasPoolAddress,
			dfrancParams.DCHF_GAS_COMPENSATION(vars.asset),
			dfrancParams.DCHF_GAS_COMPENSATION(vars.asset)
		);

		emit TroveUpdated(
			vars.asset,
			msg.sender,
			vars.compositeDebt,
			_tokenAmount,
			vars.stake,
			BorrowerOperation.openTrove
		);
		emit DCHFBorrowingFeePaid(vars.asset, msg.sender, vars.DCHFFee);
	}

	// Send ETH as collateral to a trove
	/*
	 * @note 将ETH作为抵押物发送给trove
	 */
	function addColl(
		address _asset,
		uint256 _assetSent,
		address _upperHint,
		address _lowerHint
	) external payable override {
		_adjustTrove(
			_asset,
			getMethodValue(_asset, _assetSent, false),
			msg.sender,
			0,
			0,
			false,
			_upperHint,
			_lowerHint,
			0
		);
	}

	// Send ETH as collateral to a trove. Called by only the Stability Pool.
	/*
	 * @note 将ETH作为抵押物发送到trove,仅由Stability Pool调用
	 */
	function moveETHGainToTrove(
		address _asset,
		uint256 _amountMoved,
		address _borrower,
		address _upperHint,
		address _lowerHint
	) external payable override {
		_requireCallerIsStabilityPool();
		_adjustTrove(
			_asset,
			getMethodValue(_asset, _amountMoved, false),
			_borrower,
			0,
			0,
			false,
			_upperHint,
			_lowerHint,
			0
		);
	}

	// Withdraw ETH collateral from a trove
	/*
	 * @note 从trove中提取ETH抵押物
	 */
	function withdrawColl(
		address _asset,
		uint256 _collWithdrawal,
		address _upperHint,
		address _lowerHint
	) external override {
		_adjustTrove(_asset, 0, msg.sender, _collWithdrawal, 0, false, _upperHint, _lowerHint, 0);
	}

	// Withdraw DCHF tokens from a trove: mint new DCHF tokens to the owner, and increase the trove's debt accordingly
	/*
	 * @note 从trove中提取DCHF token,即向owner发行新的DCHF token,并相应地增加trove的债务
	 */
	function withdrawDCHF(
		address _asset,
		uint256 _maxFeePercentage,
		uint256 _DCHFamount,
		address _upperHint,
		address _lowerHint
	) external override {
		_adjustTrove(
			_asset,
			0,
			msg.sender,
			0,
			_DCHFamount,
			true,
			_upperHint,
			_lowerHint,
			_maxFeePercentage
		);
	}

	// Repay DCHF tokens to a Trove: Burn the repaid DCHF tokens, and reduce the trove's debt accordingly
	/*
	 * @note 将DCHF token偿还给trove,即销毁偿还的DCHF token并相应地减少trove的债务
	 */
	function repayDCHF(
		address _asset,
		uint256 _DCHFamount,
		address _upperHint,
		address _lowerHint
	) external override {
		_adjustTrove(_asset, 0, msg.sender, 0, _DCHFamount, false, _upperHint, _lowerHint, 0);
	}

	/*
	 * @note 调整trove,既可以调整debt,又可以充值新的collateral或取出collateral
	 */
	function adjustTrove(
		address _asset,
		uint256 _assetSent,
		uint256 _maxFeePercentage,
		uint256 _collWithdrawal,
		uint256 _DCHFChange,
		bool _isDebtIncrease,
		address _upperHint,
		address _lowerHint
	) external payable override {
		_adjustTrove(
			_asset,
			getMethodValue(_asset, _assetSent, true),
			msg.sender,
			_collWithdrawal,
			_DCHFChange,
			_isDebtIncrease,
			_upperHint,
			_lowerHint,
			_maxFeePercentage
		);
	}

	/*
	 * _adjustTrove(): Alongside a debt change, this function can perform either a collateral top-up or a collateral withdrawal.
	 *
	 * It therefore expects either a positive msg.value, or a positive _collWithdrawal argument.
	 *
	 * If both are positive, it will revert.
	 */
	/*
	 * @note 调整trove,既可以调整debt,又可以充值新的collateral或取出collateral
	 */
	function _adjustTrove(
		address _asset,
		uint256 _assetSent,
		address _borrower,
		uint256 _collWithdrawal,
		uint256 _DCHFChange,
		bool _isDebtIncrease,
		address _upperHint,
		address _lowerHint,
		uint256 _maxFeePercentage
	) internal {
		ContractsCache memory contractsCache = ContractsCache(
			troveManager,
			troveManagerHelpers,
			dfrancParams.activePool(),
			DCHFToken
		);
		LocalVariables_adjustTrove memory vars;
		vars.asset = _asset;

		// 检查传入的ETH是否为0或者等于_assetSent数量
		require(
			msg.value == 0 || msg.value == _assetSent,
			"BorrowerOp: _AssetSent and Msg.value aren't the same!"
		);

		// 预言机获取该asset的价格
		vars.price = dfrancParams.priceFeed().fetchPrice(vars.asset);
		// 检查是否处于恢复模式
		bool isRecoveryMode = _checkRecoveryMode(vars.asset, vars.price);

		// 当债务提升时检查最高费用比例是否合法以及非零debt是否发生变化
		if (_isDebtIncrease) {
			_requireValidMaxFeePercentage(vars.asset, _maxFeePercentage, isRecoveryMode);
			_requireNonZeroDebtChange(_DCHFChange);
		}
		// 禁止同时充值和提取collateral
		_requireSingularCollChange(_collWithdrawal, _assetSent);
		// 检查collateral或debt是否有非零变化
		_requireNonZeroAdjustment(_collWithdrawal, _DCHFChange, _assetSent);
		// 检查trove是否处于活跃状态
		_requireTroveisActive(vars.asset, contractsCache.troveManagerHelpers, _borrower);

		// Confirm the operation is either a borrower adjusting their own trove, or a pure ETH transfer from the Stability Pool to a trove
		// 确保借贷操作是借贷者调整自己的trove或者是从Stability Pool向trove的纯ETH转账
		assert(
			msg.sender == _borrower ||
				(stabilityPoolManager.isStabilityPool(msg.sender) &&
					_assetSent > 0 &&
					_DCHFChange == 0)
		);

		// 将借贷者从再分配中获得的collateral和debt奖励发送到他们的trove中
		contractsCache.troveManagerHelpers.applyPendingRewards(vars.asset, _borrower);

		// Get the collChange based on whether or not ETH was sent in the transaction
		// 根据交易中是否发送了ETH来获取collateral的变化量(充值/提取)
		(vars.collChange, vars.isCollIncrease) = _getCollChange(_assetSent, _collWithdrawal);

		vars.netDebtChange = _DCHFChange;

		// If the adjustment incorporates a debt increase and system is in Normal Mode, then trigger a borrowing fee
		// 如果该调整包括debt的增加且系统处于正常模式,则触发计算借贷费用
		if (_isDebtIncrease && !isRecoveryMode) {
			vars.DCHFFee = _triggerBorrowingFee(
				vars.asset,
				contractsCache.troveManager,
				contractsCache.troveManagerHelpers,
				contractsCache.DCHFToken,
				_DCHFChange,
				_maxFeePercentage
			);
			// 计算调整之前原始的debt变化包括fee(可理解为debt调整前对之前的fee进行一次结算)
			vars.netDebtChange = vars.netDebtChange.add(vars.DCHFFee); // The raw debt change includes the fee
		}

		// 获取debt和collateral
		vars.debt = contractsCache.troveManagerHelpers.getTroveDebt(vars.asset, _borrower);
		vars.coll = contractsCache.troveManagerHelpers.getTroveColl(vars.asset, _borrower);

		// Get the trove's old ICR before the adjustment, and what its new ICR will be after the adjustment
		// 在调整前获取trove的旧ICR,接着计算调整之后新的ICR
		vars.oldICR = DfrancMath._computeCR(vars.coll, vars.debt, vars.price);
		vars.newICR = _getNewICRFromTroveChange(
			vars.coll,
			vars.debt,
			vars.collChange,
			vars.isCollIncrease,
			vars.netDebtChange,
			_isDebtIncrease,
			vars.price
		);
		// 检查提取的collateral的数量是否小于等于trove持有的collaboration数量
		require(
			_collWithdrawal <= vars.coll,
			"BorrowerOp: Trying to remove more than the trove holds"
		);

		// Check the adjustment satisfies all conditions for the current system mode
		// 检查此次调整是否满足当前系统模式的所有条件
		_requireValidAdjustmentInCurrentMode(
			vars.asset,
			isRecoveryMode,
			_collWithdrawal,
			_isDebtIncrease,
			vars
		);

		// When the adjustment is a debt repayment, check it's a valid amount and that the caller has enough DCHF
		// 当此次调整是债务偿还时,检查它是否为合法的数量且调用者是否有足够数量的DCHF
		if (!_isDebtIncrease && _DCHFChange > 0) {
			// 检查净债务是否大于等于最小净债务
			_requireAtLeastMinNetDebt(
				vars.asset,
				_getNetDebt(vars.asset, vars.debt).sub(vars.netDebtChange)
			);
			// 检查偿还的DCHF数量是否小于等于trove的债务
			_requireValidDCHFRepayment(vars.asset, vars.debt, vars.netDebtChange);
			// 检查是否有足够的DCHF余额偿还债务
			_requireSufficientDCHFBalance(contractsCache.DCHFToken, _borrower, vars.netDebtChange);
		}

		// 跟增加或减少来更新trove的collateral和debt
		(vars.newColl, vars.newDebt) = _updateTroveFromAdjustment(
			vars.asset,
			contractsCache.troveManager,
			contractsCache.troveManagerHelpers,
			_borrower,
			vars.collChange,
			vars.isCollIncrease,
			vars.netDebtChange,
			_isDebtIncrease
		);
		// 根据借贷者的最新collateral的价值来更新他的stake(可理解为股份/权益比例)
		vars.stake = contractsCache.troveManagerHelpers.updateStakeAndTotalStakes(
			vars.asset,
			_borrower
		);

		// Re-insert trove in to the sorted list
		// 重新插入trove到排序了的list中
		// 计算新的NICR(个人名义抵押率),考虑collateral和debt的变化
		uint256 newNICR = _getNewNominalICRFromTroveChange(
			vars.coll,
			vars.debt,
			vars.collChange,
			vars.isCollIncrease,
			vars.netDebtChange,
			_isDebtIncrease
		);
		// 根据新的NICR,将trove插入到一个新的位置
		sortedTroves.reInsert(vars.asset, _borrower, newNICR, _upperHint, _lowerHint);

		emit TroveUpdated(
			vars.asset,
			_borrower,
			vars.newDebt,
			vars.newColl,
			vars.stake,
			BorrowerOperation.adjustTrove
		);
		emit DCHFBorrowingFeePaid(vars.asset, msg.sender, vars.DCHFFee);

		// Use the unmodified _DCHFChange here, as we don't send the fee to the user 在此处使用未修改的_DCHFChange，因为我们不会向用户发送费用
		// 根据调整来移动(发行/偿还)DCHF代币债务和(充值/提取)ETH抵押物
		_moveTokensAndETHfromAdjustment(
			vars.asset,
			contractsCache.activePool,
			contractsCache.DCHFToken,
			msg.sender,
			vars.collChange,
			vars.isCollIncrease,
			_DCHFChange,
			_isDebtIncrease,
			vars.netDebtChange
		);
	}

	/*
	 * @note 关闭trove
	 */
	function closeTrove(address _asset) external override {
		ITroveManagerHelpers troveManagerHelpersCached = troveManagerHelpers;
		IActivePool activePoolCached = dfrancParams.activePool();
		IDCHFToken DCHFTokenCached = DCHFToken;

		// 检查trove是否存在且处于活跃状态
		_requireTroveisActive(_asset, troveManagerHelpersCached, msg.sender);
		// 通过预言机获取_asset(抵押物)的价格
		uint256 price = dfrancParams.priceFeed().fetchPrice(_asset);
		// 检查该操作是否处于恢复模式下,处于恢复模式时该操作不允许被执行
		_requireNotInRecoveryMode(_asset, price);

		// 将借贷者从再分配中获得的collateral和debt奖励发送到他们的trove中
		troveManagerHelpersCached.applyPendingRewards(_asset, msg.sender);

		// 获取collateral和debt
		uint256 coll = troveManagerHelpersCached.getTroveColl(_asset, msg.sender);
		uint256 debt = troveManagerHelpersCached.getTroveDebt(_asset, msg.sender);

		// 检查是否有足够的DCHF余额偿还债务
		_requireSufficientDCHFBalance(
			DCHFTokenCached,
			msg.sender,
			debt.sub(dfrancParams.DCHF_GAS_COMPENSATION(_asset))
		);

		// 当trove发生变化时获取新的TCR(系统总抵押率)
		uint256 newTCR = _getNewTCRFromTroveChange(_asset, coll, false, debt, false, price);
		// 检查新的TCR是否大于CCR(即会导致TCR<CCR的操作将不被允许,否则会进入恢复模式)
		_requireNewTCRisAboveCCR(_asset, newTCR);

		// 移除_borrower对于_asset的stake(可理解为股份/权益比例)
		troveManagerHelpersCached.removeStake(_asset, msg.sender);
		// 移除trove的owner
		troveManagerHelpersCached.closeTrove(_asset, msg.sender);

		emit TroveUpdated(_asset, msg.sender, 0, 0, 0, BorrowerOperation.closeTrove);

		// Burn the repaid DCHF from the user's balance and the gas compensation from the Gas Pool
		// 从调用者中销毁净债务(netDebt)数量的DCHF并减少总活跃债务
		_repayDCHF(
			_asset,
			activePoolCached,
			DCHFTokenCached,
			msg.sender,
			debt.sub(dfrancParams.DCHF_GAS_COMPENSATION(_asset))
		);

		// 从Gas Pool中销毁Gas补偿所需数量的DCHF并减少总活跃债务
		_repayDCHF(
			_asset,
			activePoolCached,
			DCHFTokenCached,
			gasPoolAddress,
			dfrancParams.DCHF_GAS_COMPENSATION(_asset)
		);

		// Send the collateral back to the user
		// 将抵押物资产发送回调用者
		activePoolCached.sendAsset(_asset, msg.sender, coll);
	}

	/**
	 * Claim remaining collateral from a redemption or from a liquidation with ICR > MCR in Recovery Mode
	 */
	/*
	 * @note 在恢复模式下通过ICR>MCR从赎回或清算中认领剩余抵押品
	 */
	function claimCollateral(address _asset) external override {
		// send ETH from CollSurplus Pool to owner
		collSurplusPool.claimColl(_asset, msg.sender);
	}

	// --- Helper functions ---

	/*
	 * @note 计算借贷费用
	 */
	function _triggerBorrowingFee(
		address _asset,
		ITroveManager _troveManager,
		ITroveManagerHelpers _troveManagerHelpers,
		IDCHFToken _DCHFToken,
		uint256 _DCHFamount,
		uint256 _maxFeePercentage
	) internal returns (uint256) {
		// 从借贷中衰减基本费率
		_troveManagerHelpers.decayBaseRateFromBorrowing(_asset); // decay the baseRate state variable
		// 计算借贷费用
		uint256 DCHFFee = _troveManagerHelpers.getBorrowingFee(_asset, _DCHFamount);

		// 检查fee比例是否为用户可接受的
		_requireUserAcceptsFee(DCHFFee, _DCHFamount, _maxFeePercentage);

		// Send fee to MON staking contract
		// 将fee发送到MON的质押合约中
		_DCHFToken.mint(_asset, MONStakingAddress, DCHFFee);
		MONStaking.increaseF_DCHF(DCHFFee);

		return DCHFFee;
	}

	/*
	 * @note 根据交易中是否发送了ETH来获取collateral的变化量(充值/提取)
	 */
	function _getCollChange(uint256 _collReceived, uint256 _requestedCollWithdrawal)
		internal
		pure
		returns (uint256 collChange, bool isCollIncrease)
	{
		if (_collReceived != 0) {
			collChange = _collReceived;
			isCollIncrease = true;
		} else {
			collChange = _requestedCollWithdrawal;
		}
	}

	// Update trove's coll and debt based on whether they increase or decrease
	/*
	 * @note 跟增加或减少来更新trove的collateral和debt
	 */
	function _updateTroveFromAdjustment(
		address _asset,
		ITroveManager _troveManager,
		ITroveManagerHelpers _troveManagerHelpers,
		address _borrower,
		uint256 _collChange,
		bool _isCollIncrease,
		uint256 _debtChange,
		bool _isDebtIncrease
	) internal returns (uint256, uint256) {
		uint256 newColl = (_isCollIncrease)
			? _troveManagerHelpers.increaseTroveColl(_asset, _borrower, _collChange)
			: _troveManagerHelpers.decreaseTroveColl(_asset, _borrower, _collChange);
		uint256 newDebt = (_isDebtIncrease)
			? _troveManagerHelpers.increaseTroveDebt(_asset, _borrower, _debtChange)
			: _troveManagerHelpers.decreaseTroveDebt(_asset, _borrower, _debtChange);

		return (newColl, newDebt);
	}

	/*
	 * @note 根据调整来移动(发行/偿还)DCHF代币债务和(充值/提取)ETH抵押物
	 */
	function _moveTokensAndETHfromAdjustment(
		address _asset,
		IActivePool _activePool,
		IDCHFToken _DCHFToken,
		address _borrower,
		uint256 _collChange,
		bool _isCollIncrease,
		uint256 _DCHFChange,
		bool _isDebtIncrease,
		uint256 _netDebtChange
	) internal {
		// 判断债务是否增加
		if (_isDebtIncrease) {
			// 发行DCHF
			_withdrawDCHF(_asset, _activePool, _DCHFToken, _borrower, _DCHFChange, _netDebtChange);
		} else {
			// 偿还DCHF
			_repayDCHF(_asset, _activePool, _DCHFToken, _borrower, _DCHFChange);
		}

		// 判断抵押物是否增加
		if (_isCollIncrease) {
			// 充值抵押物
			_activePoolAddColl(_asset, _activePool, _collChange);
		} else {
			// 提取抵押物
			_activePool.sendAsset(_asset, _borrower, _collChange);
		}
	}

	// Send ETH to Active Pool and increase its recorded ETH balance
	/*
	 * @note 发送ETH到Active Pool中并增加其记录的ETH余额
	 */
	function _activePoolAddColl(
		address _asset,
		IActivePool _activePool,
		uint256 _amount
	) internal {
		if (_asset == ETH_REF_ADDRESS) {
			(bool success, ) = address(_activePool).call{ value: _amount }("");
			require(success, "BorrowerOps: Sending ETH to ActivePool failed");
		} else {
			IERC20(_asset).safeTransferFrom(
				msg.sender,
				address(_activePool),
				SafetyTransfer.decimalsCorrection(_asset, _amount)
			);

			_activePool.receivedERC20(_asset, _amount);
		}
	}

	// Issue the specified amount of DCHF to _account and increases the total active debt (_netDebtIncrease potentially includes a DCHFFee)
	/*
	 * @note 发行指定数量的DCHF给_account并增加总活跃债务(_netDebtIncrease可能包括DCHFFee)
	 */
	function _withdrawDCHF(
		address _asset,
		IActivePool _activePool,
		IDCHFToken _DCHFToken,
		address _account,
		uint256 _DCHFamount,
		uint256 _netDebtIncrease
	) internal {
		// 增加_asset对应的DCHF债务
		_activePool.increaseDCHFDebt(_asset, _netDebtIncrease);
		_DCHFToken.mint(_asset, _account, _DCHFamount);
	}

	// Burn the specified amount of DCHF from _account and decreases the total active debt
	/*
	 * @note 从_account中销毁指定数量的DCHF并减少总活跃债务
	 */
	function _repayDCHF(
		address _asset,
		IActivePool _activePool,
		IDCHFToken _DCHFToken,
		address _account,
		uint256 _DCHF
	) internal {
		// 减少DCHF债务
		_activePool.decreaseDCHFDebt(_asset, _DCHF);
		_DCHFToken.burn(_account, _DCHF);
	}

	// --- 'Require' wrapper functions ---

	/*
	 * @note 判断充值collateral和提取collateral是否同时进行(不允许同时)
	 */
	function _requireSingularCollChange(uint256 _collWithdrawal, uint256 _amountSent)
		internal
		view
	{
		require(
			_collWithdrawal == 0 || _amountSent == 0,
			"BorrowerOperations: Cannot withdraw and add coll"
		);
	}

	/*
	 * @note 要求必须有collateral变化或者debt变化
	 */
	function _requireNonZeroAdjustment(
		uint256 _collWithdrawal,
		uint256 _DCHFChange,
		uint256 _assetSent
	) internal view {
		require(
			msg.value != 0 || _collWithdrawal != 0 || _DCHFChange != 0 || _assetSent != 0,
			"BorrowerOps: There must be either a collateral change or a debt change"
		);
	}

	/*
	 * @note 检查trove是否存在且处于活跃状态
	 */
	function _requireTroveisActive(
		address _asset,
		ITroveManagerHelpers _troveManagerHelpers,
		address _borrower
	) internal view {
		uint256 status = _troveManagerHelpers.getTroveStatus(_asset, _borrower);
		require(status == 1, "BorrowerOps: Trove does not exist or is closed");
	}

	/*
	 * @note 检查trove是否处于不活跃状态
	 */
	function _requireTroveisNotActive(
		address _asset,
		ITroveManager _troveManager,
		ITroveManagerHelpers _troveManagerHelpers,
		address _borrower
	) internal view {
		uint256 status = _troveManagerHelpers.getTroveStatus(_asset, _borrower);
		require(status != 1, "BorrowerOps: Trove is active");
	}

	/*
	 * @note 判断当debt上升时非零debt是否发生变化
	 */
	function _requireNonZeroDebtChange(uint256 _DCHFChange) internal pure {
		require(_DCHFChange > 0, "BorrowerOps: Debt increase requires non-zero debtChange");
	}

	/*
	 * @note 检查该操作是否处于恢复模式下,处于恢复模式时该操作不允许被执行
	 */
	function _requireNotInRecoveryMode(address _asset, uint256 _price) internal view {
		require(
			!_checkRecoveryMode(_asset, _price),
			"BorrowerOps: Operation not permitted during Recovery Mode"
		);
	}

	/*
	 * @note 处于恢复模式时不允许抵押物提取
	 */
	function _requireNoCollWithdrawal(uint256 _collWithdrawal) internal pure {
		require(
			_collWithdrawal == 0,
			"BorrowerOps: Collateral withdrawal not permitted Recovery Mode"
		);
	}

	/*
	 * @note 检查此次调整是否满足当前系统模式的所有条件
	 */
	function _requireValidAdjustmentInCurrentMode(
		address _asset,
		bool _isRecoveryMode,
		uint256 _collWithdrawal,
		bool _isDebtIncrease,
		LocalVariables_adjustTrove memory _vars
	) internal view {
		/*
		 *In Recovery Mode, only allow:
		 *
		 * - Pure collateral top-up 				纯抵押物充值
		 * - Pure debt repayment 					纯债务偿还
		 * - Collateral top-up with debt repayment  抵押物充值和债务偿还
		 * - A debt increase combined with a collateral top-up which makes the ICR >= 150% and improves the ICR (and by extension improves the TCR).
		 *   债务的增加与抵押物充值相结合使ICR>=150%,改善ICR(同时进一步改善TCR)
		 *
		 * In Normal Mode, ensure:
		 *
		 * - The new ICR is above MCR 					 新的ICR高于MCR
		 * - The adjustment won't pull the TCR below CCR 调整不能使得TCR低于CCR
		 */
		if (_isRecoveryMode) {
			// 不允许提取抵押物
			_requireNoCollWithdrawal(_collWithdrawal);
			// 判断debt是否增加
			if (_isDebtIncrease) {
				// 检查新的ICR是否大于等于CCR,否则无法执行该操作
				_requireICRisAboveCCR(_asset, _vars.newICR);
				// 检查新的ICR是否大于旧的ICR(在恢复模式下不能降低trove的ICR)
				_requireNewICRisAboveOldICR(_vars.newICR, _vars.oldICR);
			}
		} else {
			// if Normal Mode
			// 检查新的ICR是否大于MCR(即会导致ICR<MCR的操作将不被允许)
			_requireICRisAboveMCR(_asset, _vars.newICR);
			// 当trove发生变化时获取新的TCR(系统总抵押率)
			_vars.newTCR = _getNewTCRFromTroveChange(
				_asset,
				_vars.collChange,
				_vars.isCollIncrease,
				_vars.netDebtChange,
				_isDebtIncrease,
				_vars.price
			);

			// 检查新的TCR是否大于CCR(即会导致TCR<CCR的操作将不被允许,否则会进入恢复模式)
			_requireNewTCRisAboveCCR(_asset, _vars.newTCR);
		}
	}

	/*
	 * @note 检查新的ICR是否大于MCR(即会导致ICR<MCR的操作将不被允许,否则会被清算)
	 */
	function _requireICRisAboveMCR(address _asset, uint256 _newICR) internal view {
		require(
			_newICR >= dfrancParams.MCR(_asset),
			"BorrowerOps: An operation that would result in ICR < MCR is not permitted"
		);
	}

	/*
	 * @note 检查新的ICR是否大于等于CCR,否则无法执行该操作
	 */
	function _requireICRisAboveCCR(address _asset, uint256 _newICR) internal view {
		require(
			_newICR >= dfrancParams.CCR(_asset),
			"BorrowerOps: Operation must leave trove with ICR >= CCR"
		);
	}

	/*
	 * @note 检查新的ICR是否大于旧的ICR(在恢复模式下不能降低trove的ICR)
	 */
	function _requireNewICRisAboveOldICR(uint256 _newICR, uint256 _oldICR) internal pure {
		require(
			_newICR >= _oldICR,
			"BorrowerOps: Cannot decrease your Trove's ICR in Recovery Mode"
		);
	}

	/*
	 * @note 检查新的TCR是否大于CCR(即会导致TCR<CCR的操作将不被允许,否则会进入恢复模式)
	 */
	function _requireNewTCRisAboveCCR(address _asset, uint256 _newTCR) internal view {
		require(
			_newTCR >= dfrancParams.CCR(_asset),
			"BorrowerOps: An operation that would result in TCR < CCR is not permitted"
		);
	}

	/*
	 * @note 检查净债务是否大于等于最小净债务
	 */
	function _requireAtLeastMinNetDebt(address _asset, uint256 _netDebt) internal view {
		require(
			_netDebt >= dfrancParams.MIN_NET_DEBT(_asset),
			"BorrowerOps: Trove's net debt must be greater than minimum"
		);
	}

	/*
	 * @note 检查偿还的DCHF数量是否小于等于trove的债务
	 */
	function _requireValidDCHFRepayment(
		address _asset,
		uint256 _currentDebt,
		uint256 _debtRepayment
	) internal view {
		require(
			_debtRepayment <= _currentDebt.sub(dfrancParams.DCHF_GAS_COMPENSATION(_asset)),
			"BorrowerOps: Amount repaid must not be larger than the Trove's debt"
		);
	}

	/*
	 * @note 检查调用者是否为Stability Pool
	 */
	function _requireCallerIsStabilityPool() internal view {
		require(
			stabilityPoolManager.isStabilityPool(msg.sender),
			"BorrowerOps: Caller is not Stability Pool"
		);
	}

	/*
	 * @note 检查是否有足够的DCHF余额偿还债务
	 */
	function _requireSufficientDCHFBalance(
		IDCHFToken _DCHFToken,
		address _borrower,
		uint256 _debtRepayment
	) internal view {
		require(
			_DCHFToken.balanceOf(_borrower) >= _debtRepayment,
			"BorrowerOps: Caller doesnt have enough DCHF to make repayment"
		);
	}

	/*
	 * @note 检查最高费用比例是否合法
	 *		1. 处于恢复模式时,该比例需小于等于100%
	 *		2. 不处于恢复模式时,该比例需处于0.5%-100%之间
	 */
	function _requireValidMaxFeePercentage(
		address _asset,
		uint256 _maxFeePercentage,
		bool _isRecoveryMode
	) internal view {
		if (_isRecoveryMode) {
			require(
				_maxFeePercentage <= dfrancParams.DECIMAL_PRECISION(),
				"Max fee percentage must less than or equal to 100%"
			);
		} else {
			require(
				_maxFeePercentage >= dfrancParams.BORROWING_FEE_FLOOR(_asset) &&
					_maxFeePercentage <= dfrancParams.DECIMAL_PRECISION(),
				"Max fee percentage must be between 0.5% and 100%"
			);
		}
	}

	// --- ICR and TCR getters ---

	// Compute the new collateral ratio, considering the change in coll and debt. Assumes 0 pending rewards.
	/*
	 * @note 计算新的NICR(个人名义抵押率),考虑collateral和debt的变化
	 */
	function _getNewNominalICRFromTroveChange(
		uint256 _coll,
		uint256 _debt,
		uint256 _collChange,
		bool _isCollIncrease,
		uint256 _debtChange,
		bool _isDebtIncrease
	) internal pure returns (uint256) {
		(uint256 newColl, uint256 newDebt) = _getNewTroveAmounts(
			_coll,
			_debt,
			_collChange,
			_isCollIncrease,
			_debtChange,
			_isDebtIncrease
		);

		uint256 newNICR = DfrancMath._computeNominalCR(newColl, newDebt);
		return newNICR;
	}

	// Compute the new collateral ratio, considering the change in coll and debt. Assumes 0 pending rewards.
	/*
	 * @note 计算新的ICR(个人抵押率),考虑collateral和debt的变化
	 */
	function _getNewICRFromTroveChange(
		uint256 _coll,
		uint256 _debt,
		uint256 _collChange,
		bool _isCollIncrease,
		uint256 _debtChange,
		bool _isDebtIncrease,
		uint256 _price
	) internal pure returns (uint256) {
		(uint256 newColl, uint256 newDebt) = _getNewTroveAmounts(
			_coll,
			_debt,
			_collChange,
			_isCollIncrease,
			_debtChange,
			_isDebtIncrease
		);

		uint256 newICR = DfrancMath._computeCR(newColl, newDebt, _price);
		return newICR;
	}

	/*
	 * @note 获取trove调整之后collateral和debt的数量
	 */
	function _getNewTroveAmounts(
		uint256 _coll,
		uint256 _debt,
		uint256 _collChange,
		bool _isCollIncrease,
		uint256 _debtChange,
		bool _isDebtIncrease
	) internal pure returns (uint256, uint256) {
		uint256 newColl = _coll;
		uint256 newDebt = _debt;

		newColl = _isCollIncrease ? _coll.add(_collChange) : _coll.sub(_collChange);
		newDebt = _isDebtIncrease ? _debt.add(_debtChange) : _debt.sub(_debtChange);

		return (newColl, newDebt);
	}

	/*
	 * @note 当trove发生变化时获取新的TCR(系统总抵押率)
	 */
	function _getNewTCRFromTroveChange(
		address _asset,
		uint256 _collChange,
		bool _isCollIncrease,
		uint256 _debtChange,
		bool _isDebtIncrease,
		uint256 _price
	) internal view returns (uint256) {
		uint256 totalColl = getEntireSystemColl(_asset);
		uint256 totalDebt = getEntireSystemDebt(_asset);

		totalColl = _isCollIncrease ? totalColl.add(_collChange) : totalColl.sub(_collChange);
		totalDebt = _isDebtIncrease ? totalDebt.add(_debtChange) : totalDebt.sub(_debtChange);

		uint256 newTCR = DfrancMath._computeCR(totalColl, totalDebt, _price);
		return newTCR;
	}

	/*
	 * @note 获取复合债务(提取债务+gas赔偿),用于计算ICR(个人抵押率)
	 */
	function getCompositeDebt(address _asset, uint256 _debt)
		external
		view
		override
		returns (uint256)
	{
		return _getCompositeDebt(_asset, _debt);
	}

	/*
	 * @note 获取方法值
	 */
	function getMethodValue(
		address _asset,
		uint256 _amount,
		bool canBeZero
	) private view returns (uint256) {
		// 判断_asset是否为ETH
		bool isEth = _asset == address(0);

		// 检查 可否为0 或 _asset为0地址且发送的代币数量不为0 或 _asset不为0地址且发送的代币数量等于0
		// 即输入的参数中,只有当发送的_asset是ETH时_amount才会被msg.sender的数值覆盖,否则则直接使用_amount
		require(
			(canBeZero || (isEth && msg.value != 0)) || (!isEth && msg.value == 0),
			"BorrowerOp: Invalid Input. Override msg.value only if using ETH asset, otherwise use _tokenAmount"
		);

		if (_asset == address(0)) {
			_amount = msg.value;
		}

		return _amount;
	}
}
