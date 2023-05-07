// SPDX-License-Identifier: MIT

pragma solidity ^0.8.14;

/*
 * @notice 迁移合约
 *
 * @note 包含的内容如下:
 *      modifier restricted() 						为合约拥有者时才运行代码
 *		function setCompleted(uint256 completed) 	设置完成标志(uint256)
 *		function upgrade(address new_address) 		升级合约
 */
contract Migrations {
	address public owner;
	uint256 public last_completed_migration;

	/*
	 * @note 为合约拥有者时才运行代码
	 */
	modifier restricted() {
		if (msg.sender == owner) _;
	}

	constructor() {
		owner = msg.sender;
	}

	/*
	 * @note 设置完成标志(uint256)
	 */
	function setCompleted(uint256 completed) external restricted {
		last_completed_migration = completed;
	}

	/*
	 * @note 升级合约
	 */
	function upgrade(address new_address) external restricted {
		Migrations upgraded = Migrations(new_address);
		upgraded.setCompleted(last_completed_migration);
	}
}
