// SPDX-License-Identifier: MIT

pragma solidity ^0.8.14;
import "./Interfaces/ITroveManager.sol";
import "./Interfaces/ITroveManagerHelpers.sol";
import "./Interfaces/ISortedTroves.sol";
import "./Dependencies/DfrancBase.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/Initializable.sol";

/*
 * @notice 提示助手合约(助手合约)
 *
 * @note 包含的内容如下:
 *		function setAddresses(address _sortedTrovesAddress, address _troveManagerAddress,
							  address _troveManagerHelpersAddress, address _vaultParametersAddress) 	初始化设置地址 1. 检查合约地址是否不为0地址以及检查调用的合约是否存在 2. 赋值
 *		function getRedemptionHints(address _asset, uint256 _DCHFamount, uint256 _price,
									uint256 _maxIterations) 											获取赎回'提示'
 *		function getApproxHint(address _asset, uint256 _CR, uint256 _numTrials,
							   uint256 _inputRandomSeed) 												获取近似'提示'
 *		function computeNominalCR(uint256 _coll, uint256 _debt) 										计算NICR(个人名义抵押率)
 *		function computeCR(uint256 _coll, uint256 _debt, uint256 _price) 								计算ICR(个人抵押率)
 */
contract HintHelpers is DfrancBase, CheckContract, Initializable {
	using SafeMath for uint256;
	string public constant NAME = "HintHelpers";

	struct LocalRedemptionVars {
		address _asset;
		uint256 _DCHFamount;
		uint256 _pricel;
		uint256 _maxIterations;
	}

	ISortedTroves public sortedTroves;
	ITroveManager public troveManager;
	ITroveManagerHelpers public troveManagerHelpers;

	bool public isInitialized;

	// --- Events ---

	event SortedTrovesAddressChanged(address _sortedTrovesAddress);
	event TroveManagerAddressChanged(address _troveManagerAddress);

	// --- Dependency setters ---

	/*
	 * @note 初始化设置地址
	 * 		 1. 检查合约地址是否不为0地址以及检查调用的合约是否存在
	 * 		 2. 赋值
	 */
	function setAddresses(
		address _sortedTrovesAddress,
		address _troveManagerAddress,
		address _troveManagerHelpersAddress,
		address _vaultParametersAddress
	) external initializer onlyOwner {
		require(!isInitialized, "Already initialized");
		checkContract(_sortedTrovesAddress);
		checkContract(_troveManagerAddress);
		checkContract(_troveManagerHelpersAddress);
		checkContract(_vaultParametersAddress);
		isInitialized = true;

		sortedTroves = ISortedTroves(_sortedTrovesAddress);
		troveManager = ITroveManager(_troveManagerAddress);
		troveManagerHelpers = ITroveManagerHelpers(_troveManagerHelpersAddress);

		emit SortedTrovesAddressChanged(_sortedTrovesAddress);
		emit TroveManagerAddressChanged(_troveManagerAddress);

		setDfrancParameters(_vaultParametersAddress);
	}

	// --- Functions ---

	/* getRedemptionHints() - Helper function for finding the right hints to pass to redeemCollateral().
	 *
	 * It simulates a redemption of `_DCHFamount` to figure out where the redemption sequence will start and what state the final Trove
	 * of the sequence will end up in.
	 *
	 * Returns three hints:
	 *  - `firstRedemptionHint` is the address of the first Trove with ICR >= MCR (i.e. the first Trove that will be redeemed).
	 *  - `partialRedemptionHintNICR` is the final nominal ICR of the last Trove of the sequence after being hit by partial redemption,
	 *     or zero in case of no partial redemption.
	 *  - `truncatedDCHFamount` is the maximum amount that can be redeemed out of the the provided `_DCHFamount`. This can be lower than
	 *    `_DCHFamount` when redeeming the full amount would leave the last Trove of the redemption sequence with less net debt than the
	 *    minimum allowed value (i.e. dfrancParams.MIN_NET_DEBT()).
	 *
	 * The number of Troves to consider for redemption can be capped by passing a non-zero value as `_maxIterations`, while passing zero
	 * will leave it uncapped.
	 */

	/*
	 * @note 获取赎回'提示'
	 *		助手函数,用于查找要传递给 redeemCollateral() 的正确提示.它模拟“_DCHFamount”的赎回,以确定赎回序列将从何处开始,以及序列的最终 trove 将处于什么状态.
	 *		返回三个提示：
	 *			- “firstRedemptionHint”是第一个ICR>=MCR的trove(即第一个将被赎回的trove)的地址
	 *			- “partialRedemptionHintNICR”是序列中最后一个trove在被部分赎回hit后的NICR,如果没有部分赎回,则为零.
	 *			- “truncatedDCHFamount”是从提供的“_DCHFamount”中可以赎回的最高金额.这可能低于“_DCHFamount”,因为赎回全部金额会使赎回序列的最后一个 Trove 的净债务少于允许的最低价值(即 dfrancParams.MIN_NET_DEBT()).
	 *		要考虑赎回的 troves 数量可以通过传递非零值作为 “_maxIterations” 来限制,而传递零将使其不受限制.
	 */
	function getRedemptionHints(
		address _asset,
		uint256 _DCHFamount,
		uint256 _price,
		uint256 _maxIterations
	)
		external
		view
		returns (
			address firstRedemptionHint,
			uint256 partialRedemptionHintNICR,
			uint256 truncatedDCHFamount
		)
	{
		ISortedTroves sortedTrovesCached = sortedTroves;

		LocalRedemptionVars memory vars = LocalRedemptionVars(
			_asset,
			_DCHFamount,
			_price,
			_maxIterations
		);

		// 剩余的DCHF数量
		uint256 remainingDCHF = _DCHFamount;
		// 获取sortedTrove列表的最后一个node(即拥有最小的NICR的node)
		address currentTroveuser = sortedTrovesCached.getLast(vars._asset);

		// 从sortedTrove列表的最后一个node(即拥有最小的NICR的node)开始往前找第一个ICR>=MCR的trove
		while (
			currentTroveuser != address(0) &&
			troveManagerHelpers.getCurrentICR(vars._asset, currentTroveuser, _price) <
			dfrancParams.MCR(vars._asset)
		) {
			currentTroveuser = sortedTrovesCached.getPrev(vars._asset, currentTroveuser);
		}

		firstRedemptionHint = currentTroveuser;

		// 赎回trove的数量不受限制
		if (_maxIterations == 0) {
			_maxIterations = type(uint256).max;
		}

		while (currentTroveuser != address(0) && remainingDCHF > 0 && _maxIterations-- > 0) {
			// 计算净DCHF债务(净债务+借贷者通过其stake赚取的待处理的累积DCHF奖励)
			uint256 netDCHFDebt = _getNetDebt(
				vars._asset,
				troveManagerHelpers.getTroveDebt(vars._asset, currentTroveuser)
			).add(troveManagerHelpers.getPendingDCHFDebtReward(vars._asset, currentTroveuser));

			if (netDCHFDebt > remainingDCHF) {
				// 净债务大于最小净债务
				if (netDCHFDebt > dfrancParams.MIN_NET_DEBT(vars._asset)) {
					// 计算最高可赎回的DCHF数量(取 剩余的DCHF数量 和 净债务-最小净债务 之间最小的值)
					uint256 maxRedeemableDCHF = DfrancMath._min(
						remainingDCHF,
						netDCHFDebt.sub(dfrancParams.MIN_NET_DEBT(vars._asset))
					);

					// ETH = trove的collateral + 借贷者待处理的累积ETH奖励
					uint256 ETH = troveManagerHelpers.getTroveColl(vars._asset, currentTroveuser).add(
						troveManagerHelpers.getPendingAssetReward(vars._asset, currentTroveuser)
					);

					// 新collateral = ETH - (最高可赎回的DCHF数量 * 小数精度(1e18) / _price)
					uint256 newColl = ETH.sub(maxRedeemableDCHF.mul(DECIMAL_PRECISION).div(_price));
					// 新债务 = 净债务 - 最高可赎回的DCHF数量
					uint256 newDebt = netDCHFDebt.sub(maxRedeemableDCHF);

					// 获取复合债务(提取债务+gas赔偿),用于计算ICR(个人抵押率)
					uint256 compositeDebt = _getCompositeDebt(vars._asset, newDebt);
					// 计算NICR(个人名义抵押率)
					partialRedemptionHintNICR = DfrancMath._computeNominalCR(newColl, compositeDebt);

					remainingDCHF = remainingDCHF.sub(maxRedeemableDCHF);
				}
				break;
			} else {
				remainingDCHF = remainingDCHF.sub(netDCHFDebt);
			}

			// 获取当前trove在sortedTrove列表中的前一个trove(即有更高的NICR)
			currentTroveuser = sortedTrovesCached.getPrev(vars._asset, currentTroveuser);
		}

		// 计算可赎回的最高DCHF数量
		truncatedDCHFamount = _DCHFamount.sub(remainingDCHF);
	}

	/* getApproxHint() - return address of a Trove that is, on average, (length / numTrials) positions away in the
    sortedTroves list from the correct insert position of the Trove to be inserted.

    Note: The output address is worst-case O(n) positions away from the correct insert position, however, the function
    is probabilistic. Input can be tuned to guarantee results to a high degree of confidence, e.g:

    Submitting numTrials = k * sqrt(length), with k = 15 makes it very, very likely that the output address will
    be <= sqrt(length) positions away from the correct insert position.
    */
	/*
	 * @note 获取近似'提示'
	 *		返回 trove 的地址,即平均而言,(length / numTrials(试验数)) 在 sortedTroves 列表中的位置与要插入的 trove 的正确插入位置相距甚远.
	 *		注意: 输出地址是远离正确插入位置的最坏情况(O(n))位置,但是该函数是概率性的.可以调整输入以保证结果具有高度的置信度,
	 *			 例如：提交 numTrials = k * sqrt(length),其中k = 15使得输出地址很可能会在小于等于正确的插入位置 sqrt(length) 距离的位置.
	 */
	function getApproxHint(
		address _asset,
		uint256 _CR,
		uint256 _numTrials,
		uint256 _inputRandomSeed
	)
		external
		view
		returns (
			address hintAddress,
			uint256 diff,
			uint256 latestRandomSeed
		)
	{
		// 获取troveOwner数组的长度
		uint256 arrayLength = troveManagerHelpers.getTroveOwnersCount(_asset);

		if (arrayLength == 0) {
			return (address(0), 0, _inputRandomSeed);
		}

		// 获取sortedTrove列表的最后一个node(即拥有最小的NICR的node)
		hintAddress = sortedTroves.getLast(_asset);
		// 获取_CR和hintAddress的NICR的绝对差值
		diff = DfrancMath._getAbsoluteDifference(
			_CR,
			troveManagerHelpers.getNominalICR(_asset, hintAddress)
		);
		latestRandomSeed = _inputRandomSeed;

		uint256 i = 1;

		while (i < _numTrials) {
			// 最新的随机数种子
			latestRandomSeed = uint256(keccak256(abi.encodePacked(latestRandomSeed)));

			// 获取数组下标
			uint256 arrayIndex = latestRandomSeed % arrayLength;
			// 根据数组下标从troveOwner数组获取trove
			address currentAddress = troveManagerHelpers.getTroveFromTroveOwnersArray(
				_asset,
				arrayIndex
			);
			// 获取当前currentAddress的NICR
			uint256 currentNICR = troveManagerHelpers.getNominalICR(_asset, currentAddress);

			// check if abs(current - CR) > abs(closest - CR), and update closest if current is closer
			// 检查 (current - CR)的绝对值 是否大于 (closest - CR)的绝对值,如果current更近则更新closest的值
			uint256 currentDiff = DfrancMath._getAbsoluteDifference(currentNICR, _CR);

			if (currentDiff < diff) {
				diff = currentDiff;
				hintAddress = currentAddress;
			}
			i++;
		}
	}

	/*
	 * @note 计算NICR(个人名义抵押率)
	 */
	function computeNominalCR(uint256 _coll, uint256 _debt) external pure returns (uint256) {
		return DfrancMath._computeNominalCR(_coll, _debt);
	}

	/*
	 * @note 计算ICR(个人抵押率)
	 */
	function computeCR(
		uint256 _coll,
		uint256 _debt,
		uint256 _price
	) external pure returns (uint256) {
		return DfrancMath._computeCR(_coll, _debt, _price);
	}
}
