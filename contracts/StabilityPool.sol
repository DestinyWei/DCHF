// SPDX-License-Identifier: MIT

pragma solidity ^0.8.14;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./Interfaces/IBorrowerOperations.sol";
import "./Interfaces/IStabilityPool.sol";
import "./Interfaces/IBorrowerOperations.sol";
import "./Interfaces/ITroveManager.sol";
import "./Interfaces/ITroveManagerHelpers.sol";
import "./Interfaces/IDCHFToken.sol";
import "./Interfaces/ISortedTroves.sol";
import "./Interfaces/ICommunityIssuance.sol";
import "./Dependencies/DfrancBase.sol";
import "./Dependencies/DfrancSafeMath128.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/SafetyTransfer.sol";
import "./Dependencies/Initializable.sol";

/*
 * @notice 稳定池合约
 *
 * @note 包含的内容如下:
 *		function getNameBytes() 																	获取STABILITY_POOL_NAME_BYTES参数的值
 *		function getAssetType() 																	获取assetAddress的值
 *		function setAddresses(address _assetAddress, address _borrowerOperationsAddress,
							  address _troveManagerAddress, address _troveManagerHelpersAddress,
							  address _dchfTokenAddress, address _sortedTrovesAddress,
							  address _communityIssuanceAddress, address _dfrancParamsAddress) 		初始化设置地址 1. 检查合约地址是否不为0地址以及检查调用的合约是否存在 2. 赋值
 *		function getAssetBalance() 																	获取当前池子的ETH余额
 *		function getTotalDCHFDeposits() 															获取当前池子中存储的DCHF
 *		function provideToSP(uint256 _amount) 														Stability Pool提供MON和(MON，ETH)累积收益给存款者
 *		function withdrawFromSP(uint256 _amount) 													从Stability Pool中提款
 *		function withdrawAssetGainToTrove(address _upperHint, address _lowerHint) 					提取资产收益到Trove
 *		function _triggerMONIssuance(ICommunityIssuance _communityIssuance) 						触发MON发行
 *		function _updateG(uint256 _MONIssuance) 														更新MON收益"G"
 *		function _computeMONPerUnitStaked(uint256 _MONIssuance, uint256 _totalDCHFDeposits) 		计算每单位stake的MON
 *		function offset(uint256 _debtToOffset, uint256 _collToAdd) 									(尽可能)抵消Stability Pool中包含DCHF的特定债务,并将Trove的ETH抵押品从Active Pool转移到Stability Pool
 *		function _computeRewardsPerUnitStaked(uint256 _collToAdd, uint256 _debtToOffset,
											  uint256 _totalDCHFDeposits) 							计算每单位stake的奖励
 *		function _updateRewardSumAndProduct(uint256 _AssetGainPerUnitStaked,
											uint256 _DCHFLossPerUnitStaked) 						更新Stability Pool奖励总和S和产品P
 *		function _moveOffsetCollAndDebt(uint256 _collToAdd, uint256 _debtToOffset) 					移除抵消的质押物和债务
 *		function _decreaseDCHF(uint256 _amount) 													减少DCHF存款
 *		function getDepositorAssetGain(address _depositor) 											获取存款者资产收益
 *		function getDepositorAssetGain1e18(address _depositor) 										获取存款者资产收益(进制为1e18)
 *		function _getAssetGainFromSnapshots(uint256 initialDeposit, Snapshots memory snapshots) 	从快照中获取资产收益
 *		function getDepositorMONGain(address _depositor) 											获取存款者的MON收益
 *		function _getMONGainFromSnapshots(uint256 initialStake, Snapshots memory snapshots) 		从快照中获取MON收益
 *		function getCompoundedDCHFDeposit(address _depositor) 										获取复合DCHF存款
 *		function getCompoundedTotalStake() 															获取复合总stake
 *		function _getCompoundedStakeFromSnapshots(uint256 initialStake, Snapshots memory snapshots) 从快照中获取复合stake
 *		function _sendDCHFtoStabilityPool(address _address, uint256 _amount) 						从用户中发送DCHF到Stability Pool地址,同时更新其记录的DCHF
 *		function _sendAssetGainToDepositor(uint256 _amount, uint256 _amountEther) 					发送asset收益给存款者
 *		function _sendDCHFToDepositor(address _depositor, uint256 DCHFWithdrawal) 					发送DCHF给用户同时减少Pool中的DCHF
 *		function _updateDepositAndSnapshots(address _depositor, uint256 _newValue) 					更新存款和快照信息
 *		function _updateStakeAndSnapshots(uint256 _newValue) 										更新stake和快照信息
 *		function _payOutMONGains(ICommunityIssuance _communityIssuance, address _depositor) 		支付MON收益给存款者
 *		function _requireCallerIsActivePool() 														检查调用者是否为Active Pool地址
 *		function _requireCallerIsTroveManager() 													检查调用者是否为trove管理者合约地址或trove管理者助手合约地址
 *		function _requireNoUnderCollateralizedTroves() 												检查是否存在ICR<MCR的trove,是则禁止其提款
 *		function _requireUserHasDeposit(uint256 _initialDeposit) 									检查用户是否有存款
 *		function _requireNonZeroAmount(uint256 _amount) 											检查数量是否不为0
 *		function _requireUserHasTrove(address _depositor) 											检查用户是否有活跃的Trove
 *		function _requireUserHasETHGain(address _depositor) 										检查用户是否有ETH收益
 *		function receivedERC20(address _asset, uint256 _amount) 									接收ERC20代币
 *		receive() 																					接收Active Pool发送来的asset
 */
