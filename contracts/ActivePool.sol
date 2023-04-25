// SPDX-License-Identifier: MIT

pragma solidity ^0.8.14;
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./Interfaces/IActivePool.sol";
import "./Interfaces/IDefaultPool.sol";
import "./Interfaces/IStabilityPoolManager.sol";
import "./Interfaces/IStabilityPool.sol";
import "./Interfaces/ICollSurplusPool.sol";
import "./Interfaces/IDeposit.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/SafetyTransfer.sol";
import "./Dependencies/Initializable.sol";

/*
 * @notice Active Pool合约(核心合约)
 *		   Active Pool 包括所有活跃的 troves 的抵押物和 DCHF 债务(不是 DCHF tokens)
 *         当 trove 被清算时,其抵押物和 DCHF 债务将从 Active Pool 中转移到 Stability Pool, Default Pool, 或者是两者,这取决于清算的条件
 * @note 包含的内容如下:
 *		modifier callerIsBorrowerOperationOrDefaultPool() 										判断调用者是否为borrowerOperationsAddress(借款人操作地址)或default Pool
 *		modifier callerIsBOorTroveMorSP() 														判断调用者是否为borrowerOperationsAddress(借款人操作地址)或troveManagerAddress(trove管理者地址)或troveManagerHelpersAddress(trove管理者助手地址)或Stability Pool
 *		modifier callerIsBOorTroveM() 															判断调用者是否为borrowerOperationsAddress(借款人操作地址)或troveManagerAddress(trove管理者地址)或troveManagerHelpersAddress(trove管理者助手地址)
 *		function setAddresses(address _borrowerOperationsAddress, address _troveManagerAddress,
 							  address _troveManagerHelpersAddress, address _stabilityManagerAddress,
 							  address _defaultPoolAddress, address _collSurplusPoolAddress) 	初始化设置地址
 *		function getAssetBalance(address _asset) returns (uint256) 								返回返回_asset中抵押的ETH余额
 *		function getDCHFDebt(address _asset) returns (uint256) 									返回_asset的DCHF债务
 *		function sendAsset(address _asset, address _account, uint256 _amount) 					发送抵押物资产
 *		function isERC20DepositContract(address _account) returns (bool) 						判断_account是否为default Pool或collSurplus Pool或Stability Pool
 *		function increaseDCHFDebt(address _asset, uint256 _amount) 								增加_asset对应的DCHF债务
 *		function decreaseDCHFDebt(address _asset, uint256 _amount) 								减少_asset对应的DCHF债务
 *		function receivedERC20(address _asset, uint256 _amount) 								接收ERC20代币
 *		receive() 																				ETH_REF_ADDRESS接收发送到本合约的代币并放在Active Pool中
 *
 * The Active Pool holds the collaterals and DCHF debt (but not DCHF tokens) for all active troves.
 *
 * When a trove is liquidated, it's collateral and DCHF debt are transferred from the Active Pool, to either the
 * Stability Pool, the Default Pool, or both, depending on the liquidation conditions.
 *
 */
