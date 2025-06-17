// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

library YalaMath {
	uint256 internal constant DECIMAL_PRECISION = 1e18;

	function _min(uint256 _a, uint256 _b) internal pure returns (uint256) {
		return (_a < _b) ? _a : _b;
	}

	function _max(uint256 _a, uint256 _b) internal pure returns (uint256) {
		return (_a >= _b) ? _a : _b;
	}

	function _computeCR(uint256 _coll, uint256 _debt, uint256 _price) internal pure returns (uint256) {
		if (_debt > 0) {
			uint256 newCollRatio = (_coll * _price) / _debt;

			return newCollRatio;
		}
		// Return the maximal value for uint256 if the Trove has a debt of 0. Represents "infinite" CR.
		else {
			// if (_debt == 0)
			return 2 ** 256 - 1;
		}
	}

	function _computeCR(uint256 _coll, uint256 _debt) internal pure returns (uint256) {
		if (_debt > 0) {
			uint256 newCollRatio = (_coll) / _debt;

			return newCollRatio;
		}
		// Return the maximal value for uint256 if the Trove has a debt of 0. Represents "infinite" CR.
		else {
			// if (_debt == 0)
			return 2 ** 256 - 1;
		}
	}
}
