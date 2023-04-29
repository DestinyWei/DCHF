// SPDX-License-Identifier: MIT

pragma solidity ^0.8.14;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../Dependencies/BaseMath.sol";
import "../Dependencies/CheckContract.sol";
import "../Dependencies/DfrancMath.sol";
import "../Dependencies/Initializable.sol";
import "../Interfaces/IMONStaking.sol";
import "../Interfaces/IDeposit.sol";
import "../Dependencies/SafetyTransfer.sol";

/*
 * @notice MON质押合约
 *
 * @note 包含的内容如下:
 *		function setAddresses(address _monTokenAddress, address _dchfTokenAddress,
							  address _troveManagerAddress, address _troveManagerHelpersAddress,
							  address _borrowerOperationsAddress, address _activePoolAddress,
							  address _treasury) 													初始化设置地址 1. 检查合约地址是否不为0地址以及检查调用的合约是否存在 2. 赋值
 *		function stake(uint256 _MONamount) 															质押
 *		function unstake(uint256 _MONamount) 														取消质押
 *		function pause() 																			暂停
 *		function unpause() 																			取消暂停
 *		function changeTreasuryAddress(address _treasury) 											修改Treasury地址
 *		function increaseF_Asset(address _asset, uint256 _AssetFee) 								增加F_Asset(每质押个MON代币的ETH费用的运行总和)
 *		function increaseF_DCHF(uint256 _DCHFFee) 													增加F_DCHF(每质押个MON代币的DCHF费用的运行总和)
 *		function sendToTreasury(address _asset, uint256 _amount) 									发送给Treasury
 *		function getPendingAssetGain(address _asset, address _user) 								获取待处理的资产奖励
 *		function _getPendingAssetGain(address _asset, address _user) 								获取待处理的资产奖励
 *		function getPendingDCHFGain(address _user) 													获取待处理的DCHF奖励
 *		function _getPendingDCHFGain(address _user) 												获取待处理的DCHF奖励
 *		function _updateUserSnapshots(address _asset, address _user) 								更新用户快照
 *		function _sendAssetGainToUser(address _asset, uint256 _assetGain) 							发送资产奖励给用户
 *		function _sendAsset(address _sendTo, address _asset, uint256 _amount) 						发送资产或资产奖励
 *		modifier callerIsTroveManager() 															检查调用者是否为trove管理者合约地址或trove管理者助手合约地址
 *		modifier callerIsBorrowerOperations() 														检查调用者是否为借贷者操作合约地址
 *		modifier callerIsActivePool() 																检查调用者是否为Active Pool地址
 *		function _requireUserHasStake(uint256 currentStake) 										检查用户是否有质押
 *		receive() 																					接收代币
 */
