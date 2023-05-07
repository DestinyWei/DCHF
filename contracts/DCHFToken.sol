// SPDX-License-Identifier: MIT

pragma solidity ^0.8.14;
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./Dependencies/CheckContract.sol";
import "./Interfaces/IDCHFToken.sol";

/*
 * DCHFToken contract valid for both V1 and V2:
 *
 * It allows to have 2 or more TroveManagers registered that can mint and burn.
 * It allows to have 2 or more BorrowerOperations registered that can mint and burn.
 *
 * Two public arrays record the TroveManager and BorrowerOps addresses registered.
 *
 * Two events are logged when modifying the array of troveManagers and borrowerOps.
 *
 * The different modifiers are updated and check if either one of the TroveManagers
 * or BorrowerOperations are making the call with mapping(address => bool).
 *
 * functions addTroveManager and addBorrowerOps register new contracts into the array.
 *
 * functions removeTroveManager and removeBorrowerOps enable the removal of a contract
 * from both the mapping and the public array.
 *
 * Additional checks in place in order to ensure that the addresses added are real
 * TroveManager or BorrowerOps contracts.
 */

interface ITroveManager {
	function isContractTroveManager() external pure returns (bool);
}

interface IBorrowerOps {
	function isContractBorrowerOps() external pure returns (bool);
}

/*
 * @notice DCHF代币合约(核心合约)
 *
 * @note 包含的内容如下:
 *		function emergencyStopMinting(address _asset, bool status) 							紧急停止铸造代币
 *		function mint(address _asset, address _account, uint256 _amount) 					铸造代币
 *		function burn(address _account, uint256 _amount) 									销毁代币
 *		function sendToPool(address _sender, address _poolAddress, uint256 _amount) 		_sender将_amount数量的代币发送到pool中
 *		function returnFromPool(address _poolAddress, address _receiver, uint256 _amount) 	pool将_amount数量的代币发送给_receiver
 *		function transfer(address recipient, uint256 amount) returns (bool) 				转账amount数量的代币给recipient
 *		function transferFrom(address sender, address recipient, uint256 amount) 			sender转账amount数量的代币给recipient
 *		function addTroveManager(address _troveManager) 									添加trove管理合约
 *		function removeTroveManager(address _troveManager) 									移除trove管理合约
 *		function addBorrowerOps(address _borrowerOps) 										添加借贷者操作合约
 *		function removeBorrowerOps(address _borrowerOps) 									移除借贷者操作合约
 *		function _removeElement(address[] storage _array, address _contract) 				将_contract从_array中删除
 *		function _requireValidRecipient(address _recipient) 								判断_recipient为合法地址
 *		function _requireCallerIsBorrowerOperations() 										判断调用者是否为合法的借贷者操作合约
 *		function _requireCallerIsBOorTroveMorSP() 											判断调用者是否为合法的借贷者操作合约或合法的trove管理合约或Stability Pool
 *		function _requireCallerIsStabilityPool() 											判断调用者是否为Stability Pool
 *		function _requireCallerIsTroveMorSP() 												判断调用者是否为合法的trove管理合约或Stability Pool
 */