contract StabilityPool is
	DfrancBase,
	CheckContract,
	ReentrancyGuard,
	Initializable,
	IStabilityPool
{
	using SafeMath for uint256;
	using DfrancSafeMath128 for uint128;
	using SafeERC20 for IERC20;

	string public constant NAME = "StabilityPool";
	bytes32 public constant STABILITY_POOL_NAME_BYTES =
		0xf704b47f65a99b2219b7213612db4be4a436cdf50624f4baca1373ef0de0aac7;

	IBorrowerOperations public borrowerOperations;

	ITroveManager public troveManager;

	ITroveManagerHelpers public troveManagerHelpers;

	IDCHFToken public dchfToken;

	// Needed to check if there are pending liquidations 需要检查是否有待处理的清算
	ISortedTroves public sortedTroves;

	ICommunityIssuance public communityIssuance;

	address internal assetAddress;

	uint256 internal assetBalance; // deposited ether tracker

	// Tracker for DCHF held in the pool. Changes when users deposit/withdraw, and when Trove debt is offset.
	// 在Pool中持有的DCHF跟踪器.当用户存款/提取以及Trove债务被抵消时发生变化.
	uint256 internal totalDCHFDeposits;

	// --- Data structures ---

	struct Snapshots {
		uint256 S;
		uint256 P;
		uint256 G;
		uint128 scale;
		uint128 epoch;
	}

	mapping(address => uint256) public deposits; // depositor address -> Deposit struct
	mapping(address => Snapshots) public depositSnapshots; // depositor address -> snapshots struct

	uint256 public totalStakes;
	Snapshots public systemSnapshots;

	/*  Product 'P': Running product by which to multiply an initial deposit, in order to find the current compounded deposit,
	 * after a series of liquidations have occurred, each of which cancel some DCHF debt with the deposit.
	 *  P是一个乘以初始存款的运行中项目,目的是为了获取在发生一系列清算事件之后当前的复合存款,每次清算都会用存款抵消一部分DCHF债务
	 *
	 * During its lifetime, a deposit's value evolves from d_t to d_t * P / P_t , where P_t
	 * is the snapshot of P taken at the instant the deposit was made. 18-digit decimal.
	 * 在它的生命周期内,存款的价值从d_t到d_t * P / P_t演变,这里的P_t是指在存款时拍摄的P快照
	 */
	uint256 public P;

	uint256 public constant SCALE_FACTOR = 1e9; // 比例因子

	// Each time the scale of P shifts by SCALE_FACTOR, the scale is incremented by 1  P每变化SCALE_FACTOR时,scale会增加1
	uint128 public currentScale;

	// With each offset that fully empties the Pool, the epoch is incremented by 1  每次变化完全清空Pool时,epoch增加1
	uint128 public currentEpoch;

	/* ETH Gain sum 'S': During its lifetime, each deposit d_t earns an ETH gain of ( d_t * [S - S_t] )/P_t, where S_t
	 * is the depositor's snapshot of S taken at the time t when the deposit was made.
	 * ETH收益总和“S”:在其生命周期内,每笔存款d_t赚取的ETH收益为(d_t * [S - S_t]) / P_t,其中S_t是存款者在存款时拍摄的S快照
	 *
	 * The 'S' sums are stored in a nested mapping (epoch => scale => sum):
	 *
	 * - The inner mapping records the sum S at different scales  内层mapping记录的是不同scale下的S总和
	 * - The outer mapping records the (scale => sum) mappings, for different epochs.  外层mapping记录的是不同epoch下的(scale => sum) mapping
	 */
	mapping(uint128 => mapping(uint128 => uint256)) public epochToScaleToSum;

	/*
	 * Similarly, the sum 'G' is used to calculate MON gains. During it's lifetime, each deposit d_t earns a MON gain of
	 *  ( d_t * [G - G_t] )/P_t, where G_t is the depositor's snapshot of G taken at time t when  the deposit was made.
	 * 类似地,总和"G"是用于计算MON代币收益.在其生命周期内,每笔存款d_t赚取的MON收益为(d_t * [G - G_t]) / P_t,其中G_t是存款者在存款时拍摄的G快照
	 *
	 *  MON reward events occur are triggered by depositor operations (new deposit, topup, withdrawal), and liquidations.
	 *  In each case, the MON reward is issued (i.e. G is updated), before other state changes are made.
	 */
	mapping(uint128 => mapping(uint128 => uint256)) public epochToScaleToG;

	// Error tracker for the error correction in the MON issuance calculation 用于MON发行计算中的错误更正的错误跟踪器
	uint256 public lastMONError;
	// Error trackers for the error correction in the offset calculation 用于偏移计算中的误差校正的误差跟踪器
	uint256 public lastAssetError_Offset;
	uint256 public lastDCHFLossError_Offset;

	bool public isInitialized;

	// --- Contract setters ---

	/*
	 * @note 获取STABILITY_POOL_NAME_BYTES参数的值
	 */
	function getNameBytes() external pure override returns (bytes32) {
		return STABILITY_POOL_NAME_BYTES;
	}

	/*
	 * @note 获取assetAddress的值
	 */
	function getAssetType() external view override returns (address) {
		return assetAddress;
	}

	/*
	 * @note 初始化设置地址
	 * 		 1. 检查合约地址是否不为0地址以及检查调用的合约是否存在
	 * 		 2. 赋值
	 */
	function setAddresses(
		address _assetAddress,
		address _borrowerOperationsAddress,
		address _troveManagerAddress,
		address _troveManagerHelpersAddress,
		address _dchfTokenAddress,
		address _sortedTrovesAddress,
		address _communityIssuanceAddress,
		address _dfrancParamsAddress
	) external initializer onlyOwner {
		require(!isInitialized, "Already initialized");
		checkContract(_borrowerOperationsAddress);
		checkContract(_troveManagerAddress);
		checkContract(_troveManagerHelpersAddress);
		checkContract(_dchfTokenAddress);
		checkContract(_sortedTrovesAddress);
		checkContract(_communityIssuanceAddress);
		checkContract(_dfrancParamsAddress);

		isInitialized = true;

		if (_assetAddress != ETH_REF_ADDRESS) {
			checkContract(_assetAddress);
		}

		assetAddress = _assetAddress;
		borrowerOperations = IBorrowerOperations(_borrowerOperationsAddress);
		troveManager = ITroveManager(_troveManagerAddress);
		troveManagerHelpers = ITroveManagerHelpers(_troveManagerHelpersAddress);
		dchfToken = IDCHFToken(_dchfTokenAddress);
		sortedTroves = ISortedTroves(_sortedTrovesAddress);
		communityIssuance = ICommunityIssuance(_communityIssuanceAddress);
		setDfrancParameters(_dfrancParamsAddress);

		P = DECIMAL_PRECISION;

		emit BorrowerOperationsAddressChanged(_borrowerOperationsAddress);
		emit TroveManagerAddressChanged(_troveManagerAddress);
		emit DCHFTokenAddressChanged(_dchfTokenAddress);
		emit SortedTrovesAddressChanged(_sortedTrovesAddress);
		emit CommunityIssuanceAddressChanged(_communityIssuanceAddress);
	}

	// --- Getters for public variables. Required by IPool interface ---

	/*
	 * @note 获取当前池子的ETH余额
	 */
	function getAssetBalance() external view override returns (uint256) {
		return assetBalance;
	}

	/*
	 * @note 获取当前池子中存储的DCHF
	 */
	function getTotalDCHFDeposits() external view override returns (uint256) {
		return totalDCHFDeposits;
	}

	// --- External Depositor Functions ---

	/*  provideToSP():
	 *
	 * - Triggers a MON issuance, based on time passed since the last issuance. The MON issuance is shared between *all* depositors
	 * - Sends depositor's accumulated gains (MON, ETH) to depositor
	 * - Increases deposit and system stake, and takes new snapshots for each.
	 * - 根据自上次发行以来经过的时间触发MON发行.MON发行由所有存款者共享
	 * - 将存款者的累积收益(MON，ETH)发送给存款者
	 * - 增加存款和系统质押，并为每个存款者拍摄新的快照
	 */
	/*
	 * @note Stability Pool提供MON和(MON，ETH)累积收益给存款者
	 */
	function provideToSP(uint256 _amount) external override nonReentrant {
		_requireNonZeroAmount(_amount);

		uint256 initialDeposit = deposits[msg.sender];

		ICommunityIssuance communityIssuanceCached = communityIssuance;
		_triggerMONIssuance(communityIssuanceCached);

		uint256 depositorAssetGain = getDepositorAssetGain(msg.sender);
		uint256 depositorAssetGainEther = getDepositorAssetGain1e18(msg.sender);

		uint256 compoundedDCHFDeposit = getCompoundedDCHFDeposit(msg.sender);
		uint256 DCHFLoss = initialDeposit.sub(compoundedDCHFDeposit); // Needed only for event log

		// First pay out any MON gains
		// 首先支付任何MON收益
		_payOutMONGains(communityIssuanceCached, msg.sender);

		// Update System stake 更新系统质押
		uint256 compoundedStake = getCompoundedTotalStake();
		uint256 newStake = compoundedStake.add(_amount);
		// 更新stake和快照信息
		_updateStakeAndSnapshots(newStake);
		emit StakeChanged(newStake, msg.sender);

		// 从用户中发送DCHF到Stability Pool地址,同时更新其记录的DCHF
		_sendDCHFtoStabilityPool(msg.sender, _amount);

		uint256 newDeposit = compoundedDCHFDeposit.add(_amount);
		// 更新存款和快照信息
		_updateDepositAndSnapshots(msg.sender, newDeposit);

		emit UserDepositChanged(msg.sender, newDeposit);
		emit AssetGainWithdrawn(msg.sender, depositorAssetGain, DCHFLoss); // DCHF Loss required for event log

		// 发送asset收益给存款者
		_sendAssetGainToDepositor(depositorAssetGain, depositorAssetGainEther);
	}

	/*  withdrawFromSP():
	 *
	 * - Triggers a MON issuance, based on time passed since the last issuance. The MON issuance is shared between *all* depositors
	 * - Sends all depositor's accumulated gains (MON, ETH) to depositor
	 * - Decreases deposit and system stake, and takes new snapshots for each.
	 * - 根据自上次发行以来经过的时间触发MON发行.MON发行由所有存款者共享
	 * - 将所有存款人的累积收益(MON，ETH)发送给存款者
	 * - 减少存款和系统质押,并为每个存款者拍摄新的快照
	 *
	 * If _amount > userDeposit, the user withdraws all of their compounded deposit.
	 * 当提款数量大于用户的存款数量,用户会提取全部的复合存款
	 */
	/*
	 * @note 从Stability Pool中提款
	 */
	function withdrawFromSP(uint256 _amount) external override nonReentrant {
		if (_amount != 0) {
			_requireNoUnderCollateralizedTroves();
		}
		uint256 initialDeposit = deposits[msg.sender];
		_requireUserHasDeposit(initialDeposit);

		ICommunityIssuance communityIssuanceCached = communityIssuance;

		_triggerMONIssuance(communityIssuanceCached);

		uint256 depositorAssetGain = getDepositorAssetGain(msg.sender);
		uint256 depositorAssetGainEther = getDepositorAssetGain1e18(msg.sender);

		uint256 compoundedDCHFDeposit = getCompoundedDCHFDeposit(msg.sender);
		uint256 DCHFtoWithdraw = DfrancMath._min(_amount, compoundedDCHFDeposit);
		uint256 DCHFLoss = initialDeposit.sub(compoundedDCHFDeposit); // Needed only for event log

		// First pay out any MON gains
		_payOutMONGains(communityIssuanceCached, msg.sender);

		// Update System stake
		uint256 compoundedStake = getCompoundedTotalStake();
		uint256 newStake = compoundedStake.sub(DCHFtoWithdraw);
		_updateStakeAndSnapshots(newStake);
		emit StakeChanged(newStake, msg.sender);

		_sendDCHFToDepositor(msg.sender, DCHFtoWithdraw);

		// Update deposit
		uint256 newDeposit = compoundedDCHFDeposit.sub(DCHFtoWithdraw);
		_updateDepositAndSnapshots(msg.sender, newDeposit);
		emit UserDepositChanged(msg.sender, newDeposit);

		emit AssetGainWithdrawn(msg.sender, depositorAssetGain, DCHFLoss); // DCHF Loss required for event log

		_sendAssetGainToDepositor(depositorAssetGain, depositorAssetGainEther);
	}

	/* withdrawETHGainToTrove:
	 * - Triggers a MON issuance, based on time passed since the last issuance. The MON issuance is shared between *all* depositors
	 * - Sends all depositor's MON gain to depositor
	 * - Transfers the depositor's entire ETH gain from the Stability Pool to the caller's trove
	 * - Leaves their compounded deposit in the Stability Pool
	 * - Updates snapshots for deposit and system stake
	 * - 根据自上次发行以来经过的时间触发MON发行.MON发行由所有存款者共享
	 * - 将所有存款者的MON收益发送给存款者
	 * - 将存款者的全部ETH收益从Stability Pool转移到调用者的trove中
	 * - 将其复合存款留在稳定池中
	 * - 更新存款和系统质押的快照
	 */
	/*
	 * @note 提取资产收益到Trove
	 */
	function withdrawAssetGainToTrove(address _upperHint, address _lowerHint) external override {
		uint256 initialDeposit = deposits[msg.sender];
		_requireUserHasDeposit(initialDeposit);
		_requireUserHasTrove(msg.sender);
		_requireUserHasETHGain(msg.sender);

		ICommunityIssuance communityIssuanceCached = communityIssuance;

		_triggerMONIssuance(communityIssuanceCached);

		uint256 depositorAssetGain = getDepositorAssetGain1e18(msg.sender);

		uint256 compoundedDCHFDeposit = getCompoundedDCHFDeposit(msg.sender);
		uint256 DCHFLoss = initialDeposit.sub(compoundedDCHFDeposit); // Needed only for event log

		// First pay out any MON gains
		_payOutMONGains(communityIssuanceCached, msg.sender);

		// Update System stake
		uint256 compoundedSystemStake = getCompoundedTotalStake();
		_updateStakeAndSnapshots(compoundedSystemStake);
		emit StakeChanged(compoundedSystemStake, msg.sender);

		_updateDepositAndSnapshots(msg.sender, compoundedDCHFDeposit);

		/*
			Emit events before transferring ETH gain to Trove.
         	This lets the event log make more sense (i.e. so it appears that first the ETH gain is withdrawn
        	and then it is deposited into the Trove, not the other way around).
        	在将ETH收益转移到Trove之前触发事件.这让事件日志更有意义(即看起来首先提取ETH收益,然后将其存入Trove,而不是相反)
        */
		emit AssetGainWithdrawn(msg.sender, depositorAssetGain, DCHFLoss);
		emit UserDepositChanged(msg.sender, compoundedDCHFDeposit);

		assetBalance = assetBalance.sub(depositorAssetGain);
		emit StabilityPoolAssetBalanceUpdated(assetBalance);
		emit AssetSent(msg.sender, depositorAssetGain);

		borrowerOperations.moveETHGainToTrove{
			value: assetAddress == address(0) ? depositorAssetGain : 0
		}(assetAddress, depositorAssetGain, msg.sender, _upperHint, _lowerHint);
	}

	// --- MON issuance functions ---

	/*
	 * @note 触发MON发行
	 */
	function _triggerMONIssuance(ICommunityIssuance _communityIssuance) internal {
		uint256 MONIssuance = _communityIssuance.issueMON();
		_updateG(MONIssuance);
	}

	/*
	 * @note 更新MON收益"G"
	 */
	function _updateG(uint256 _MONIssuance) internal {
		uint256 totalDCHF = totalDCHFDeposits; // cached to save an SLOAD
		/*
		 * When total deposits is 0, G is not updated. In this case, the MON issued can not be obtained by later
		 * depositors - it is missed out on, and remains in the balanceof the CommunityIssuance contract.
		 * 当总存款为0时,G不会更新.在这种情况下,发行的MON无法被后来的存款人获得 - 它被错过了,并保留在社区发行合同的余额中
		 */
		if (totalDCHF == 0 || _MONIssuance == 0) {
			return;
		}

		uint256 MONPerUnitStaked;
		MONPerUnitStaked = _computeMONPerUnitStaked(_MONIssuance, totalDCHF);

		uint256 marginalMONGain = MONPerUnitStaked.mul(P);
		epochToScaleToG[currentEpoch][currentScale] = epochToScaleToG[currentEpoch][currentScale]
			.add(marginalMONGain);

		emit G_Updated(epochToScaleToG[currentEpoch][currentScale], currentEpoch, currentScale);
	}

	/*
	 * @note 计算每单位stake的MON
	 */
	function _computeMONPerUnitStaked(uint256 _MONIssuance, uint256 _totalDCHFDeposits)
		internal
		returns (uint256)
	{
		/*
		 * Calculate the MON-per-unit staked.  Division uses a "feedback" error correction, to keep the
		 * cumulative error low in the running total G:
		 * 计算每单位质押的MON.除法使用“反馈”纠错,以保持运行总量G中的累积误差较低：
		 *
		 * 1) Form a numerator which compensates for the floor division error that occurred the last time this
		 * function was called.
		 * 2) Calculate "per-unit-staked" ratio.
		 * 3) Multiply the ratio back by its denominator, to reveal the current floor division error.
		 * 4) Store this error for use in the next correction when this function is called.
		 * 5) Note: static analysis tools complain about this "division before multiplication", however, it is intended.
		 *
		 * 1) 形成一个numerator,用于补偿上次调用此函数时发生的floor(个人理解为地板价)除法误差
		 * 2) 计算“每单位stake”比率
		 * 3) 将比率乘以其分母,以显示当前的floor(个人理解为地板价)除法误差
		 * 4) 存储此错误,以便在调用此函数时用于下一次更正
		 * 5) 注意:静态分析工具抱怨这种“除法后乘法”,但是这是有意的
		 */
		uint256 MONNumerator = _MONIssuance.mul(DECIMAL_PRECISION).add(lastMONError);

		uint256 MONPerUnitStaked = MONNumerator.div(_totalDCHFDeposits);
		lastMONError = MONNumerator.sub(MONPerUnitStaked.mul(_totalDCHFDeposits));

		return MONPerUnitStaked;
	}

	// --- Liquidation functions ---

	/*
	 * Cancels out the specified debt against the DCHF contained in the Stability Pool (as far as possible)
	 * and transfers the Trove's ETH collateral from ActivePool to StabilityPool.
	 * Only called by liquidation functions in the TroveManager.
	 * (尽可能)抵消Stability Pool中包含DCHF的特定债务,并将Trove的ETH抵押品从Active Pool转移到Stability Pool.仅由TroveManager中的清算函数调用
	 */
	/*
	 * @note (尽可能)抵消Stability Pool中包含DCHF的特定债务,并将Trove的ETH抵押品从Active Pool转移到Stability Pool
	 */
	function offset(uint256 _debtToOffset, uint256 _collToAdd) external override {
		_requireCallerIsTroveManager();
		uint256 totalDCHF = totalDCHFDeposits; // cached to save an SLOAD 缓存以保存 SLOAD
		if (totalDCHF == 0 || _debtToOffset == 0) {
			return;
		}

		// 触发MON发行
		_triggerMONIssuance(communityIssuance);

		(
			uint256 AssetGainPerUnitStaked,
			uint256 DCHFLossPerUnitStaked
		) = _computeRewardsPerUnitStaked(_collToAdd, _debtToOffset, totalDCHF);

		// 更新Stability Pool奖励总和S和产品P
		_updateRewardSumAndProduct(AssetGainPerUnitStaked, DCHFLossPerUnitStaked); // updates S and P

		// 移除抵消的质押物和债务
		_moveOffsetCollAndDebt(_collToAdd, _debtToOffset);
	}

	// --- Offset helper functions ---

	/*
	 * @note 计算每单位stake的奖励
	 */
	function _computeRewardsPerUnitStaked(
		uint256 _collToAdd,
		uint256 _debtToOffset,
		uint256 _totalDCHFDeposits
	) internal returns (uint256 AssetGainPerUnitStaked, uint256 DCHFLossPerUnitStaked) {
		/*
		 * Compute the DCHF and ETH rewards. Uses a "feedback" error correction, to keep
		 * the cumulative error in the P and S state variables low:
		 * 计算DCHF和ETH奖励.使用“反馈”纠错,以保持P和S状态变量中的累积误差较低
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
		uint256 AssetNumerator = _collToAdd.mul(DECIMAL_PRECISION).add(lastAssetError_Offset);

		assert(_debtToOffset <= _totalDCHFDeposits);
		if (_debtToOffset == _totalDCHFDeposits) {
			DCHFLossPerUnitStaked = DECIMAL_PRECISION; // When the Pool depletes to 0, so does each deposit 当Pool耗尽到0时,每笔存款也会耗尽
			lastDCHFLossError_Offset = 0;
		} else {
			uint256 DCHFLossNumerator = _debtToOffset.mul(DECIMAL_PRECISION).sub(
				lastDCHFLossError_Offset
			);
			/*
			 * Add 1 to make error in quotient positive. We want "slightly too much" DCHF loss,
			 * which ensures the error in any given compoundedDCHFDeposit favors the Stability Pool.
			 * 加1使商的误差为正.我们希望DCHF损失“略大”,这确保了任何给定的复合DCHF存款中的错误都有利于Stability Pool
			 */
			DCHFLossPerUnitStaked = (DCHFLossNumerator.div(_totalDCHFDeposits)).add(1);
			lastDCHFLossError_Offset = (DCHFLossPerUnitStaked.mul(_totalDCHFDeposits)).sub(
				DCHFLossNumerator
			);
		}

		AssetGainPerUnitStaked = AssetNumerator.div(_totalDCHFDeposits);
		lastAssetError_Offset = AssetNumerator.sub(AssetGainPerUnitStaked.mul(_totalDCHFDeposits));

		return (AssetGainPerUnitStaked, DCHFLossPerUnitStaked);
	}

	// Update the Stability Pool reward sum S and product P
	/*
	 * @note 更新Stability Pool奖励总和S和产品P
	 */
	function _updateRewardSumAndProduct(
		uint256 _AssetGainPerUnitStaked,
		uint256 _DCHFLossPerUnitStaked
	) internal {
		uint256 currentP = P;
		uint256 newP;

		assert(_DCHFLossPerUnitStaked <= DECIMAL_PRECISION);
		/*
		 * The newProductFactor is the factor by which to change all deposits, due to the depletion of Stability Pool DCHF in the liquidation.
		 * We make the product factor 0 if there was a pool-emptying. Otherwise, it is (1 - DCHFLossPerUnitStaked)
		 * newProductFactor是更改所有存款的因素,由于清算中Stability Pool的DCHF的耗尽.
		 * 如果存在pool-emptying,我们将产品因子设为 0.否则,它是(1 - DCHFLossPerUnitStaked)
		 */
		uint256 newProductFactor = uint256(DECIMAL_PRECISION).sub(_DCHFLossPerUnitStaked);

		uint128 currentScaleCached = currentScale;
		uint128 currentEpochCached = currentEpoch;
		uint256 currentS = epochToScaleToSum[currentEpochCached][currentScaleCached];

		/*
		 * Calculate the new S first, before we update P.
		 * The ETH gain for any given depositor from a liquidation depends on the value of their deposit
		 * (and the value of totalDeposits) prior to the Stability being depleted by the debt in the liquidation.
		 * 在我们更新P之前,先计算新的 S.
		 * 任何给定存款人从清算中获得的ETH收益取决于在清算中的债务耗尽稳定性之前其存款的价值(以及总存款的价值)
		 *
		 * Since S corresponds to ETH gain, and P to deposit loss, we update S first.
		 * 由于S对应于ETH收益,P对应于存款损失,因此我们首先更新S
		 */
		uint256 marginalAssetGain = _AssetGainPerUnitStaked.mul(currentP);
		uint256 newS = currentS.add(marginalAssetGain);
		epochToScaleToSum[currentEpochCached][currentScaleCached] = newS;
		emit S_Updated(newS, currentEpochCached, currentScaleCached);

		// If the Stability Pool was emptied, increment the epoch, and reset the scale and product P
		// 如果Stability Pool已清空,则增加epoch,并重置scale和product P
		if (newProductFactor == 0) {
			currentEpoch = currentEpochCached.add(1);
			emit EpochUpdated(currentEpoch);
			currentScale = 0;
			emit ScaleUpdated(currentScale);
			newP = DECIMAL_PRECISION;

			// If multiplying P by a non-zero product factor would reduce P below the scale boundary, increment the scale
			// 如果将P乘以非零乘积因子会将P降低到scale边界以下,则递增scale
		} else if (currentP.mul(newProductFactor).div(DECIMAL_PRECISION) < SCALE_FACTOR) {
			newP = currentP.mul(newProductFactor).mul(SCALE_FACTOR).div(DECIMAL_PRECISION);
			currentScale = currentScaleCached.add(1);
			emit ScaleUpdated(currentScale);
		} else {
			newP = currentP.mul(newProductFactor).div(DECIMAL_PRECISION);
		}

		assert(newP > 0);
		P = newP;

		emit P_Updated(newP);
	}

	/*
	 * @note 移除抵消的质押物和债务
	 */
	function _moveOffsetCollAndDebt(uint256 _collToAdd, uint256 _debtToOffset) internal {
		IActivePool activePoolCached = dfrancParams.activePool();

		// Cancel the liquidated DCHF debt with the DCHF in the stability pool 在Stability Pool中抵消清算的DCHF债务
		activePoolCached.decreaseDCHFDebt(assetAddress, _debtToOffset);
		_decreaseDCHF(_debtToOffset);

		// Burn the debt that was successfully offset 销毁成功抵消的债务
		dchfToken.burn(address(this), _debtToOffset);

		activePoolCached.sendAsset(assetAddress, address(this), _collToAdd);
	}

	/*
	 * @note 减少DCHF存款
	 */
	function _decreaseDCHF(uint256 _amount) internal {
		uint256 newTotalDCHFDeposits = totalDCHFDeposits.sub(_amount);
		totalDCHFDeposits = newTotalDCHFDeposits;
		emit StabilityPoolDCHFBalanceUpdated(newTotalDCHFDeposits);
	}

	// --- Reward calculator functions for depositor ---

	/* Calculates the ETH gain earned by the deposit since its last snapshots were taken.
	 * Given by the formula:  E = d0 * (S - S(0))/P(0)
	 * where S(0) and P(0) are the depositor's snapshots of the sum S and product P, respectively.
	 * d0 is the last recorded deposit value.
	 * 计算自上次拍摄快照以来存款赚取的ETH收益
	 * 由公式给出: E = d0 * (S - S(0)) / P(0), 其中S(0)和P(0)分别是存款者对总和S和乘积P的快照.d0是最后记录的存款价值
	 */
	/*
	 * @note 获取存款者资产收益
	 */
	function getDepositorAssetGain(address _depositor) public view override returns (uint256) {
		uint256 initialDeposit = deposits[_depositor];

		if (initialDeposit == 0) {
			return 0;
		}

		Snapshots memory snapshots = depositSnapshots[_depositor];

		return
			SafetyTransfer.decimalsCorrection(
				assetAddress,
				_getAssetGainFromSnapshots(initialDeposit, snapshots)
			);
	}

	/*
	 * @note 获取存款者资产收益(进制为1e18)
	 */
	function getDepositorAssetGain1e18(address _depositor) public view returns (uint256) {
		uint256 initialDeposit = deposits[_depositor];

		if (initialDeposit == 0) {
			return 0;
		}

		Snapshots memory snapshots = depositSnapshots[_depositor];

		return _getAssetGainFromSnapshots(initialDeposit, snapshots);
	}

	/*
	 * @note 从快照中获取资产收益
	 */
	function _getAssetGainFromSnapshots(uint256 initialDeposit, Snapshots memory snapshots)
		internal
		view
		returns (uint256)
	{
		/*
		 * Grab the sum 'S' from the epoch at which the stake was made. The ETH gain may span up to one scale change.
		 * If it does, the second portion of the ETH gain is scaled by 1e9.
		 * If the gain spans no scale change, the second portion will be 0.
		 * 从进行质押的epoch中获取总和“S”.ETH收益最多可以跨越一个scale变化
		 * 如果是这样,ETH收益的第二部分将按1e9缩放
		 * 如果收益范围没有scale变化,则第二部分将为0
		 */
		uint128 epochSnapshot = snapshots.epoch;
		uint128 scaleSnapshot = snapshots.scale;
		uint256 S_Snapshot = snapshots.S;
		uint256 P_Snapshot = snapshots.P;

		uint256 firstPortion = epochToScaleToSum[epochSnapshot][scaleSnapshot].sub(S_Snapshot);
		uint256 secondPortion = epochToScaleToSum[epochSnapshot][scaleSnapshot.add(1)].div(
			SCALE_FACTOR
		);

		uint256 AssetGain = initialDeposit
			.mul(firstPortion.add(secondPortion))
			.div(P_Snapshot)
			.div(DECIMAL_PRECISION);

		return AssetGain;
	}

	/*
	 * Calculate the MON gain earned by a deposit since its last snapshots were taken.
	 * Given by the formula:  MON = d0 * (G - G(0))/P(0)
	 * where G(0) and P(0) are the depositor's snapshots of the sum G and product P, respectively.
	 * d0 is the last recorded deposit value.
	 * 计算自上次拍摄快照以来存款赚取的MON收益
	 * 由公式给出:MON = d0 * (G - G(0)) / P(0),其中G(0)和P(0)分别是存款人对总和G和乘积P的快照.d0是最后记录的存款价值
	 */
	/*
	 * @note 获取存款者的MON收益
	 */
	function getDepositorMONGain(address _depositor) public view override returns (uint256) {
		uint256 initialDeposit = deposits[_depositor];
		if (initialDeposit == 0) {
			return 0;
		}

		Snapshots memory snapshots = depositSnapshots[_depositor];
		return _getMONGainFromSnapshots(initialDeposit, snapshots);
	}

	/*
	 * @note 从快照中获取MON收益
	 */
	function _getMONGainFromSnapshots(uint256 initialStake, Snapshots memory snapshots)
		internal
		view
		returns (uint256)
	{
		/*
		 * Grab the sum 'G' from the epoch at which the stake was made. The MON gain may span up to one scale change.
		 * If it does, the second portion of the MON gain is scaled by 1e9.
		 * If the gain spans no scale change, the second portion will be 0.
		 * 从进行质押的epoch中获取总和“G”.MON收益最多可以跨越一个scale变化
		 * 如果是这样,则MON收益的第二部分按1e9缩放
		 * 如果收益范围没有scale变化,则第二部分将为0
		 */
		uint128 epochSnapshot = snapshots.epoch;
		uint128 scaleSnapshot = snapshots.scale;
		uint256 G_Snapshot = snapshots.G;
		uint256 P_Snapshot = snapshots.P;

		uint256 firstPortion = epochToScaleToG[epochSnapshot][scaleSnapshot].sub(G_Snapshot);
		uint256 secondPortion = epochToScaleToG[epochSnapshot][scaleSnapshot.add(1)].div(
			SCALE_FACTOR
		);

		uint256 MONGain = initialStake.mul(firstPortion.add(secondPortion)).div(P_Snapshot).div(
			DECIMAL_PRECISION
		);

		return MONGain;
	}

	// --- Compounded deposit and compounded System stake ---

	/*
	 * Return the user's compounded deposit. Given by the formula:  d = d0 * P/P(0)
	 * where P(0) is the depositor's snapshot of the product P, taken when they last updated their deposit.
	 * 退还用户的复合存款.由公式给出:d = d0 * P / P(0),其中P(0)是存款者上次更新存款时拍摄的产品P的快照
	 */
	/*
	 * @note 获取复合DCHF存款
	 */
	function getCompoundedDCHFDeposit(address _depositor)
		public
		view
		override
		returns (uint256)
	{
		uint256 initialDeposit = deposits[_depositor];
		if (initialDeposit == 0) {
			return 0;
		}

		return _getCompoundedStakeFromSnapshots(initialDeposit, depositSnapshots[_depositor]);
	}

	/*
	 * Return the system's compounded stake. Given by the formula:  D = D0 * P/P(0)
	 * where P(0) is the depositor's snapshot of the product P
	 * 返还系统的复利权益.由公式给出:D = D0 * P / P(0),其中P(0)是存款者对产品P的快照
	 *
	 * The system's compounded stake is equal to the sum of its depositors' compounded deposits.
	 * 该系统的复合stake等于其存款者的复合存款之和
	 */
	/*
	 * @note 获取复合总stake
	 */
	function getCompoundedTotalStake() public view override returns (uint256) {
		uint256 cachedStake = totalStakes;
		if (cachedStake == 0) {
			return 0;
		}

		return _getCompoundedStakeFromSnapshots(cachedStake, systemSnapshots);
	}

	// Internal function, used to calculcate compounded deposits and compounded stakes. 内部函数,用于计算复合存款和复利stake
	/*
	 * @note 从快照中获取复合stake
	 */
	function _getCompoundedStakeFromSnapshots(uint256 initialStake, Snapshots memory snapshots)
		internal
		view
		returns (uint256)
	{
		uint256 snapshot_P = snapshots.P;
		uint128 scaleSnapshot = snapshots.scale;
		uint128 epochSnapshot = snapshots.epoch;

		// If stake was made before a pool-emptying event, then it has been fully cancelled with debt -- so, return 0
		// 如果stake是在pool-emptying事件之前进行的,那么它已被债务完全抵消 - 所以,返回0
		if (epochSnapshot < currentEpoch) {
			return 0;
		}

		uint256 compoundedStake;
		uint128 scaleDiff = currentScale.sub(scaleSnapshot);

		/* Compute the compounded stake. If a scale change in P was made during the stake's lifetime,
		 * account for it. If more than one scale change was made, then the stake has decreased by a factor of
		 * at least 1e-9 -- so return 0.
		 * 计算复合stake.如果在质押的生命周期内发生了P的scale变化,请考虑它
		 * 如果进行了多次scale更改,则本金至少减少了1e-9的系数 - 因此返回0
		 */
		if (scaleDiff == 0) {
			compoundedStake = initialStake.mul(P).div(snapshot_P);
		} else if (scaleDiff == 1) {
			compoundedStake = initialStake.mul(P).div(snapshot_P).div(SCALE_FACTOR);
		} else {
			compoundedStake = 0;
		}

		/*
		 * If compounded deposit is less than a billionth of the initial deposit, return 0.
		 * 如果复合存款小于初始存款的十亿分之一,则返回0
		 *
		 * NOTE: originally, this line was in place to stop rounding errors making the deposit too large. However, the error
		 * corrections should ensure the error in P "favors the Pool", i.e. any given compounded deposit should slightly less
		 * than it's theoretical value.
		 * 注意:最初,此行是为了防止舍入误差使存款过大.但是,误差校正应确保P中的误差“有利于Pool”,即任何给定的复合存款都应略低于其理论值
		 *
		 * Thus it's unclear whether this line is still really needed.
		 * 因此,目前还不清楚这条线是否真的需要
		 */
		if (compoundedStake < initialStake.div(1e9)) {
			return 0;
		}

		return compoundedStake;
	}

	// --- Sender functions for DCHF deposit, ETH gains and MON gains ---

	// Transfer the DCHF tokens from the user to the Stability Pool's address, and update its recorded DCHF
	/*
	 * @note 从用户中发送DCHF到Stability Pool地址,同时更新其记录的DCHF
	 */
	function _sendDCHFtoStabilityPool(address _address, uint256 _amount) internal {
		dchfToken.sendToPool(_address, address(this), _amount);
		uint256 newTotalDCHFDeposits = totalDCHFDeposits.add(_amount);
		totalDCHFDeposits = newTotalDCHFDeposits;
		emit StabilityPoolDCHFBalanceUpdated(newTotalDCHFDeposits);
	}

	/*
	 * @note 发送asset收益给存款者
	 */
	function _sendAssetGainToDepositor(uint256 _amount, uint256 _amountEther) internal {
		if (_amount == 0) {
			return;
		}

		assetBalance = assetBalance.sub(_amountEther);

		if (assetAddress == ETH_REF_ADDRESS) {
			(bool success, ) = msg.sender.call{ value: _amountEther }("");
			require(success, "StabilityPool: sending ETH failed");
		} else {
			IERC20(assetAddress).safeTransfer(msg.sender, _amount);
		}

		emit StabilityPoolAssetBalanceUpdated(assetBalance);
		emit AssetSent(msg.sender, _amount);
	}

	// Send DCHF to user and decrease DCHF in Pool
	/*
	 * @note 发送DCHF给用户同时减少Pool中的DCHF
	 */
	function _sendDCHFToDepositor(address _depositor, uint256 DCHFWithdrawal) internal {
		if (DCHFWithdrawal == 0) {
			return;
		}

		dchfToken.returnFromPool(address(this), _depositor, DCHFWithdrawal);
		_decreaseDCHF(DCHFWithdrawal);
	}

	// --- Stability Pool Deposit Functionality ---

	/*
	 * @note 更新存款和快照信息
	 */
	function _updateDepositAndSnapshots(address _depositor, uint256 _newValue) internal {
		deposits[_depositor] = _newValue;

		if (_newValue == 0) {
			delete depositSnapshots[_depositor];
			emit DepositSnapshotUpdated(_depositor, 0, 0, 0);
			return;
		}
		uint128 currentScaleCached = currentScale;
		uint128 currentEpochCached = currentEpoch;
		uint256 currentP = P;

		// Get S and G for the current epoch and current scale
		uint256 currentS = epochToScaleToSum[currentEpochCached][currentScaleCached];
		uint256 currentG = epochToScaleToG[currentEpochCached][currentScaleCached];

		Snapshots storage depositSnap = depositSnapshots[_depositor];

		// Record new snapshots of the latest running product P, sum S, and sum G, for the depositor
		depositSnap.P = currentP;
		depositSnap.S = currentS;
		depositSnap.G = currentG;
		depositSnap.scale = currentScaleCached;
		depositSnap.epoch = currentEpochCached;

		emit DepositSnapshotUpdated(_depositor, currentP, currentS, currentG);
	}

	/*
	 * @note 更新stake和快照信息
	 */
	function _updateStakeAndSnapshots(uint256 _newValue) internal {
		Snapshots storage snapshots = systemSnapshots;
		totalStakes = _newValue;

		uint128 currentScaleCached = currentScale;
		uint128 currentEpochCached = currentEpoch;
		uint256 currentP = P;

		// Get G for the current epoch and current scale
		uint256 currentG = epochToScaleToG[currentEpochCached][currentScaleCached];

		// Record new snapshots of the latest running product P and sum G for the system
		snapshots.P = currentP;
		snapshots.G = currentG;
		snapshots.scale = currentScaleCached;
		snapshots.epoch = currentEpochCached;

		emit SystemSnapshotUpdated(currentP, currentG);
	}

	/*
	 * @note 支付MON收益给存款者
	 */
	function _payOutMONGains(ICommunityIssuance _communityIssuance, address _depositor)
		internal
	{
		// Pay out depositor's MON gain
		uint256 depositorMONGain = getDepositorMONGain(_depositor);
		_communityIssuance.sendMON(_depositor, depositorMONGain);
		emit MONPaidToDepositor(_depositor, depositorMONGain);
	}

	// --- 'require' functions ---

	/*
	 * @note 检查调用者是否为Active Pool地址
	 */
	function _requireCallerIsActivePool() internal view {
		require(
			msg.sender == address(dfrancParams.activePool()),
			"StabilityPool: Caller is not ActivePool"
		);
	}

	/*
	 * @note 检查调用者是否为trove管理者合约地址或trove管理者助手合约地址
	 */
	function _requireCallerIsTroveManager() internal view {
		require(
			msg.sender == address(troveManager) || msg.sender == address(troveManagerHelpers),
			"SortedTroves: Caller is not the TroveManager"
		);
	}

	/*
	 * @note 检查是否存在ICR<MCR的trove,是则禁止其提款
	 */
	function _requireNoUnderCollateralizedTroves() public {
		uint256 price = dfrancParams.priceFeed().fetchPrice(assetAddress);
		address lowestTrove = sortedTroves.getLast(assetAddress);
		uint256 ICR = troveManagerHelpers.getCurrentICR(assetAddress, lowestTrove, price);
		require(
			ICR >= dfrancParams.MCR(assetAddress),
			"StabilityPool: Cannot withdraw while there are troves with ICR < MCR"
		);
	}

	/*
	 * @note 检查用户是否有存款
	 */
	function _requireUserHasDeposit(uint256 _initialDeposit) internal pure {
		require(_initialDeposit > 0, "StabilityPool: User must have a non-zero deposit");
	}

	/*
	 * @note 检查数量是否不为0
	 */
	function _requireNonZeroAmount(uint256 _amount) internal pure {
		require(_amount > 0, "StabilityPool: Amount must be non-zero");
	}

	/*
	 * @note 检查用户是否有活跃的Trove
	 */
	function _requireUserHasTrove(address _depositor) internal view {
		require(
			troveManagerHelpers.getTroveStatus(assetAddress, _depositor) == 1,
			"StabilityPool: caller must have an active trove to withdraw AssetGain to"
		);
	}

	/*
	 * @note 检查用户是否有ETH收益
	 */
	function _requireUserHasETHGain(address _depositor) internal view {
		uint256 AssetGain = getDepositorAssetGain(_depositor);
		require(AssetGain > 0, "StabilityPool: caller must have non-zero ETH Gain");
	}

	// --- Fallback function ---

	/*
	 * @note 接收ERC20代币
	 */
	function receivedERC20(address _asset, uint256 _amount) external override {
		_requireCallerIsActivePool();

		require(_asset == assetAddress, "Receiving the wrong asset in StabilityPool");

		if (assetAddress != ETH_REF_ADDRESS) {
			assetBalance = assetBalance.add(_amount);
			emit StabilityPoolAssetBalanceUpdated(assetBalance);
		}
	}

	/*
	 * @note 接收Active Pool发送来的asset
	 */
	receive() external payable {
		_requireCallerIsActivePool();
		assetBalance = assetBalance.add(msg.value);
		emit StabilityPoolAssetBalanceUpdated(assetBalance);
	}
}