contract MONStaking is
	IMONStaking,
	Pausable,
	Ownable,
	CheckContract,
	BaseMath,
	ReentrancyGuard,
	Initializable
{
	using SafeMath for uint256;
	using SafeERC20 for IERC20;

	bool public isInitialized;

	// --- Data ---
	string public constant NAME = "MONStaking";
	address constant ETH_REF_ADDRESS = address(0);

	mapping(address => uint256) public stakes;
	uint256 public totalMONStaked;

	mapping(address => uint256) public F_ASSETS; // Running sum of ETH fees per-MON-staked 每质押个MON代币的ETH费用的运行总和
	uint256 public F_DCHF; // Running sum of MON fees per-MON-staked 每质押个MON代币的ETH费用的运行总和

	// User snapshots of F_ETH and F_DCHF, taken at the point at which their latest deposit was made
	mapping(address => Snapshot) public snapshots;

	struct Snapshot {
		mapping(address => uint256) F_ASSET_Snapshot;
		uint256 F_DCHF_Snapshot;
	}

	address[] ASSET_TYPE;
	mapping(address => bool) isAssetTracked;
	mapping(address => uint256) public sentToTreasuryTracker;

	IERC20 public monToken;
	IERC20 public dchfToken;

	address public troveManagerAddress;
	address public troveManagerHelpersAddress;
	address public borrowerOperationsAddress;
	address public activePoolAddress;
	address public treasury;

	// --- Functions ---
	/*
	 * @note 初始化设置地址
	 * 		 1. 检查合约地址是否不为0地址以及检查调用的合约是否存在
	 * 		 2. 赋值
	 */
	function setAddresses(
		address _monTokenAddress,
		address _dchfTokenAddress,
		address _troveManagerAddress,
		address _troveManagerHelpersAddress,
		address _borrowerOperationsAddress,
		address _activePoolAddress,
		address _treasury
	) external override initializer {
		require(!isInitialized, "Already Initialized");
		require(_treasury != address(0), "Invalid Treausry Address");
		checkContract(_monTokenAddress);
		checkContract(_dchfTokenAddress);
		checkContract(_troveManagerAddress);
		checkContract(_troveManagerHelpersAddress);
		checkContract(_borrowerOperationsAddress);
		checkContract(_activePoolAddress);
		isInitialized = true;
		_pause();

		monToken = IERC20(_monTokenAddress);
		dchfToken = IERC20(_dchfTokenAddress);
		troveManagerAddress = _troveManagerAddress;
		troveManagerHelpersAddress = _troveManagerHelpersAddress;
		borrowerOperationsAddress = _borrowerOperationsAddress;
		activePoolAddress = _activePoolAddress;
		treasury = _treasury;

		isAssetTracked[ETH_REF_ADDRESS] = true;
		ASSET_TYPE.push(ETH_REF_ADDRESS);

		emit MONTokenAddressSet(_monTokenAddress);
		emit MONTokenAddressSet(_dchfTokenAddress);
		emit TroveManagerAddressSet(_troveManagerAddress);
		emit BorrowerOperationsAddressSet(_borrowerOperationsAddress);
		emit ActivePoolAddressSet(_activePoolAddress);
	}

	// If caller has a pre-existing stake, send any accumulated ETH and DCHF gains to them.
	/*
	 * @note 质押
	 *		 如果调用者有预先存在的stake,请将任何累积的ETH和DCHF奖励发送给他们
	 */
	function stake(uint256 _MONamount) external override nonReentrant whenNotPaused {
		require(_MONamount > 0, "MON amount is zero");

		uint256 currentStake = stakes[msg.sender];

		uint256 assetLength = ASSET_TYPE.length;
		uint256 AssetGain;
		address asset;

		for (uint256 i = 0; i < assetLength; i++) {
			asset = ASSET_TYPE[i];

			if (currentStake != 0) {
				AssetGain = _getPendingAssetGain(asset, msg.sender);

				if (i == 0) {
					uint256 DCHFGain = _getPendingDCHFGain(msg.sender);
					dchfToken.safeTransfer(msg.sender, DCHFGain);

					emit StakingGainsDCHFWithdrawn(msg.sender, DCHFGain);
				}

				_sendAssetGainToUser(asset, AssetGain);
				emit StakingGainsAssetWithdrawn(msg.sender, asset, AssetGain);
			}

			_updateUserSnapshots(asset, msg.sender);
		}

		uint256 newStake = currentStake.add(_MONamount);

		// Increase user’s stake and total MON staked
		stakes[msg.sender] = newStake;
		totalMONStaked = totalMONStaked.add(_MONamount);
		emit TotalMONStakedUpdated(totalMONStaked);

		// Transfer MON from caller to this contract
		monToken.safeTransferFrom(msg.sender, address(this), _MONamount);

		emit StakeChanged(msg.sender, newStake);
	}

	// Unstake the MON and send the it back to the caller, along with their accumulated DCHF & ETH gains.
	// If requested amount > stake, send their entire stake.
	/*
	 * @note 取消质押
	 *		 取消质押MON并将他们累积的DCHF和ETH奖励一起发回给调用者
	 *		 如果要求的数量 > 质押的数量,发送他们的全部的stake
	 */
	function unstake(uint256 _MONamount) external override nonReentrant {
		uint256 currentStake = stakes[msg.sender];
		_requireUserHasStake(currentStake);

		uint256 assetLength = ASSET_TYPE.length;
		uint256 AssetGain;
		address asset;

		for (uint256 i = 0; i < assetLength; i++) {
			asset = ASSET_TYPE[i];

			// Grab any accumulated ETH and DCHF gains from the current stake
			// 从当前质押中获取任何累积的ETH和DCHF奖励
			AssetGain = _getPendingAssetGain(asset, msg.sender);

			if (i == 0) {
				uint256 DCHFGain = _getPendingDCHFGain(msg.sender);
				dchfToken.safeTransfer(msg.sender, DCHFGain);
				emit StakingGainsDCHFWithdrawn(msg.sender, DCHFGain);
			}

			_updateUserSnapshots(asset, msg.sender);
			emit StakingGainsAssetWithdrawn(msg.sender, asset, AssetGain);

			_sendAssetGainToUser(asset, AssetGain);
		}

		if (_MONamount > 0) {
			uint256 MONToWithdraw = DfrancMath._min(_MONamount, currentStake);

			uint256 newStake = currentStake.sub(MONToWithdraw);

			// Decrease user's stake and total MON staked
			stakes[msg.sender] = newStake;
			totalMONStaked = totalMONStaked.sub(MONToWithdraw);
			emit TotalMONStakedUpdated(totalMONStaked);

			// Transfer unstaked MON to user
			monToken.safeTransfer(msg.sender, MONToWithdraw);

			emit StakeChanged(msg.sender, newStake);
		}
	}

	/*
	 * @note 暂停
	 */
	function pause() public onlyOwner {
		_pause();
	}

	/*
	 * @note 取消暂停
	 */
	function unpause() external onlyOwner {
		_unpause();
	}

	/*
	 * @note 修改Treasury地址
	 */
	function changeTreasuryAddress(address _treasury) public onlyOwner {
		require(_treasury != address(0), "Treasury address is zero");
		treasury = _treasury;
		emit TreasuryAddressChanged(_treasury);
	}

	// --- Reward-per-unit-staked increase functions. Called by Dfranc core contracts ---

	/*
	 * @note 增加F_Asset(每质押个MON代币的ETH费用的运行总和)
	 */
	function increaseF_Asset(address _asset, uint256 _AssetFee)
		external
		override
		callerIsTroveManager
	{
		if (paused()) {
			sendToTreasury(_asset, _AssetFee);
			return;
		}

		if (!isAssetTracked[_asset]) {
			isAssetTracked[_asset] = true;
			ASSET_TYPE.push(_asset);
		}

		uint256 AssetFeePerMONStaked;

		if (totalMONStaked > 0) {
			AssetFeePerMONStaked = _AssetFee.mul(DECIMAL_PRECISION).div(totalMONStaked);
		}

		F_ASSETS[_asset] = F_ASSETS[_asset].add(AssetFeePerMONStaked);
		emit F_AssetUpdated(_asset, F_ASSETS[_asset]);
	}

	/*
	 * @note 增加F_DCHF(每质押个MON代币的DCHF费用的运行总和)
	 */
	function increaseF_DCHF(uint256 _DCHFFee) external override callerIsBorrowerOperations {
		if (paused()) {
			sendToTreasury(address(dchfToken), _DCHFFee);
			return;
		}

		uint256 DCHFFeePerMONStaked;

		if (totalMONStaked > 0) {
			DCHFFeePerMONStaked = _DCHFFee.mul(DECIMAL_PRECISION).div(totalMONStaked);
		}

		F_DCHF = F_DCHF.add(DCHFFeePerMONStaked);
		emit F_DCHFUpdated(F_DCHF);
	}

	/*
	 * @note 发送给Treasury
	 */
	function sendToTreasury(address _asset, uint256 _amount) internal {
		_sendAsset(treasury, _asset, _amount);
		sentToTreasuryTracker[_asset] += _amount;

		emit SentToTreasury(_asset, _amount);
	}

	// --- Pending reward functions ---

	/*
	 * @note 获取待处理的资产奖励
	 */
	function getPendingAssetGain(address _asset, address _user)
		external
		view
		override
		returns (uint256)
	{
		return _getPendingAssetGain(_asset, _user);
	}

	/*
	 * @note 获取待处理的资产奖励
	 */
	function _getPendingAssetGain(address _asset, address _user)
		internal
		view
		returns (uint256)
	{
		uint256 F_ASSET_Snapshot = snapshots[_user].F_ASSET_Snapshot[_asset];
		uint256 AssetGain = stakes[_user].mul(F_ASSETS[_asset].sub(F_ASSET_Snapshot)).div(
			DECIMAL_PRECISION
		);
		return AssetGain;
	}

	/*
	 * @note 获取待处理的DCHF奖励
	 */
	function getPendingDCHFGain(address _user) external view override returns (uint256) {
		return _getPendingDCHFGain(_user);
	}

	/*
	 * @note 获取待处理的DCHF奖励
	 */
	function _getPendingDCHFGain(address _user) internal view returns (uint256) {
		uint256 F_DCHF_Snapshot = snapshots[_user].F_DCHF_Snapshot;
		uint256 DCHFGain = stakes[_user].mul(F_DCHF.sub(F_DCHF_Snapshot)).div(DECIMAL_PRECISION);
		return DCHFGain;
	}

	// --- Internal helper functions ---

	/*
	 * @note 更新用户快照
	 */
	function _updateUserSnapshots(address _asset, address _user) internal {
		snapshots[_user].F_ASSET_Snapshot[_asset] = F_ASSETS[_asset];
		snapshots[_user].F_DCHF_Snapshot = F_DCHF;
		emit StakerSnapshotsUpdated(_user, F_ASSETS[_asset], F_DCHF);
	}

	/*
	 * @note 发送资产奖励给用户
	 */
	function _sendAssetGainToUser(address _asset, uint256 _assetGain) internal {
		_assetGain = SafetyTransfer.decimalsCorrection(_asset, _assetGain);
		_sendAsset(msg.sender, _asset, _assetGain);
		emit AssetSent(_asset, msg.sender, _assetGain);
	}

	/*
	 * @note 发送资产或资产奖励
	 */
	function _sendAsset(
		address _sendTo,
		address _asset,
		uint256 _amount
	) internal {
		if (_asset == ETH_REF_ADDRESS) {
			(bool success, ) = _sendTo.call{ value: _amount }("");
			require(success, "MONStaking: Failed to send accumulated AssetGain");
		} else {
			IERC20(_asset).safeTransfer(_sendTo, _amount);
		}
	}

	// --- 'require' functions ---

	/*
	 * @note 检查调用者是否为trove管理者合约地址或trove管理者助手合约地址
	 */
	modifier callerIsTroveManager() {
		require(
			msg.sender == troveManagerAddress || msg.sender == troveManagerHelpersAddress,
			"MONStaking: caller is not TroveM"
		);
		_;
	}

	/*
	 * @note 检查调用者是否为借贷者操作合约地址
	 */
	modifier callerIsBorrowerOperations() {
		require(msg.sender == borrowerOperationsAddress, "MONStaking: caller is not BorrowerOps");
		_;
	}

	/*
	 * @note 检查调用者是否为Active Pool地址
	 */
	modifier callerIsActivePool() {
		require(msg.sender == activePoolAddress, "MONStaking: caller is not ActivePool");
		_;
	}

	/*
	 * @note 检查用户是否有质押
	 */
	function _requireUserHasStake(uint256 currentStake) internal pure {
		require(currentStake > 0, "MONStaking: User must have a non-zero stake");
	}

	/*
	 * @note 接收代币
	 */
	receive() external payable callerIsActivePool {}
}
