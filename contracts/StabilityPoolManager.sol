pragma solidity ^0.8.14;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./Dependencies/CheckContract.sol";
import "./Dependencies/Initializable.sol";
import "./Interfaces/IStabilityPoolManager.sol";

/*
 * @notice Stability Pool管理合约(助手合约)
 * @note 包含的内容如下:
 *		modifier isController() 													判断调用者是否为合约所有者或管理员合约
 *		function setAddresses(address _adminContract) 								设置管理员合约地址
 *		function setAdminContract(address _admin) 									设置管理员地址
 *		function isStabilityPool(address stabilityPool) returns (bool) 				判断是否为Stability Pool
 *		function addStabilityPool(address asset, address stabilityPool) 			添加Stability Pool
 *		function removeStabilityPool(address asset) 								移除Stability Pool
 *		function getAssetStabilityPool(address asset) returns (IStabilityPool) 		获取asset的Stability Pool地址
 *		function unsafeGetAssetStabilityPool(address _asset) returns (address)		不安全地获取_asset的Stability Pool地址
 */
contract StabilityPoolManager is Ownable, CheckContract, Initializable, IStabilityPoolManager {
	mapping(address => address) stabilityPools;
	mapping(address => bool) validStabilityPools;

	string public constant NAME = "StabilityPoolManager";

	bool public isInitialized;
	address public adminContract;

	/*
	 * @note 判断调用者是否为合约所有者或管理员合约
	 */
	modifier isController() {
		require(msg.sender == owner() || msg.sender == adminContract, "Invalid permissions");
		_;
	}

	/*
	 * @note 设置管理员合约地址
	 */
	function setAddresses(address _adminContract) external initializer onlyOwner {
		require(!isInitialized, "Already initialized");
		checkContract(_adminContract);
		isInitialized = true;

		adminContract = _adminContract;
	}

	/*
	 * @note 设置管理员地址
	 */
	function setAdminContract(address _admin) external onlyOwner {
		require(_admin != address(0), "Admin cannot be empty address");
		checkContract(_admin);
		adminContract = _admin;
	}

	/*
	 * @note 判断是否为Stability Pool
	 */
	function isStabilityPool(address stabilityPool) external view override returns (bool) {
		return validStabilityPools[stabilityPool];
	}

	/*
	 * @note 添加Stability Pool
	 */
	function addStabilityPool(address asset, address stabilityPool)
		external
		override
		isController
	{
		CheckContract(asset);
		CheckContract(stabilityPool);
		require(!validStabilityPools[stabilityPool], "StabilityPool already created.");
		require(
			IStabilityPool(stabilityPool).getAssetType() == asset,
			"Stability Pool doesn't have the same asset type. Is it initialized?"
		);

		stabilityPools[asset] = stabilityPool;
		validStabilityPools[stabilityPool] = true;

		emit StabilityPoolAdded(asset, stabilityPool);
	}

	/*
	 * @note 移除Stability Pool
	 */
	function removeStabilityPool(address asset) external isController {
		address stabilityPool = stabilityPools[asset];
		delete validStabilityPools[stabilityPool];
		delete stabilityPools[asset];

		emit StabilityPoolRemoved(asset, stabilityPool);
	}

	/*
	 * @note 获取asset的Stability Pool地址
	 */
	function getAssetStabilityPool(address asset)
		external
		view
		override
		returns (IStabilityPool)
	{
		require(stabilityPools[asset] != address(0), "Invalid asset StabilityPool");
		return IStabilityPool(stabilityPools[asset]);
	}

	/*
	 * @note 不安全地获取_asset的Stability Pool地址
	 */
	function unsafeGetAssetStabilityPool(address _asset)
		external
		view
		override
		returns (address)
	{
		return stabilityPools[_asset];
	}
}
