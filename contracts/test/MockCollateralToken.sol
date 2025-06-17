// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockCollateralToken is ERC20 {
	constructor() ERC20("Mock Collateral Token", "MCT") {
		_mint(msg.sender, 1e30);
	}
}
