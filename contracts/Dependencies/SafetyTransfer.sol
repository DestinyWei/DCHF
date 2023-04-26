import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./ERC20Decimals.sol";

/*
 * @notice 安全转账库
 *		转换ether的进制(10^18)为token的进制 DCHF token的进制为10^20,该函数的功能即为将10^18转换为10^20
 *
 * @note function decimalsCorrection(address _token, uint256 _amount) returns (uint256) 转换ether的进制(10^18)为token的进制 DCHF token的进制为10^20,该函数的功能即为将10^18转换为10^20
 */
library SafetyTransfer {
	using SafeMath for uint256;

	//_amount is in ether (1e18) and we want to convert it to the token decimal
	function decimalsCorrection(address _token, uint256 _amount)
		internal
		view
		returns (uint256)
	{
		if (_token == address(0)) return _amount;
		if (_amount == 0) return 0;

		uint8 decimals = ERC20Decimals(_token).decimals();
		if (decimals < 18) {
			return _amount.div(10**(18 - decimals));
		} else {
			return _amount.mul(10**(decimals - 18));
		}
	}
}
