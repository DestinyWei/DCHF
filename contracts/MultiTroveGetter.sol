// SPDX-License-Identifier: MIT

pragma solidity ^0.8.14;
pragma experimental ABIEncoderV2;

import "./Interfaces/ITroveManager.sol";
import "./Interfaces/ITroveManagerHelpers.sol";
import "./SortedTroves.sol";

/*  Helper contract for grabbing Trove data for the front end. Not part of the core Dfranc system. */
/*
 * @notice 多Trove获取合约(助手合约)
 *			用于前端抓取Trove数据的助手合约,不是核心Dfranc系统的一部分
 * @note 包含的内容如下:
 *		function getMultipleSortedTroves(address _asset,
					int256 _startIdx, uint256 _count)  					获取多个sortedTrove数据
 *		function _getMultipleSortedTrovesFromHead(address _asset,
					uint256 _startIdx, uint256 _count) 					从头开始获取_count个sortedTrove数据
 *		function _getMultipleSortedTrovesFromTail(address _asset,
					uint256 _startIdx, uint256 _count)					从末尾开始获取多个sortedTrove数据
 */
contract MultiTroveGetter {
	struct CombinedTroveData {
		address owner;
		address asset;
		uint256 debt;
		uint256 coll;
		uint256 stake;
		uint256 snapshotAsset;
		uint256 snapshotDCHFDebt;
	}

	ITroveManager public troveManager; // XXX Troves missing from ITroveManager?
	ITroveManagerHelpers public troveManagerHelpers;
	ISortedTroves public sortedTroves;

	constructor(
		ITroveManager _troveManager,
		ITroveManagerHelpers _troveManagerHelpers,
		ISortedTroves _sortedTroves
	) {
		troveManager = _troveManager;
		troveManagerHelpers = _troveManagerHelpers;
		sortedTroves = _sortedTroves;
	}

	/*
	 * @note 获取多个sortedTrove数据
	 */
	function getMultipleSortedTroves(
		address _asset,
		int256 _startIdx,
		uint256 _count
	) external view returns (CombinedTroveData[] memory _troves) {
		uint256 startIdx;
		bool descend;

		if (_startIdx >= 0) {
			startIdx = uint256(_startIdx);
			descend = true;
		} else {
			startIdx = uint256(-(_startIdx + 1));
			descend = false;
		}

		uint256 sortedTrovesSize = sortedTroves.getSize(_asset);

		// 下标超出sorteTrove的大小
		if (startIdx >= sortedTrovesSize) {
			_troves = new CombinedTroveData[](0);
		} else {
			uint256 maxCount = sortedTrovesSize - startIdx;

			// 避免获取溢出
			if (_count > maxCount) {
				_count = maxCount;
			}

			// 判断读取顺序(从头到尾/从尾到头)
			if (descend) {
				_troves = _getMultipleSortedTrovesFromHead(_asset, startIdx, _count);
			} else {
				_troves = _getMultipleSortedTrovesFromTail(_asset, startIdx, _count);
			}
		}
	}

	/*
	 * @note 从头开始获取_count个sortedTrove数据
	 */
	function _getMultipleSortedTrovesFromHead(
		address _asset,
		uint256 _startIdx,
		uint256 _count
	) internal view returns (CombinedTroveData[] memory _troves) {
		// 获取sortedTrove列表中的第一个node
		address currentTroveowner = sortedTroves.getFirst(_asset);

		// 从头移动到想要从sortedTrove列表中获取的第startIdx处的node
		for (uint256 idx = 0; idx < _startIdx; ++idx) {
			currentTroveowner = sortedTroves.getNext(_asset, currentTroveowner);
		}

		_troves = new CombinedTroveData[](_count);

		for (uint256 idx = 0; idx < _count; ++idx) {
			_troves[idx].owner = currentTroveowner;
			(
				_troves[idx].asset,
				_troves[idx].debt,
				_troves[idx].coll,
				_troves[idx].stake,
				/* status */
				/* arrayIndex */
				,

			) = troveManagerHelpers.getTrove(_asset, currentTroveowner);
			(_troves[idx].snapshotAsset, _troves[idx].snapshotDCHFDebt) = troveManagerHelpers
				.getRewardSnapshots(_asset, currentTroveowner);

			currentTroveowner = sortedTroves.getNext(_asset, currentTroveowner);
		}
	}

	/*
	 * @note 从末尾开始获取多个sortedTrove数据
	 */
	function _getMultipleSortedTrovesFromTail(
		address _asset,
		uint256 _startIdx,
		uint256 _count
	) internal view returns (CombinedTroveData[] memory _troves) {
		// 获取sortedTrove列表中的最后一个node
		address currentTroveowner = sortedTroves.getLast(_asset);

		// 从末尾移动到想要从sortedTrove列表中获取的第startIdx处的node
		for (uint256 idx = 0; idx < _startIdx; ++idx) {
			currentTroveowner = sortedTroves.getPrev(_asset, currentTroveowner);
		}

		_troves = new CombinedTroveData[](_count);

		for (uint256 idx = 0; idx < _count; ++idx) {
			_troves[idx].owner = currentTroveowner;
			(
				_troves[idx].asset,
				_troves[idx].debt,
				_troves[idx].coll,
				_troves[idx].stake,
				/* status */
				/* arrayIndex */
				,

			) = troveManagerHelpers.getTrove(_asset, currentTroveowner);
			(_troves[idx].snapshotAsset, _troves[idx].snapshotDCHFDebt) = troveManagerHelpers
				.getRewardSnapshots(_asset, currentTroveowner);

			currentTroveowner = sortedTroves.getPrev(_asset, currentTroveowner);
		}
	}
}
