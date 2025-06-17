// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./IDebtToken.sol";

interface IPSM {
	event PegTokenUpdated(IERC20Metadata pegToken);
	event FeeInUpdated(uint256 feeIn);
	event FeeOutUpdated(uint256 feeOut);
	event Buy(address from, uint256 amountDebtToken, uint256 amountPegToken, uint256 fee);
	event Sell(address from, uint256 amountDebtToken, uint256 amountPegToken, uint256 fee);
	event SupplyCapUpdated(uint256 newCap);
	event DebtCeilingUpdated(uint256 newCeiling);

	function factory() external view returns (address);
	function pegToken() external view returns (IERC20Metadata);
	function debtToken() external view returns (IDebtToken);
	function feeIn() external view returns (uint256);
	function feeOut() external view returns (uint256);
	function priceFactor() external view returns (uint256);
	function initialize(IERC20Metadata _pegToken, uint256 _feeIn, uint256 _feeOut, uint256 _supplyCap) external; // only called by owner
	function setFeeIn(uint256 _feeIn) external;
	function setFeeOut(uint256 _feeOut) external;

	function buy(uint256 amountPegToken) external returns (uint256 amountDebtTokenUsed, uint256 fee);
	function sell(uint256 amountDebtToken) external returns (uint256 amountPegTokenReceived, uint256 fee);
	function estimateBuy(uint256 amountDebtToken) external view returns (uint256 amountPegTokenUsed, uint256 fee);
	function estimateSell(uint256 amountDebtToken) external returns (uint256 amountPegTokenReceived, uint256 fee);
}
