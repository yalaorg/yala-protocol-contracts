// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMetadataNFT {
	struct TroveData {
		uint256 tokenId;
		address owner;
		IERC20 collToken;
		IERC20 debtToken;
		uint256 collAmount;
		uint256 debtAmount;
		uint256 interest;
	}

	function uri(TroveData memory _troveData) external view returns (string memory);
}
