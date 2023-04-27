// SPDX-License-Identifier: MIT

pragma solidity ^0.8.14;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./Interfaces/ICollSurplusPool.sol";

import "./Dependencies/CheckContract.sol";
import "./Dependencies/SafetyTransfer.sol";
import "./Dependencies/Initializable.sol";

/*
 * @notice collateral盈余池合约(核心合约)
 *		   主要作用是管理抵押资产的剩余价值,并确保该价值在抵押贷款期间得到充分利用
 *		   具体而言,CollSurplusPool合约会跟踪每个抵押贷款的抵押物价值,并将任何超过贷款余额的价值存入CollSurplusPool中
 *		   这些资金可以用于支付贷款利息、赎回抵押物或购买DCHF稳定币等
 *
 * @note 包含的内容如下:
 *		function setAddresses(address _borrowerOperationsAddress, address _troveManagerAddress,
							  address _troveManagerHelpersAddress, address _activePoolAddress) 		初始化设置地址
 *		function getAssetBalance(address _asset) returns (uint256) 									返回ActivePool的asset状态变量,不完全等于原始的ether余额---ether可以被强制发送到合约中
 *		function getCollateral(address _asset, address _account) returns (uint256) 					获取_account的_asset余额即获取_account的collateral余额
 *		function accountSurplus(address _asset, address _account, uint256 _amount) 					增加_account中对应_amount数量的_asset
 *		function claimColl(address _asset, address _account) 										认领collateral
 *		function receivedERC20(address _asset, uint256 _amount) 									接收_amount数量的ERC20(_asset)
 *		function _requireCallerIsBorrowerOperations() 												检查调用者是否为借贷者操作合约地址
 *		function _requireCallerIsTroveManager() 													检查调用者是否为trove管理者合约地址或trove管理者助手合约地址
 *		function _requireCallerIsActivePool() 														检查调用者是否为Active Pool地址
 *		receive() 																					接收发送到本合约的代币同时给ETH_REF_ADDRESS增加余额
 */
contract CollSurplusPool is Ownable, CheckContract, Initializable, ICollSurplusPool {
	using SafeMath for uint256;
	using SafeERC20 for IERC20;

	string public constant NAME = "CollSurplusPool";
	address constant ETH_REF_ADDRESS = address(0);

	address public borrowerOperationsAddress;
	address public troveManagerAddress;
	address public troveManagerHelpersAddress;
	address public activePoolAddress;

	bool public isInitialized;

	// deposited ether tracker 存储的ether的追踪器
	mapping(address => uint256) balances;
	// Collateral surplus claimable by trove owners  trove拥有者认领的盈余的collateral
	mapping(address => mapping(address => uint256)) internal userBalances;

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
		address _activePoolAddress
	) external override initializer onlyOwner {
		require(!isInitialized, "Already initialized");
		checkContract(_borrowerOperationsAddress);
		checkContract(_troveManagerAddress);
		checkContract(_troveManagerHelpersAddress);
		checkContract(_activePoolAddress);
		isInitialized = true;

		borrowerOperationsAddress = _borrowerOperationsAddress;
		troveManagerAddress = _troveManagerAddress;
		troveManagerHelpersAddress = _troveManagerHelpersAddress;
		activePoolAddress = _activePoolAddress;

		emit BorrowerOperationsAddressChanged(_borrowerOperationsAddress);
		emit TroveManagerAddressChanged(_troveManagerAddress);
		emit ActivePoolAddressChanged(_activePoolAddress);

		renounceOwnership();
	}

	/* Returns the Asset state variable at ActivePool address.
       Not necessarily equal to the raw ether balance - ether can be forcibly sent to contracts. */
	/*
	 * @note 返回ActivePool的asset状态变量,不完全等于原始的ether余额---ether可以被强制发送到合约中
	 */
	function getAssetBalance(address _asset) external view override returns (uint256) {
		return balances[_asset];
	}

	/*
	 * @note 获取_account的_asset余额即获取_account的collateral余额
	 */
	function getCollateral(address _asset, address _account)
		external
		view
		override
		returns (uint256)
	{
		return userBalances[_account][_asset];
	}

	// --- Pool functionality ---

	/*
	 * @note 增加_account中对应_amount数量的_asset
	 */
	function accountSurplus(
		address _asset,
		address _account,
		uint256 _amount
	) external override {
		_requireCallerIsTroveManager();

		uint256 newAmount = userBalances[_account][_asset].add(_amount);
		userBalances[_account][_asset] = newAmount;

		emit CollBalanceUpdated(_account, newAmount);
	}

	/*
	 * @note 认领collateral
	 */
	function claimColl(address _asset, address _account) external override {
		_requireCallerIsBorrowerOperations();
		// 获取可认领的Ether collateral数量
		uint256 claimableCollEther = userBalances[_account][_asset];

		uint256 safetyTransferclaimableColl = SafetyTransfer.decimalsCorrection(
			_asset,
			userBalances[_account][_asset]
		);

		require(
			safetyTransferclaimableColl > 0,
			"CollSurplusPool: No collateral available to claim"
		);

		userBalances[_account][_asset] = 0;
		emit CollBalanceUpdated(_account, 0);

		balances[_asset] = balances[_asset].sub(claimableCollEther);
		emit AssetSent(_account, safetyTransferclaimableColl);

		// 判断_asset是否为0地址
		if (_asset == ETH_REF_ADDRESS) {
			(bool success, ) = _account.call{ value: claimableCollEther }("");
			require(success, "CollSurplusPool: sending ETH failed");
		} else {
			IERC20(_asset).safeTransfer(_account, safetyTransferclaimableColl);
		}
	}

	/*
	 * @note 接收_amount数量的ERC20(_asset)
	 */
	function receivedERC20(address _asset, uint256 _amount) external override {
		_requireCallerIsActivePool();
		balances[_asset] = balances[_asset].add(_amount);
	}

	// --- 'require' functions ---

	/*
	 * @note 检查调用者是否为借贷者操作合约地址
	 */
	function _requireCallerIsBorrowerOperations() internal view {
		require(
			msg.sender == borrowerOperationsAddress,
			"CollSurplusPool: Caller is not Borrower Operations"
		);
	}

	/*
	 * @note 检查调用者是否为trove管理者合约地址或trove管理者助手合约地址
	 */
	function _requireCallerIsTroveManager() internal view {
		require(
			msg.sender == troveManagerAddress ||
			msg.sender == troveManagerHelpersAddress,
			"CollSurplusPool: Caller is not TroveManager");
	}

	/*
	 * @note 检查调用者是否为Active Pool地址
	 */
	function _requireCallerIsActivePool() internal view {
		require(msg.sender == activePoolAddress, "CollSurplusPool: Caller is not Active Pool");
	}

	// --- Fallback function ---

	/*
	 * @note 接收发送到本合约的代币同时给ETH_REF_ADDRESS增加余额
	 */
	receive() external payable {
		_requireCallerIsActivePool();
		balances[ETH_REF_ADDRESS] = balances[ETH_REF_ADDRESS].add(msg.value);
	}
}
