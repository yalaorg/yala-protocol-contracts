// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "../interfaces/IDebtToken.sol";
import "../dependencies/YalaOwnable.sol";
import "../interfaces/IPSM.sol";

contract PSM is IPSM, YalaOwnable, Pausable {
	using SafeERC20 for IERC20;

	uint256 public constant DECIMAL_PRECISIONS = 1e18;
	address public immutable override factory;
	IDebtToken public immutable override debtToken;
	IERC20Metadata public override pegToken;
	uint256 public override priceFactor;
	uint256 public override feeIn; // Fee for buying debtToken  (in DECIMAL_PRECISIONS)
	uint256 public override feeOut; // Fee for selling debtToken (in DECIMAL_PRECISIONS)
	uint256 public supplyCap; // Maximum amount of debtToken that can be held by PSM
	uint256 public totalActivedebt;

	constructor(address _yalaCore, address _factory, address _debtToken) YalaOwnable(_yalaCore) {
		factory = _factory;
		debtToken = IDebtToken(_debtToken);
	}

	function initialize(IERC20Metadata _pegToken, uint256 _feeIn, uint256 _feeOut, uint256 _supplyCap) external override {
		require(msg.sender == factory, "PSM: !Factory");
		uint8 pegTokenDecimals = _pegToken.decimals();
		require(pegTokenDecimals <= 18, "PSM: Peg token decimals not supported");
		priceFactor = 10 ** (18 - pegTokenDecimals);
		pegToken = _pegToken;
		_setFeeIn(_feeIn);
		_setFeeOut(_feeOut);
		_setSupplyCap(_supplyCap);
		emit PegTokenUpdated(_pegToken);
	}

	function setFeeIn(uint256 _feeIn) external override onlyOwner {
		_setFeeIn(_feeIn);
	}

	function setFeeOut(uint256 _feeOut) external override onlyOwner {
		_setFeeOut(_feeOut);
	}

	function setSupplyCap(uint256 _supplyCap) external onlyOwner {
		_setSupplyCap(_supplyCap);
	}

	// New functions for pausing and unpausing
	function pause() external onlyOwner {
		_pause();
	}

	function unpause() external onlyOwner {
		_unpause();
	}

	function buy(uint256 amountPegToken) external override whenNotPaused returns (uint256 amountDebtTokenReceived, uint256 fee) {
		require(amountPegToken > 0, "PSM: Amount peg token must be greater than 0");
		(amountDebtTokenReceived, fee) = estimateBuy(amountPegToken);
		require(totalActivedebt + amountDebtTokenReceived <= supplyCap, "PSM: Supply cap reached");
		if (feeIn > 0) require(fee > 0, "PSM: Fee must be greater than 0");
		IERC20(pegToken).safeTransferFrom(msg.sender, address(this), amountPegToken);
		debtToken.mint(msg.sender, amountDebtTokenReceived);
		if (fee > 0) debtToken.mint(YALA_CORE.feeReceiver(), fee);
		totalActivedebt = totalActivedebt + amountDebtTokenReceived + fee;

		emit Buy(msg.sender, amountDebtTokenReceived, amountPegToken, fee);
	}

	function sell(uint256 amountDebtToken) external override whenNotPaused returns (uint256 amountPegTokenReceived, uint256 fee) {
		require(amountDebtToken > 0, "PSM: Amount debt token must be greater than 0");
		(amountPegTokenReceived, fee) = estimateSell(amountDebtToken);
		if (feeOut > 0) require(fee > 0, "PSM: Fee must be greater than 0");
		require(pegToken.balanceOf(address(this)) >= amountPegTokenReceived, "PSM: Insufficient peg token balance");
		debtToken.burn(msg.sender, amountDebtToken - fee);
		IERC20(pegToken).safeTransfer(msg.sender, amountPegTokenReceived);
		if (fee > 0) debtToken.transferFrom(msg.sender, YALA_CORE.feeReceiver(), fee);
		totalActivedebt = totalActivedebt - amountDebtToken;

		emit Sell(msg.sender, amountDebtToken, amountPegTokenReceived, fee);
	}

	function estimateBuy(uint256 amountPegToken) public view override returns (uint256 amountDebtTokenReceived, uint256 fee) {
		if (feeIn > 0) {
			fee = (amountPegToken * feeIn * priceFactor) / DECIMAL_PRECISIONS;
		}
		amountDebtTokenReceived = amountPegToken * priceFactor - fee;
	}

	function estimateSell(uint256 amountDebtToken) public view override returns (uint256 amountPegTokenReceived, uint256 fee) {
		if (feeOut > 0) {
			fee = (amountDebtToken * feeOut) / DECIMAL_PRECISIONS;
		}
		amountPegTokenReceived = (amountDebtToken - fee) / priceFactor;
	}

	function _setFeeIn(uint256 _feeIn) internal {
		require(_feeIn <= DECIMAL_PRECISIONS, "PSM: Fee in must be less than 1");
		feeIn = _feeIn;
		emit FeeInUpdated(_feeIn);
	}

	function _setFeeOut(uint256 _feeOut) internal {
		require(_feeOut <= DECIMAL_PRECISIONS, "PSM: Fee out must be less than 1");
		feeOut = _feeOut;
		emit FeeOutUpdated(_feeOut);
	}

	function _setSupplyCap(uint256 _supplyCap) internal {
		supplyCap = _supplyCap;
		emit SupplyCapUpdated(_supplyCap);
	}
}