contract ActivePool is
	Ownable,
	ReentrancyGuard,
	CheckContract,
	Initializable,
	IActivePool
{
	using SafeERC20 for IERC20;
	using SafeMath for uint256;

	string public constant NAME = "ActivePool";
	address constant ETH_REF_ADDRESS = address(0);

	address public borrowerOperationsAddress;
	address public troveManagerAddress;
	address public troveManagerHelpersAddress;
	IDefaultPool public defaultPool;
	ICollSurplusPool public collSurplusPool;

	IStabilityPoolManager public stabilityPoolManager;

	bool public isInitialized;

	mapping(address => uint256) internal assetsBalance;
	mapping(address => uint256) internal DCHFDebts;

	// --- Contract setters ---

	/*
	 * @note 初始化设置地址
	 * 		 1. 检查合约地址是否不为0地址以及检查调用的合约是否存在
	 * 		 2. 赋值完成后将拥有者地址删除即该合约没有拥有者
	 */
	function setAddresses(
		address _borrowerOperationsAddress,
		address _troveManagerAddress,
		address _troveManagerHelpersAddress,
		address _stabilityManagerAddress,
		address _defaultPoolAddress,
		address _collSurplusPoolAddress
	) external initializer onlyOwner {
		require(!isInitialized, "Already initialized");
		checkContract(_borrowerOperationsAddress);
		checkContract(_troveManagerAddress);
		checkContract(_troveManagerHelpersAddress);
		checkContract(_stabilityManagerAddress);
		checkContract(_defaultPoolAddress);
		checkContract(_collSurplusPoolAddress);
		isInitialized = true;

		borrowerOperationsAddress = _borrowerOperationsAddress;
		troveManagerAddress = _troveManagerAddress;
		troveManagerHelpersAddress = _troveManagerHelpersAddress;
		stabilityPoolManager = IStabilityPoolManager(_stabilityManagerAddress);
		defaultPool = IDefaultPool(_defaultPoolAddress);
		collSurplusPool = ICollSurplusPool(_collSurplusPoolAddress);

		emit BorrowerOperationsAddressChanged(_borrowerOperationsAddress);
		emit TroveManagerAddressChanged(_troveManagerAddress);
		emit StabilityPoolAddressChanged(_stabilityManagerAddress);
		emit DefaultPoolAddressChanged(_defaultPoolAddress);

		renounceOwnership();
	}

	// --- Getters for public variables. Required by IPool interface ---

	/*
	 * Returns the ETH state variable.
	 *
	 * Not necessarily equal to the the contract's raw ETH balance - ether can be forcibly sent to contracts.
	 */
	/*
	 * @note 返回返回_asset中抵押的ETH余额
	 * 		 不一定完全等于合约中原始的ETH余额,以太币可以被强制发送到合约中
	 */
	function getAssetBalance(address _asset) external view override returns (uint256) {
		return assetsBalance[_asset];
	}

	/*
	 * @note 返回_asset的DCHF债务
	 */
	function getDCHFDebt(address _asset) external view override returns (uint256) {
		return DCHFDebts[_asset];
	}

	// --- Pool functionality ---

	/*
	 * @note 发送抵押物资产
	 */
	function sendAsset(
		address _asset,
		address _account,
		uint256 _amount
	) external override nonReentrant callerIsBOorTroveMorSP {
		// 判断调用者是否为Stability Pool同时判断_asset对应的Stability Pool是否为调用者地址
		if (stabilityPoolManager.isStabilityPool(msg.sender)) {
			assert(address(stabilityPoolManager.getAssetStabilityPool(_asset)) == msg.sender);
		}

		uint256 safetyTransferAmount = SafetyTransfer.decimalsCorrection(_asset, _amount);
		if (safetyTransferAmount == 0) return;

		assetsBalance[_asset] = assetsBalance[_asset].sub(_amount);

		// 判断是否为0地址
		if (_asset != ETH_REF_ADDRESS) {
			IERC20(_asset).safeTransfer(_account, safetyTransferAmount);

			if (isERC20DepositContract(_account)) {
				IDeposit(_account).receivedERC20(_asset, _amount);
			}
		} else {
			(bool success, ) = _account.call{ value: _amount }("");
			require(success, "ActivePool: sending ETH failed");
		}

		emit ActivePoolAssetBalanceUpdated(_asset, assetsBalance[_asset]);
		emit AssetSent(_account, _asset, safetyTransferAmount);
	}

	/*
	 * @note 判断_account是否为default Pool或collSurplus Pool或Stability Pool
	 */
	function isERC20DepositContract(address _account) private view returns (bool) {
		return (_account == address(defaultPool) ||
			_account == address(collSurplusPool) ||
			stabilityPoolManager.isStabilityPool(_account));
	}

	/*
	 * @note 增加_asset对应的DCHF债务
	 */
	function increaseDCHFDebt(address _asset, uint256 _amount)
		external
		override
		callerIsBOorTroveM
	{
		DCHFDebts[_asset] = DCHFDebts[_asset].add(_amount);
		emit ActivePoolDCHFDebtUpdated(_asset, DCHFDebts[_asset]);
	}

	/*
	 * @note 减少_asset对应的DCHF债务
	 */
	function decreaseDCHFDebt(address _asset, uint256 _amount)
		external
		override
		callerIsBOorTroveMorSP
	{
		DCHFDebts[_asset] = DCHFDebts[_asset].sub(_amount);
		emit ActivePoolDCHFDebtUpdated(_asset, DCHFDebts[_asset]);
	}

	// --- 'require' functions ---

	/*
	 * @note 判断调用者是否为borrowerOperationsAddress(借款人操作地址)或default Pool
	 */
	modifier callerIsBorrowerOperationOrDefaultPool() {
		require(
			msg.sender == borrowerOperationsAddress || msg.sender == address(defaultPool),
			"ActivePool: Caller is neither BO nor Default Pool"
		);

		_;
	}

	/*
	 * @note 判断调用者是否为borrowerOperationsAddress(借款人操作地址)或troveManagerAddress(trove管理者地址)
	 *		 或troveManagerHelpersAddress(trove管理者助手地址)或Stability Pool
	 */
	modifier callerIsBOorTroveMorSP() {
		require(
			msg.sender == borrowerOperationsAddress ||
				msg.sender == troveManagerAddress ||
				msg.sender == troveManagerHelpersAddress ||
				stabilityPoolManager.isStabilityPool(msg.sender),
			"ActivePool: Caller is neither BorrowerOperations nor TroveManager nor StabilityPool"
		);
		_;
	}

	/*
	 * @note 判断调用者是否为borrowerOperationsAddress(借款人操作地址)或troveManagerAddress(trove管理者地址)
	 *		 或troveManagerHelpersAddress(trove管理者助手地址)
	 */
	modifier callerIsBOorTroveM() {
		require(
			msg.sender == borrowerOperationsAddress ||
			msg.sender == troveManagerAddress ||
			msg.sender == troveManagerHelpersAddress,
			"ActivePool: Caller is neither BorrowerOperations nor TroveManager"
		);

		_;
	}

	/*
	 * @note 接收_amount数量的ERC20(_asset)
	 */
	function receivedERC20(address _asset, uint256 _amount)
		external
		override
		callerIsBorrowerOperationOrDefaultPool
	{
		assetsBalance[_asset] = assetsBalance[_asset].add(_amount);
		emit ActivePoolAssetBalanceUpdated(_asset, assetsBalance[_asset]);
	}

	// --- Fallback function ---

	/*
	 * @note 接收发送到本合约的代币并增加ETH_REF_ADDRESS的余额
	 */
	receive() external payable callerIsBorrowerOperationOrDefaultPool {
		assetsBalance[ETH_REF_ADDRESS] = assetsBalance[ETH_REF_ADDRESS].add(msg.value);
		emit ActivePoolAssetBalanceUpdated(ETH_REF_ADDRESS, assetsBalance[ETH_REF_ADDRESS]);
	}
}
