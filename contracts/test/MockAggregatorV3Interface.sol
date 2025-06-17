// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IAggregatorV3Interface.sol";

contract MockAggregatorV3Interface is IAggregatorV3Interface, Ownable {
	struct RoundData {
		uint80 roundId;
		int256 answer;
		uint256 startedAt;
		uint256 updatedAt;
		uint80 answeredInRound;
	}

	uint8 public DECIMALS = 8;
	RoundData internal latestData;
	mapping(uint80 => RoundData) public datas;

	constructor(address newOwner) {
		_transferOwnership(newOwner);
	}

	function updateDecimals(uint8 _decimals) external onlyOwner {
		DECIMALS = _decimals;
	}

	function updateRoundData(RoundData memory roundData) external onlyOwner {
		latestData = roundData;
		datas[roundData.roundId] = roundData;
	}

	function decimals() external view returns (uint8) {
		return DECIMALS;
	}

	function description() external pure returns (string memory) {
		return "Mock AggregatorV3Interface";
	}

	function version() external pure returns (uint256) {
		return 1;
	}

	function getRoundData(uint80 _roundId) external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) {
		return (datas[_roundId].roundId, datas[_roundId].answer, datas[_roundId].startedAt, datas[_roundId].updatedAt, datas[_roundId].answeredInRound);
	}

	function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) {
		return (latestData.roundId, latestData.answer, latestData.startedAt, latestData.updatedAt, latestData.answeredInRound);
	}
}
