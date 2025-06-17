// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "../interfaces/IYalaCore.sol";

/**
    @title Yala Ownable
    @notice Contracts inheriting `YalaOwnable` have the same owner as `YalaCore`.
            The ownership cannot be independently modified or renounced.
 */
contract YalaOwnable {
	IYalaCore public immutable YALA_CORE;

	constructor(address _yalaCore) {
		YALA_CORE = IYalaCore(_yalaCore);
	}

	modifier onlyOwner() {
		require(msg.sender == YALA_CORE.owner(), "Only owner");
		_;
	}

	function owner() public view returns (address) {
		return YALA_CORE.owner();
	}

	function guardian() public view returns (address) {
		return YALA_CORE.guardian();
	}
}
