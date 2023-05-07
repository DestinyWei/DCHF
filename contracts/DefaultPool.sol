// SPDX-License-Identifier: MIT

pragma solidity ^0.8.14;
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./Interfaces/IDefaultPool.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/SafetyTransfer.sol";
import "./Dependencies/Initializable.sol";

/*
 * The Default Pool holds the ETH and DCHF debt (but not DCHF tokens) from liquidations that have been redistributed
 * to active troves but not yet "applied", i.e. not yet recorded on a recipient active trove's struct.
 *
 * When a trove makes an operation that applies its pending ETH and DCHF debt, its pending ETH and DCHF debt is moved
 * from the Default Pool to the Active Pool.
 */
/*
 * @notice 默认池
 *		Default Pool持有来自清算的 ETH 和 DCHF 债务(但不是 DCHF 代币),这些债务已重新分配给活跃的trove但尚未“应用”,即尚未记录在接收者活跃的trove的结构中
 *		当一个trove执行应用其待处理的 ETH 和 DCHF 债务的操作时,其待处理的 ETH 和 DCHF 债务将从Default Pool移动到Active Pool。
 *
 * @note 包含的内容如下:
 *		function setAddresses(address _troveManagerAddress,address _troveManagerHelpersAddress,
							  address _activePoolAddress) 											初始化设置地址
 *		function getAssetBalance(address _asset) returns (uint256) 									返回返回_asset中抵押的ETH余额
 *		function getDCHFDebt(address _asset) returns (uint256) 										返回_asset的DCHF债务
 *		function sendAssetToActivePool(address _asset, uint256 _amount) 							发送_amount数量的_asset到Active Pool(即说明再分配的collateral已经记录在接收者活跃的trove的结构中)
 *		function increaseDCHFDebt(address _asset, uint256 _amount) 									增加_asset对应的DCHF债务
 *		function decreaseDCHFDebt(address _asset, uint256 _amount) 									减少_asset对应的DCHF债务
 *		modifier callerIsActivePool() 																检查调用者是否为Active Pool地址
 *		modifier callerIsTroveManager() 															检查调用者是否为trove管理者合约地址或trove管理者助手合约地址
 *		function receivedERC20(address _asset, uint256 _amount) 									接收_amount数量的ERC20(_asset)
 *		receive() 																					接收发送到本合约的代币并增加ETH_REF_ADDRESS的余额
 */
contract DefaultPool is Ownable, CheckContract, Initializable, IDefaultPool {
	using SafeMath for uint256;
	using SafeERC20 for IERC20;

	string public constant NAME = "DefaultPool";

	address constant ETH_REF_ADDRESS = address(0);

	address public troveManagerAddress;
	address public troveManagerHelpersAddress;
	address public activePoolAddress;

	bool public isInitialized;

	mapping(address => uint256) internal assetsBalance;
	mapping(address => uint256) internal DCHFDebts; // debt

	// --- Dependency setters ---

	/*
	 * @note 初始化设置地址
	 * 		 1. 检查合约地址是否不为0地址以及检查调用的合约是否存在
	 * 		 2. 赋值完成后将拥有者地址删除即该合约没有拥有者
	 */
	function setAddresses(
		address _troveManagerAddress,
		address _troveManagerHelpersAddress,
		address _activePoolAddress
	  ) external
		initializer
		onlyOwner
	{
		require(!isInitialized, "Already initialized");
		checkContract(_troveManagerAddress);
		checkContract(_activePoolAddress);
		checkContract(_troveManagerHelpersAddress);
		isInitialized = true;

		troveManagerAddress = _troveManagerAddress;
		troveManagerHelpersAddress = _troveManagerHelpersAddress;
		activePoolAddress = _activePoolAddress;

		emit TroveManagerAddressChanged(_troveManagerAddress);
		emit ActivePoolAddressChanged(_activePoolAddress);

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
	 * @note 发送_amount数量的_asset到Active Pool(即说明再分配的collateral已经记录在接收者活跃的trove的结构中)
	 */
	function sendAssetToActivePool(address _asset, uint256 _amount)
		external
		override
		callerIsTroveManager
	{
		address activePool = activePoolAddress; // cache to save an SLOAD

		uint256 safetyTransferAmount = SafetyTransfer.decimalsCorrection(_asset, _amount);
		if (safetyTransferAmount == 0) return;

		assetsBalance[_asset] = assetsBalance[_asset].sub(_amount);

		// 判断是否为0地址
		if (_asset != ETH_REF_ADDRESS) {
			IERC20(_asset).safeTransfer(activePool, safetyTransferAmount);
			IDeposit(activePool).receivedERC20(_asset, _amount);
		} else {
			(bool success, ) = activePool.call{ value: _amount }("");
			require(success, "DefaultPool: sending ETH failed");
		}

		emit DefaultPoolAssetBalanceUpdated(_asset, assetsBalance[_asset]);
		emit AssetSent(activePool, _asset, safetyTransferAmount);
	}

	/*
	 * @note 增加_asset对应的DCHF债务
	 */
	function increaseDCHFDebt(address _asset, uint256 _amount)
		external
		override
		callerIsTroveManager
	{
		DCHFDebts[_asset] = DCHFDebts[_asset].add(_amount);
		emit DefaultPoolDCHFDebtUpdated(_asset, DCHFDebts[_asset]);
	}

	/*
	 * @note 减少_asset对应的DCHF债务
	 */
	function decreaseDCHFDebt(address _asset, uint256 _amount)
		external
		override
		callerIsTroveManager
	{
		DCHFDebts[_asset] = DCHFDebts[_asset].sub(_amount);
		emit DefaultPoolDCHFDebtUpdated(_asset, DCHFDebts[_asset]);
	}

	// --- 'require' functions ---

	/*
	 * @note 检查调用者是否为Active Pool地址
	 */
	modifier callerIsActivePool() {
		require(msg.sender == activePoolAddress, "DefaultPool: Caller is not the ActivePool");
		_;
	}

	/*
	 * @note 检查调用者是否为trove管理者合约地址或trove管理者助手合约地址
	 */
	modifier callerIsTroveManager() {
		require(
			msg.sender == troveManagerAddress ||
			msg.sender == troveManagerHelpersAddress,
			"DefaultPool: Caller is not the TroveManager");
		_;
	}

	/*
	 * @note 接收_amount数量的ERC20(_asset)
	 */
	function receivedERC20(address _asset, uint256 _amount)
		external
		override
		callerIsActivePool
	{
		require(_asset != ETH_REF_ADDRESS, "ETH Cannot use this functions");

		assetsBalance[_asset] = assetsBalance[_asset].add(_amount);
		emit DefaultPoolAssetBalanceUpdated(_asset, assetsBalance[_asset]);
	}

	// --- Fallback function ---

	/*
	 * @note 接收发送到本合约的代币并增加ETH_REF_ADDRESS的余额
	 */
	receive() external payable callerIsActivePool {
		assetsBalance[ETH_REF_ADDRESS] = assetsBalance[ETH_REF_ADDRESS].add(msg.value);
		emit DefaultPoolAssetBalanceUpdated(ETH_REF_ADDRESS, assetsBalance[ETH_REF_ADDRESS]);
	}
}
