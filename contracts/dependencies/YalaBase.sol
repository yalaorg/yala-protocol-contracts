// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/*
 * Base contract for TroveManager, BorrowerOperations. Contains global system constants and
 * common functions.
 */
contract YalaBase {
	uint256 public constant DECIMAL_PRECISION = 1e18;

	// Amount of debt to be locked in gas pool on opening troves
	uint256 public immutable DEBT_GAS_COMPENSATION;

	constructor(uint256 _gasCompensation) {
		DEBT_GAS_COMPENSATION = _gasCompensation;
	}

	// --- Gas compensation functions ---

	// Returns the composite debt (drawn debt + gas compensation) of a trove, for the purpose of ICR calculation
	function _getCompositeDebt(uint256 _debt) internal view returns (uint256) {
		return _debt + DEBT_GAS_COMPENSATION;
	}

	function _getNetDebt(uint256 _debt) internal view returns (uint256) {
		return _debt - DEBT_GAS_COMPENSATION;
	}
}
