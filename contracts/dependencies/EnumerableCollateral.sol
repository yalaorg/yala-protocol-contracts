// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

library EnumerableCollateral {
	using EnumerableSet for EnumerableSet.AddressSet;
	error EnumerableMapNonexistentKey(address key);

	struct TroveManagerToCollateral {
		EnumerableSet.AddressSet _keys;
		mapping(address => IERC20) _values;
	}

	function set(TroveManagerToCollateral storage map, address key, IERC20 value) internal returns (bool) {
		map._values[key] = value;
		return map._keys.add(address(key));
	}

	function remove(TroveManagerToCollateral storage map, address key) internal returns (bool) {
		delete map._values[key];
		return map._keys.remove(key);
	}

	function contains(TroveManagerToCollateral storage map, address key) internal view returns (bool) {
		return map._keys.contains(key);
	}

	function length(TroveManagerToCollateral storage map) internal view returns (uint256) {
		return map._keys.length();
	}

	function at(TroveManagerToCollateral storage map, uint256 index) internal view returns (address, IERC20) {
		address key = map._keys.at(index);
		return (key, map._values[key]);
	}

	function tryGet(TroveManagerToCollateral storage map, address key) internal view returns (bool exists, IERC20 value) {
		value = map._values[key];
		exists = address(value) != address(0);
	}

	function get(TroveManagerToCollateral storage map, address key) internal view returns (IERC20) {
		if (!contains(map, key)) {
			revert EnumerableMapNonexistentKey(key);
		}
		return map._values[key];
	}

	function keys(TroveManagerToCollateral storage map) internal view returns (address[] memory) {
		return map._keys.values();
	}
}