contract DCHFToken is CheckContract, IDCHFToken, Ownable {
	using SafeMath for uint256;

	address[] public troveManagers;
	address[] public borrowerOps;

	IStabilityPoolManager public immutable stabilityPoolManager;

	mapping(address => bool) public emergencyStopMintingCollateral;

	mapping(address => bool) public validTroveManagers;
	mapping(address => bool) public validBorrowerOps;

	event EmergencyStopMintingCollateral(address _asset, bool state);
	event UpdateTroveManagers(address[] troveManagers);
	event UpdateBorrowerOps(address[] borrowerOps);

	constructor(address _stabilityPoolManagerAddress) ERC20("Defi Franc", "DCHF") {
		checkContract(_stabilityPoolManagerAddress);

		stabilityPoolManager = IStabilityPoolManager(_stabilityPoolManagerAddress);
		emit StabilityPoolAddressChanged(_stabilityPoolManagerAddress);
	}

	// --- Functions for intra-Dfranc calls ---

	/*
	 * @note 紧急停止铸造代币
	 */
	function emergencyStopMinting(address _asset, bool status) external override onlyOwner {
		emergencyStopMintingCollateral[_asset] = status;
		emit EmergencyStopMintingCollateral(_asset, status);
	}

	/*
	 * @note 铸造代币
	 */
	function mint(
		address _asset,
		address _account,
		uint256 _amount
	) external override {
		_requireCallerIsBorrowerOperations();
		require(!emergencyStopMintingCollateral[_asset], "Mint is blocked on this collateral");
		_mint(_account, _amount);
	}

	/*
	 * @note 销毁代币
	 */
	function burn(address _account, uint256 _amount) external override {
		_requireCallerIsBOorTroveMorSP();
		_burn(_account, _amount);
	}

	/*
	 * @note _sender将_amount数量的代币发送到pool中
	 */
	function sendToPool(
		address _sender,
		address _poolAddress,
		uint256 _amount
	) external override {
		_requireCallerIsStabilityPool();
		_transfer(_sender, _poolAddress, _amount);
	}

	/*
	 * @note pool将_amount数量的代币发送给_receiver
	 */
	function returnFromPool(
		address _poolAddress,
		address _receiver,
		uint256 _amount
	) external override {
		_requireCallerIsTroveMorSP();
		_transfer(_poolAddress, _receiver, _amount);
	}

	// --- External functions ---

	/*
	 * @note 转账amount数量的代币给recipient
	 */
	function transfer(address recipient, uint256 amount) public override returns (bool) {
		_requireValidRecipient(recipient);
		return super.transfer(recipient, amount);
	}

	/*
	 * @note sender转账amount数量的代币给recipient
	 */
	function transferFrom(
		address sender,
		address recipient,
		uint256 amount
	) public override returns (bool) {
		_requireValidRecipient(recipient);
		return super.transferFrom(sender, recipient, amount);
	}

	/*
	 * @note 添加trove管理合约
	 */
	function addTroveManager(address _troveManager) external override onlyOwner {
		CheckContract(_troveManager);
		assert(ITroveManager(_troveManager).isContractTroveManager());
		require(!validTroveManagers[_troveManager], "TroveManager already exists");
		validTroveManagers[_troveManager] = true;
		troveManagers.push(_troveManager);
		emit UpdateTroveManagers(troveManagers);
	}

	/*
	 * @note 移除trove管理合约
	 */
	function removeTroveManager(address _troveManager) external override onlyOwner {
		require(validTroveManagers[_troveManager], "TroveManager does not exist");
		delete validTroveManagers[_troveManager];
		_removeElement(troveManagers, _troveManager);
		emit UpdateTroveManagers(troveManagers);
	}

	/*
	 * @note 添加借贷者操作合约
	 */
	function addBorrowerOps(address _borrowerOps) external override onlyOwner {
		CheckContract(_borrowerOps);
		assert(IBorrowerOps(_borrowerOps).isContractBorrowerOps());
		require(!validBorrowerOps[_borrowerOps], "BorrowerOps already exists");
		validBorrowerOps[_borrowerOps] = true;
		borrowerOps.push(_borrowerOps);
		emit UpdateBorrowerOps(borrowerOps);
	}

	/*
	 * @note 移除借贷者操作合约
	 */
	function removeBorrowerOps(address _borrowerOps) external override onlyOwner {
		require(validBorrowerOps[_borrowerOps], "BorrowerOps does not exist");
		delete validBorrowerOps[_borrowerOps];
		_removeElement(borrowerOps, _borrowerOps);
		emit UpdateBorrowerOps(borrowerOps);
	}

	// --- Internal functions ---

	/*
	 * @note 将_contract从_array中删除
	 */
	function _removeElement(address[] storage _array, address _contract) internal {
		for (uint256 i; i < _array.length; i++) {
			if (_array[i] == _contract) {
				_array[i] = _array[_array.length - 1];
				_array.pop();
				break;
			}
		}
	}

	// --- 'require' functions ---

	/*
	 * @note 判断_recipient为合法地址
	 *		1. 不为0地址或本合约地址
	 *		2. 不为Stability Pool,合法的trove管理合约,合法的借贷者操作地址
	 */
	function _requireValidRecipient(address _recipient) internal view {
		require(
			_recipient != address(0) && _recipient != address(this),
			"DCHF: Cannot transfer tokens directly to the DCHF token contract or the zero address"
		);
		require(
			!stabilityPoolManager.isStabilityPool(_recipient) &&
				!validTroveManagers[_recipient] &&
				!validBorrowerOps[_recipient],
			"DCHF: Cannot transfer tokens directly to the StabilityPool, TroveManager or BorrowerOps"
		);
	}

	/*
	 * @note 判断调用者是否为合法的借贷者操作合约
	 */
	function _requireCallerIsBorrowerOperations() internal view {
		require(validBorrowerOps[msg.sender], "DCHFToken: Caller is not BorrowerOperations");
	}

	/*
	 * @note 判断调用者是否为合法的借贷者操作合约或合法的trove管理合约或Stability Pool
	 */
	function _requireCallerIsBOorTroveMorSP() internal view {
		require(
			validBorrowerOps[msg.sender] ||
				validTroveManagers[msg.sender] ||
				stabilityPoolManager.isStabilityPool(msg.sender),
			"DCHF: Caller is neither BorrowerOperations nor TroveManager nor StabilityPool"
		);
	}

	/*
	 * @note 判断调用者是否为Stability Pool
	 */
	function _requireCallerIsStabilityPool() internal view {
		require(
			stabilityPoolManager.isStabilityPool(msg.sender),
			"DCHF: Caller is not the StabilityPool"
		);
	}

	/*
	 * @note 判断调用者是否为合法的trove管理合约或Stability Pool
	 */
	function _requireCallerIsTroveMorSP() internal view {
		require(
			validTroveManagers[msg.sender] || stabilityPoolManager.isStabilityPool(msg.sender),
			"DCHF: Caller is neither TroveManager nor StabilityPool"
		);
	}
}
