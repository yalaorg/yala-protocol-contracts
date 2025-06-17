// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockDecimalCollateralToken is ERC20 {
	uint8 public DECIMALS;

	constructor(uint8 _decimals) ERC20("Mock Collateral Token", "bfBTC") {
		DECIMALS = _decimals;
		_mint(msg.sender, 1e30);
	}

	function decimals() public view override returns (uint8) {
		return DECIMALS;
	}

	function burn(uint256 amount) external {
		_burn(msg.sender, amount);
	}
}
