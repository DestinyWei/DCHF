// SPDX-License-Identifier: MIT

pragma solidity ^0.8.14;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../Interfaces/IStabilityPoolManager.sol";
import "../Interfaces/ICommunityIssuance.sol";
import "../Dependencies/BaseMath.sol";
import "../Dependencies/DfrancMath.sol";
import "../Dependencies/CheckContract.sol";
import "../Dependencies/Initializable.sol";

/*
 * @notice 社区发行MON代币的合约
 *
 * @note 包含的内容如下:
 *		modifier activeStabilityPoolOnly(address _pool) 									判断最后一次更新的时间是否为0即判断该合约有没有添加pool
 *		modifier isController() 															判断调用者是否为合约拥有者或管理员合约地址
 *		modifier isStabilityPool(address _pool) 											判断_pool是否为Stability Pool
 *		modifier onlyStabilityPool() 														判断调用者是否为Stability Pool
 *		function setAddresses(address _monTokenAddress,address _stabilityPoolManagerAddress,
 							  address _adminContract) 										初始化设置地址
 *		function setAdminContract(address _admin) 											设置管理员合约地址
 *		function addFundToStabilityPool(address _pool, uint256 _assignedSupply) 			将调用者的_assignedSupply数量的资金投入Stability Pool中
 *		function removeFundFromStabilityPool(address _pool, uint256 _fundToRemove) 			将资金从Stability Pool中取出
 *		function addFundToStabilityPoolFrom(address _pool,uint256 _assignedSupply,
											address _spender) 								将_spender的_assignedSupply数量的资金投入Stability Pool中
 *		function _addFundToStabilityPoolFrom(address _pool,uint256 _assignedSupply,
											address _spender) 								将_spender的_assignedSupply数量的资金投入Stability Pool中
 *		function transferFundToAnotherStabilityPool(address _target,address _receiver,
											uint256 _quantity) 								将_target(Stability Pool)的_quantity数量的资金转移到_receiver(Stability Pool)中
 *		function disableStabilityPool(address _pool) 										清空_pool(Stability Pool),可理解为重置
 *		function issueMON() returns (uint256) 												发行MON代币并返回发行的数量
 *		function _issueMON(address _pool) returns (uint256) 								发行MON代币并返回发行的数量
 *		function _getLastUpdateTokenDistribution(address stabilityPool) returns (uint256) 	从最后一次更新到现在总共发行的MON代币数量
 *		function sendMON(address _account, uint256 _MONamount) 								发送MON代币到_account,注意当 _MONamount > 合约的余额 时只会把所有余额发送出去并不会发送_MONamount数量
 *		function setWeeklyDfrancDistribution(address _stabilityPool, uint256 _weeklyReward) 设置每周MON代币的分配数量(以分钟计数)
 */
