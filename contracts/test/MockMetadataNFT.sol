// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "../interfaces/IMetadataNFT.sol";

contract MockMetadataNFT is IMetadataNFT {
	function uri(TroveData memory _troveData) external view override returns (string memory) {
		return "";
	}
}
