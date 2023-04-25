//SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";

import "./Dependencies/CheckContract.sol";
import "./Dependencies/Initializable.sol";

import "./Interfaces/IStabilityPoolManager.sol";
import "./Interfaces/IDfrancParameters.sol";
import "./Interfaces/IStabilityPool.sol";
import "./Interfaces/ICommunityIssuance.sol";

/*
 * @notice 管理员合约(管理合约)
 *
 * @note 包含的内容如下:
 *		function setAddresses(address _paramaters, address _stabilityPoolManager,
							address _borrowerOperationsAddress, address _troveManagerAddress,
							address _troveManagerHelpersAddress, address _dchfTokenAddress,
							address _sortedTrovesAddress, address _communityIssuanceAddress) 	初始化设置地址
 *		function addNewCollateral(address _stabilityPoolProxyAddress,address _chainlinkOracle,
							address _chainlinkIndex, uint256 assignedToken,
							uint256 _tokenPerWeekDistributed, uint256 redemptionLockInDay) 		添加新的抵押物,需要授权给CommunityIssuance合约来使用这个function
 */
contract AdminContract is Ownable, Initializable {
	string public constant NAME = "AdminContract";

	bytes32 public constant STABILITY_POOL_NAME_BYTES =
		0xf704b47f65a99b2219b7213612db4be4a436cdf50624f4baca1373ef0de0aac7;
	bool public isInitialized;

	IDfrancParameters private dfrancParameters;
	IStabilityPoolManager private stabilityPoolManager;
	ICommunityIssuance private communityIssuance;

	address borrowerOperationsAddress;
	address troveManagerAddress;
	address troveManagerHelpersAddress;
	address dchfTokenAddress;
	address sortedTrovesAddress;

	/*
	 * @note 初始化设置地址
	 * 		 1. 检查合约地址是否不为0地址以及检查调用的合约是否存在
	 * 		 2. 赋值
	 */
	function setAddresses(
		address _paramaters,
		address _stabilityPoolManager,
		address _borrowerOperationsAddress,
		address _troveManagerAddress,
		address _troveManagerHelpersAddress,
		address _dchfTokenAddress,
		address _sortedTrovesAddress,
		address _communityIssuanceAddress
	) external initializer onlyOwner {
		require(!isInitialized, "Already initialized");
		CheckContract(_paramaters);
		CheckContract(_stabilityPoolManager);
		CheckContract(_borrowerOperationsAddress);
		CheckContract(_troveManagerAddress);
		CheckContract(_troveManagerHelpersAddress);
		CheckContract(_dchfTokenAddress);
		CheckContract(_sortedTrovesAddress);
		CheckContract(_communityIssuanceAddress);
		isInitialized = true;

		borrowerOperationsAddress = _borrowerOperationsAddress;
		troveManagerAddress = _troveManagerAddress;
		troveManagerHelpersAddress = _troveManagerHelpersAddress;
		dchfTokenAddress = _dchfTokenAddress;
		sortedTrovesAddress = _sortedTrovesAddress;
		communityIssuance = ICommunityIssuance(_communityIssuanceAddress);

		dfrancParameters = IDfrancParameters(_paramaters);
		stabilityPoolManager = IStabilityPoolManager(_stabilityPoolManager);
	}

	//Needs to approve Community Issuance to use this fonction.
	/*
	 * @note 添加新的抵押物,需要授权给CommunityIssuance合约来使用这个function
	 */
	function addNewCollateral(
		address _stabilityPoolProxyAddress,
		address _chainlinkOracle,
		address _chainlinkIndex,
		uint256 assignedToken,
		uint256 _tokenPerWeekDistributed,
		uint256 redemptionLockInDay
	) external onlyOwner {
		address _asset = IStabilityPool(_stabilityPoolProxyAddress).getAssetType(); // 获取代币类型

		// 判断该collateral是否已添加过
		require(
			stabilityPoolManager.unsafeGetAssetStabilityPool(_asset) == address(0),
			"This collateral already exists"
		);

		dfrancParameters.priceFeed().addOracle(_asset, _chainlinkOracle, _chainlinkIndex);
		dfrancParameters.setAsDefaultWithRemptionBlock(_asset, redemptionLockInDay);

		// 创建一个对应_asset的Stability Pool
		stabilityPoolManager.addStabilityPool(_asset, _stabilityPoolProxyAddress);
		// 将assignedToken数量的资产添加到StabilityPool中
		communityIssuance.addFundToStabilityPoolFrom(
			_stabilityPoolProxyAddress,
			assignedToken,
			msg.sender
		);
		// 设置每周发行的MON代币数量
		communityIssuance.setWeeklyDfrancDistribution(
			_stabilityPoolProxyAddress,
			_tokenPerWeekDistributed
		);
	}
}