contract CommunityIssuance is
	ICommunityIssuance,
	Ownable,
	CheckContract,
	BaseMath,
	Initializable
{
	using SafeMath for uint256;
	using SafeERC20 for IERC20;

	string public constant NAME = "CommunityIssuance";
	uint256 public constant DISTRIBUTION_DURATION = 7 days / 60; // 168min = 2.8h
	uint256 public constant SECONDS_IN_ONE_MINUTE = 60;

	IERC20 public monToken;
	IStabilityPoolManager public stabilityPoolManager;

	mapping(address => uint256) public totalMONIssued;
	mapping(address => uint256) public lastUpdateTime; // lastUpdateTime is in minutes 最后一次更新的时间(以分钟计数)
	mapping(address => uint256) public MONSupplyCaps; // MON代币供应量上限,为100.000.000(1亿)
	mapping(address => uint256) public monDistributionsByPool; // monDistributionsByPool is in minutes 在Pool中的MON代币发行的数量(以分钟计数)

	address public adminContract;

	bool public isInitialized;

	/*
	 * @note 判断最后一次更新的时间是否为0即判断该合约有没有添加pool
	 */
	modifier activeStabilityPoolOnly(address _pool) {
		require(lastUpdateTime[_pool] != 0, "CommunityIssuance: Pool needs to be added first.");
		_;
	}

	/*
	 * @note 判断调用者是否为合约拥有者或管理员合约地址
	 */
	modifier isController() {
		require(msg.sender == owner() || msg.sender == adminContract, "Invalid Permission");
		_;
	}

	/*
	 * @note 判断_pool是否为Stability Pool
	 */
	modifier isStabilityPool(address _pool) {
		require(
			stabilityPoolManager.isStabilityPool(_pool),
			"CommunityIssuance: caller is not SP"
		);
		_;
	}

	/*
	 * @note 判断调用者是否为Stability Pool
	 */
	modifier onlyStabilityPool() {
		require(
			stabilityPoolManager.isStabilityPool(msg.sender),
			"CommunityIssuance: caller is not SP"
		);
		_;
	}

	// --- Functions ---

	/*
	 * @note 初始化设置地址
	 * 		 1. 检查合约地址是否不为0地址以及检查调用的合约是否存在
	 * 		 2. 赋值
	 */
	function setAddresses(
		address _monTokenAddress,
		address _stabilityPoolManagerAddress,
		address _adminContract
	) external override initializer {
		require(!isInitialized, "Already initialized");
		checkContract(_monTokenAddress);
		checkContract(_stabilityPoolManagerAddress);
		checkContract(_adminContract);
		isInitialized = true;

		adminContract = _adminContract;

		monToken = IERC20(_monTokenAddress);
		stabilityPoolManager = IStabilityPoolManager(_stabilityPoolManagerAddress);

		emit MONTokenAddressSet(_monTokenAddress);
		emit StabilityPoolAddressSet(_stabilityPoolManagerAddress);
	}

	/*
	 * @note 设置管理员合约地址
	 */
	function setAdminContract(address _admin) external onlyOwner {
		require(_admin != address(0), "Admin address is zero");
		checkContract(_admin);
		adminContract = _admin;
	}

	/*
	 * @note 将调用者的_assignedSupply数量的资金投入Stability Pool中
	 */
	function addFundToStabilityPool(address _pool, uint256 _assignedSupply)
		external
		override
		isController
	{
		_addFundToStabilityPoolFrom(_pool, _assignedSupply, msg.sender);
	}

	/*
	 * @note 将资金从Stability Pool中取出
	 */
	function removeFundFromStabilityPool(address _pool, uint256 _fundToRemove)
		external
		onlyOwner
		activeStabilityPoolOnly(_pool)
	{
		uint256 newCap = MONSupplyCaps[_pool].sub(_fundToRemove);
		require(
			totalMONIssued[_pool] <= newCap,
			"CommunityIssuance: Stability Pool doesn't have enough supply."
		);

		MONSupplyCaps[_pool] -= _fundToRemove;

		if (totalMONIssued[_pool] == MONSupplyCaps[_pool]) {
			disableStabilityPool(_pool);
		}

		monToken.safeTransfer(msg.sender, _fundToRemove);
	}

	/*
	 * @note 将_spender的_assignedSupply数量的资金投入Stability Pool中
	 */
	function addFundToStabilityPoolFrom(
		address _pool,
		uint256 _assignedSupply,
		address _spender
	) external override isController {
		_addFundToStabilityPoolFrom(_pool, _assignedSupply, _spender);
	}

	/*
	 * @note 将_spender的_assignedSupply数量的资金投入Stability Pool中
	 */
	function _addFundToStabilityPoolFrom(
		address _pool,
		uint256 _assignedSupply,
		address _spender
	) internal {
		require(
			stabilityPoolManager.isStabilityPool(_pool),
			"CommunityIssuance: Invalid Stability Pool"
		);

		if (lastUpdateTime[_pool] == 0) {
			lastUpdateTime[_pool] = (block.timestamp / SECONDS_IN_ONE_MINUTE);
		}

		MONSupplyCaps[_pool] += _assignedSupply;
		monToken.safeTransferFrom(_spender, address(this), _assignedSupply);
	}

	/*
	 * @note 将_target(Stability Pool)的_quantity数量的资金转移到_receiver(Stability Pool)中
	 */
	function transferFundToAnotherStabilityPool(
		address _target,
		address _receiver,
		uint256 _quantity
	)
		external
		override
		onlyOwner
		activeStabilityPoolOnly(_target)
		activeStabilityPoolOnly(_receiver)
	{
		uint256 newCap = MONSupplyCaps[_target].sub(_quantity);
		require(
			totalMONIssued[_target] <= newCap,
			"CommunityIssuance: Stability Pool doesn't have enough supply."
		);

		MONSupplyCaps[_target] -= _quantity;
		MONSupplyCaps[_receiver] += _quantity;

		if (totalMONIssued[_target] == MONSupplyCaps[_target]) {
			disableStabilityPool(_target);
		}
	}

	/*
	 * @note 清空_pool(Stability Pool),可理解为重置
	 */
	function disableStabilityPool(address _pool) internal {
		lastUpdateTime[_pool] = 0;
		MONSupplyCaps[_pool] = 0;
		totalMONIssued[_pool] = 0;
	}

	/*
	 * @note 发行MON代币并返回发行的数量
	 */
	function issueMON() external override onlyStabilityPool returns (uint256) {
		return _issueMON(msg.sender);
	}

	/*
	 * @note 发行MON代币并返回发行的数量
	 */
	function _issueMON(address _pool) internal isStabilityPool(_pool) returns (uint256) {
		uint256 maxPoolSupply = MONSupplyCaps[_pool];

		// 当_pool中MON代币的数量大于_pool的MON代币供应量上限(1亿)时则不再发行新的MON代币
		if (totalMONIssued[_pool] >= maxPoolSupply) return 0;

		uint256 issuance = _getLastUpdateTokenDistribution(_pool);
		uint256 totalIssuance = issuance.add(totalMONIssued[_pool]);

		if (totalIssuance > maxPoolSupply) {
			issuance = maxPoolSupply.sub(totalMONIssued[_pool]); // 重新赋值为MON代币供应量上限与当前MON代币总发行量的差值
			totalIssuance = maxPoolSupply;
		}

		lastUpdateTime[_pool] = (block.timestamp / SECONDS_IN_ONE_MINUTE);
		totalMONIssued[_pool] = totalIssuance;
		emit TotalMONIssuedUpdated(_pool, totalIssuance);

		return issuance;
	}

	/*
	 * @note 从最后一次更新到现在总共发行的MON代币数量
	 */
	function _getLastUpdateTokenDistribution(address stabilityPool)
		internal
		view
		returns (uint256)
	{
		require(lastUpdateTime[stabilityPool] != 0, "Stability pool hasn't been assigned");
		// 计算距离最后一次更新过去了多少分钟
		uint256 timePassed = block.timestamp.div(SECONDS_IN_ONE_MINUTE).sub(
			lastUpdateTime[stabilityPool]
		);
		// 每分钟发行的MON代币数量 * 距离最后一次更新过去的时间 = 从最后一次更新到现在总共发行的MON代币数量
		uint256 totalDistributedSinceBeginning = monDistributionsByPool[stabilityPool].mul(
			timePassed
		);

		return totalDistributedSinceBeginning;
	}

	/*
	 * @note 发送MON代币到_account,注意当 _MONamount > 合约的余额 时只会把所有余额发送出去并不会发送_MONamount数量
	 */
	function sendMON(address _account, uint256 _MONamount) external override onlyStabilityPool {
		uint256 balanceMON = monToken.balanceOf(address(this));
		uint256 safeAmount = balanceMON >= _MONamount ? _MONamount : balanceMON; // 判断合约余额是否大于等于_MONamount,防止超出余额数量

		if (safeAmount == 0) {
			return;
		}

		monToken.safeTransfer(_account, safeAmount);
	}

	/*
	 * @note 设置每周MON代币的发行数量(以分钟计数)
	 */
	function setWeeklyDfrancDistribution(address _stabilityPool, uint256 _weeklyReward)
		external
		isController
		isStabilityPool(_stabilityPool)
	{
		monDistributionsByPool[_stabilityPool] = _weeklyReward.div(DISTRIBUTION_DURATION);
	}
}
