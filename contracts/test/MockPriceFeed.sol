// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockPriceFeed {
	mapping(IERC20 => uint256) public prices;

	function updatePrice(IERC20 token, uint256 _amount) external {
		prices[token] = _amount;
	}

	function fetchPrice(IERC20 token) public view returns (uint256) {
		return prices[token];
	}
}
