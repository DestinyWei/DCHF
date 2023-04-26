// SPDX-License-Identifier: MIT

pragma solidity ^0.8.14;
// 检查合约地址是否不为0地址以及检查调用的合约是否存在
contract CheckContract {
	function checkContract(address _account) internal view {
		require(_account != address(0), "Account cannot be zero address");

		uint256 size;
		assembly {
			size := extcodesize(_account) // 检查要调用的合约是否确实存在（包含代码）
		}
		require(size > 0, "Account code size cannot be zero");
	}
}
