// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./BaseMath.sol";
import "./DfrancMath.sol";
import "../Interfaces/IActivePool.sol";
import "../Interfaces/IDefaultPool.sol";
import "../Interfaces/IPriceFeed.sol";
import "../Interfaces/IDfrancBase.sol";

/*
 * @notice TroveManager, BorrowerOperations and StabilityPool三个合约的基础合约, 包含了全局系统常量和一些常用函数
 * Base contract for TroveManager, BorrowerOperations and StabilityPool. Contains global system constants and
 * common functions.
 * @note 包含的内容如下:
 *		function setDfrancParameters(address _vaultParams) 											设置DfrancParameters合约地址
 *		function _getCompositeDebt(address _asset, uint256 _debt) returns (uint256) 				获取复合债务(提取债务+gas赔偿),用于计算ICR(个人抵押率)
 *		function _getNetDebt(address _asset, uint256 _debt) returns (uint256) 						获取净债务(提取债务-gas赔偿)
 *		function _getCollGasCompensation(address _asset, uint256 _entireColl) returns (uint256) 	获取单个trove的collateral中被提取出来用于gas赔偿的ETH数量
 *		function getEntireSystemColl(address _asset) returns (uint256 entireSystemColl) 			获取整个系统中所有的collateral余额
 *		function getEntireSystemDebt(address _asset) returns (uint256 entireSystemDebt) 			获取整个系统中所有的DCHF debt
 *		function _getTCR(address _asset, uint256 _price) returns (uint256 TCR) 						获取系统总抵押率
 *		function _checkRecoveryMode(address _asset, uint256 _price) returns (bool) 					检查系统是否处于恢复模式
 *		function _requireUserAcceptsFee(uint256 _fee, uint256 _amount, uint256 _maxFeePercentage) 	检查fee比例是否为用户可接受的
 */
contract DfrancBase is BaseMath, IDfrancBase, Ownable {
	using SafeMath for uint256;
	address public constant ETH_REF_ADDRESS = address(0);

	IDfrancParameters public override dfrancParams;

	/*
	 * @note 设置DfrancParameters合约地址
	 */
	function setDfrancParameters(address _vaultParams) public onlyOwner {
		dfrancParams = IDfrancParameters(_vaultParams);
		emit VaultParametersBaseChanged(_vaultParams);
	}

	// --- Gas compensation functions ---

	// Returns the composite debt (drawn debt + gas compensation) of a trove, for the purpose of ICR calculation
	/*
	 * @note 获取复合债务(提取债务+gas赔偿),用于计算ICR(个人抵押率)
	 */
	function _getCompositeDebt(address _asset, uint256 _debt) internal view returns (uint256) {
		return _debt.add(dfrancParams.DCHF_GAS_COMPENSATION(_asset));
	}

	/*
	 * @note 获取净债务(提取债务-gas赔偿)
	 */
	function _getNetDebt(address _asset, uint256 _debt) internal view returns (uint256) {
		return _debt.sub(dfrancParams.DCHF_GAS_COMPENSATION(_asset));
	}

	// Return the amount of ETH to be drawn from a trove's collateral and sent as gas compensation.
	/*
	 * @note 获取单个trove的collateral中被提取出来用于gas赔偿的ETH数量
	 */
	function _getCollGasCompensation(address _asset, uint256 _entireColl)
		internal
		view
		returns (uint256)
	{
		return _entireColl / dfrancParams.PERCENT_DIVISOR(_asset);
	}

	/*
	 * @note 获取整个系统中所有的collateral余额
	 */
	function getEntireSystemColl(address _asset) public view returns (uint256 entireSystemColl) {
		uint256 activeColl = dfrancParams.activePool().getAssetBalance(_asset);
		uint256 liquidatedColl = dfrancParams.defaultPool().getAssetBalance(_asset);

		return activeColl.add(liquidatedColl);
	}

	/*
	 * @note 获取整个系统中所有的DCHF debt
	 */
	function getEntireSystemDebt(address _asset) public view returns (uint256 entireSystemDebt) {
		uint256 activeDebt = dfrancParams.activePool().getDCHFDebt(_asset);
		uint256 closedDebt = dfrancParams.defaultPool().getDCHFDebt(_asset);

		return activeDebt.add(closedDebt);
	}

	/*
	 * @note 获取系统总抵押率
	 */
	function _getTCR(address _asset, uint256 _price) internal view returns (uint256 TCR) {
		uint256 entireSystemColl = getEntireSystemColl(_asset);
		uint256 entireSystemDebt = getEntireSystemDebt(_asset);

		TCR = DfrancMath._computeCR(entireSystemColl, entireSystemDebt, _price);

		return TCR;
	}

	/*
	 * @note 检查系统是否处于恢复模式
	 */
	function _checkRecoveryMode(address _asset, uint256 _price) internal view returns (bool) {
		uint256 TCR = _getTCR(_asset, _price);

		return TCR < dfrancParams.CCR(_asset);
	}

	/*
	 * @note 检查fee比例是否为用户可接受的
	 */
	function _requireUserAcceptsFee(
		uint256 _fee,
		uint256 _amount,
		uint256 _maxFeePercentage
	) internal view {
		uint256 feePercentage = _fee.mul(dfrancParams.DECIMAL_PRECISION()).div(_amount); // _fee * 小数点精度 / _amount
		require(feePercentage <= _maxFeePercentage, "FM");
	}
}
