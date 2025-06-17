// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "../interfaces/IAggregatorV3Interface.sol";
import "../dependencies/YalaMath.sol";
import "../dependencies/YalaOwnable.sol";

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
/**
    @title Yala Multi Token Price Feed
    @notice Based on Gravita's PriceFeed:
            https://github.com/Gravita-Protocol/Gravita-SmartContracts/blob/9b69d555f3567622b0f84df8c7f1bb5cd9323573/contracts/PriceFeed.sol

            Yala's implementation additionally caches price values within a block
 */
contract PriceFeed is YalaOwnable {
	struct OracleRecord {
		IAggregatorV3Interface chainLinkOracle;
		uint8 decimals;
		uint32 heartbeat;
		bool isFeedWorking;
	}

	struct PriceRecord {
		uint256 scaledPrice;
		uint64 timestamp;
		uint64 lastUpdated;
		uint128 roundId;
	}

	struct FeedResponse {
		uint80 roundId;
		int256 answer;
		uint256 timestamp;
		bool success;
	}

	struct OracleSetup {
		address token;
		address chainlink;
		uint32 heartbeat;
	}

	uint256 public constant RESPONSE_TIMEOUT_BUFFER = 1 hours;
	uint256 public constant MAX_PRICE_DEVIATION_FROM_PREVIOUS_ROUND = 5e17; // 50%
	uint8 public constant MAX_DIGITS = 36;

	mapping(address => uint8) public TARGET_DIGITS;
	mapping(address => OracleRecord) public oracleRecords;
	mapping(address => PriceRecord) public priceRecords;

	error PriceFeed__UnsupportedTokenDecimalsError(address token, uint8 decimals);
	error PriceFeed__InvalidFeedResponseError(address token);
	error PriceFeed__FeedFrozenError(address token);
	error PriceFeed__UnknownFeedError(address token);
	error PriceFeed__HeartbeatOutOfBoundsError();

	event NewOracleRegistered(address token, address chainlinkAggregator);
	event PriceFeedStatusUpdated(address token, address oracle, bool isWorking);
	event PriceRecordUpdated(address indexed token, uint256 _price);

	constructor(address _yalaCore, OracleSetup[] memory oracles) YalaOwnable(_yalaCore) {
		for (uint8 i = 0; i < oracles.length; i++) {
			OracleSetup memory o = oracles[i];
			_setOracle(o.token, o.chainlink, o.heartbeat);
		}
	}

	function setOracle(address _token, address _chainlinkOracle, uint32 _heartbeat) external onlyOwner {
		_setOracle(_token, _chainlinkOracle, _heartbeat);
	}

	function _setOracle(address _token, address _chainlinkOracle, uint32 _heartbeat) internal {
		uint8 decimals = IERC20Metadata(_token).decimals();
		if (decimals > 18) {
			revert PriceFeed__UnsupportedTokenDecimalsError(_token, decimals);
		}
		TARGET_DIGITS[_token] = MAX_DIGITS - decimals;

		if (_heartbeat > 86400) revert PriceFeed__HeartbeatOutOfBoundsError();

		IAggregatorV3Interface newFeed = IAggregatorV3Interface(_chainlinkOracle);
		FeedResponse memory currResponse = _fetchFeedResponses(newFeed);
		if (!_isFeedWorking(currResponse)) {
			revert PriceFeed__InvalidFeedResponseError(_token);
		}

		if (_isPriceStale(currResponse.timestamp, _heartbeat)) {
			revert PriceFeed__FeedFrozenError(_token);
		}

		OracleRecord memory record = OracleRecord({ chainLinkOracle: newFeed, decimals: newFeed.decimals(), heartbeat: _heartbeat, isFeedWorking: true });
		oracleRecords[_token] = record;
		PriceRecord memory _priceRecord = priceRecords[_token];
		_processFeedResponses(_token, record, currResponse, _priceRecord);
		emit NewOracleRegistered(_token, _chainlinkOracle);
	}

	/**
        @notice Get the latest price returned from the oracle
        @dev You can obtain these values by calling `TroveManager.fetchPrice()`
             rather than directly interacting with this contract.
        @param _token Token to fetch the price for
        @return The latest valid price for the requested token
     */
	function fetchPrice(address _token) public returns (uint256) {
		PriceRecord memory priceRecord = priceRecords[_token];
		OracleRecord memory oracle = oracleRecords[_token];

		uint256 scaledPrice = priceRecord.scaledPrice;
		// We short-circuit only if the price was already correct in the current block
		if (priceRecord.lastUpdated != block.timestamp) {
			if (priceRecord.lastUpdated == 0) {
				revert PriceFeed__UnknownFeedError(_token);
			}
			FeedResponse memory currResponse = _fetchFeedResponses(oracle.chainLinkOracle);
			scaledPrice = _processFeedResponses(_token, oracle, currResponse, priceRecord);
		}
		return scaledPrice;
	}

	function _processFeedResponses(address _token, OracleRecord memory oracle, FeedResponse memory _currResponse, PriceRecord memory priceRecord) internal returns (uint256) {
		uint8 decimals = oracle.decimals;
		bool isValidResponse = _isFeedWorking(_currResponse) && !_isPriceStale(_currResponse.timestamp, oracle.heartbeat);
		if (isValidResponse) {
			uint256 scaledPrice = _scalePriceByDigits(_token, uint256(_currResponse.answer), decimals);
			if (!oracle.isFeedWorking) {
				_updateFeedStatus(_token, oracle, true);
			}
			_storePrice(_token, scaledPrice, _currResponse.timestamp, _currResponse.roundId);
			return scaledPrice;
		} else {
			if (oracle.isFeedWorking) {
				_updateFeedStatus(_token, oracle, false);
			}
			if (_isPriceStale(priceRecord.timestamp, oracle.heartbeat)) {
				revert PriceFeed__FeedFrozenError(_token);
			}
			return priceRecord.scaledPrice;
		}
	}

	function _fetchFeedResponses(IAggregatorV3Interface oracle) internal view returns (FeedResponse memory currResponse) {
		currResponse = _fetchCurrentFeedResponse(oracle);
	}

	function _isPriceStale(uint256 _priceTimestamp, uint256 _heartbeat) internal view returns (bool) {
		return block.timestamp - _priceTimestamp > _heartbeat + RESPONSE_TIMEOUT_BUFFER;
	}

	function _isFeedWorking(FeedResponse memory _currentResponse) internal view returns (bool) {
		return _isValidResponse(_currentResponse);
	}

	function _isValidResponse(FeedResponse memory _response) internal view returns (bool) {
		return (_response.success) && (_response.roundId != 0) && (_response.timestamp != 0) && (_response.timestamp <= block.timestamp) && (_response.answer > 0);
	}

	function _scalePriceByDigits(address token, uint256 _price, uint256 _answerDigits) internal view returns (uint256) {
		uint8 targetDigits = TARGET_DIGITS[token];
		if (_answerDigits == targetDigits) {
			return _price;
		} else if (_answerDigits < targetDigits) {
			// Scale the returned price value up to target precision
			return _price * (10 ** (targetDigits - _answerDigits));
		} else {
			// Scale the returned price value down to target precision
			return _price / (10 ** (_answerDigits - targetDigits));
		}
	}

	function _updateFeedStatus(address _token, OracleRecord memory _oracle, bool _isWorking) internal {
		oracleRecords[_token].isFeedWorking = _isWorking;
		emit PriceFeedStatusUpdated(_token, address(_oracle.chainLinkOracle), _isWorking);
	}

	function _storePrice(address _token, uint256 _price, uint256 _timestamp, uint128 roundId) internal {
		priceRecords[_token] = PriceRecord({ scaledPrice: _price, timestamp: uint64(_timestamp), lastUpdated: uint64(block.timestamp), roundId: roundId });
		emit PriceRecordUpdated(_token, _price);
	}

	function _fetchCurrentFeedResponse(IAggregatorV3Interface _priceAggregator) internal view returns (FeedResponse memory response) {
		try _priceAggregator.latestRoundData() returns (uint80 roundId, int256 answer, uint256 /* startedAt */, uint256 timestamp, uint80 /* answeredInRound */) {
			// If call to Chainlink succeeds, return the response and success = true
			response.roundId = roundId;
			response.answer = answer;
			response.timestamp = timestamp;
			response.success = true;
		} catch {
			// If call to Chainlink aggregator reverts, return a zero response with success = false
			return response;
		}
	}

	function _fetchPrevFeedResponse(IAggregatorV3Interface _priceAggregator, uint80 _currentRoundId) internal view returns (FeedResponse memory prevResponse) {
		if (_currentRoundId == 0) {
			return prevResponse;
		}
		unchecked {
			try _priceAggregator.getRoundData(_currentRoundId - 1) returns (uint80 roundId, int256 answer, uint256 /* startedAt */, uint256 timestamp, uint80 /* answeredInRound */) {
				prevResponse.roundId = roundId;
				prevResponse.answer = answer;
				prevResponse.timestamp = timestamp;
				prevResponse.success = true;
			} catch {}
		}
	}
}
