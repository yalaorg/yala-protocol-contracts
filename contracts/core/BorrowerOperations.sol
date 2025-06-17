// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";

import "../interfaces/IDebtToken.sol";
import "../interfaces/IBorrowerOperations.sol";
import "../dependencies/YalaBase.sol";
import "../dependencies/YalaMath.sol";
import "../dependencies/YalaOwnable.sol";
import "../dependencies/DelegatedOps.sol";

/**
    @title Yala Borrower Operations
    @notice Based on Liquity's `BorrowerOperations`
            https://github.com/liquity/dev/blob/main/packages/contracts/contracts/BorrowerOperations.sol

 */
contract BorrowerOperations is IBorrowerOperations, YalaBase, YalaOwnable, DelegatedOps {
	using SafeERC20 for IERC20;

	IDebtToken public immutable debtToken;
	address public immutable factory;
	uint256 public minNetDebt;

	mapping(ITroveManager => IERC20) public collateraTokens;

	modifier auth(ITroveManager troveManager, uint256 id) {
		address owner = troveManager.ownerOf(id);
		require(msg.sender == owner || troveManager.getApproved(id) == msg.sender || troveManager.isApprovedForAll(owner, msg.sender), "BorrowerOps: Not authorized");
		_;
	}

	constructor(address _yalaCore, address _debtTokenAddress, address _factory, uint256 _minNetDebt, uint256 _gasCompensation) YalaOwnable(_yalaCore) YalaBase(_gasCompensation) {
		debtToken = IDebtToken(_debtTokenAddress);
		factory = _factory;
		_setMinNetDebt(_minNetDebt);
	}

	function _setMinNetDebt(uint256 _minNetDebt) internal {
		require(_minNetDebt > 0, "BorrowerOps: Invalid min net debt");
		minNetDebt = _minNetDebt;
		emit MinNetDebtUpdated(_minNetDebt);
	}

	function configureCollateral(ITroveManager troveManager, IERC20 collateralToken) external {
		require(msg.sender == factory, "BorrowerOps: !Factory");
		require(address(collateraTokens[troveManager]) == address(0), "BorrowerOps: Collateral configured");
		collateraTokens[troveManager] = collateralToken;
		emit CollateralConfigured(troveManager, collateralToken);
	}

	function removeTroveManager(ITroveManager troveManager) external {
		require(address(collateraTokens[troveManager]) != address(0) && troveManager.shutdownAt() != 0 && troveManager.getEntireSystemDebt() == 0, "Trove Manager cannot be removed");
		delete collateraTokens[troveManager];
		emit TroveManagerRemoved(troveManager);
	}

	function getCompositeDebt(uint256 _debt) public view returns (uint256) {
		return _getCompositeDebt(_debt);
	}

	function openTrove(ITroveManager troveManager, address account, uint256 _collateralAmount, uint256 _debtAmount) external callerOrDelegated(account) returns (uint256 id) {
		require(!YALA_CORE.paused(), "BorrowerOps: Deposits are paused");
		LocalVariables_openTrove memory vars;
		vars.netDebt = _debtAmount;
		vars.compositeDebt = _getCompositeDebt(vars.netDebt);
		_requireAtLeastMinNetDebt(vars.compositeDebt);
		troveManager.accrueInterests();
		(vars.collateralToken, vars.totalCollateral, vars.totalDebt, vars.totalInterest, vars.price) = _getCollateralAndTCRData(troveManager);
		(vars.MCR, vars.CCR) = (troveManager.MCR(), troveManager.CCR());
		vars.ICR = YalaMath._computeCR(_collateralAmount, vars.compositeDebt, vars.price);
		_requireICRisAboveMCR(vars.ICR, vars.MCR);
		uint256 TCR = YalaMath._computeCR(vars.totalCollateral, vars.totalDebt + vars.totalInterest, vars.price);
		if (TCR >= vars.CCR) {
			uint256 newTCR = _getNewTCRFromTroveChange(vars.totalCollateral * vars.price, vars.totalDebt + vars.totalInterest, _collateralAmount * vars.price, true, vars.compositeDebt, true);
			_requireNewTCRisAboveCCR(newTCR, vars.CCR);
		} else {
			_requireICRisAboveCCR(vars.ICR, vars.CCR);
		}
		// Create the trove
		id = troveManager.openTrove(account, _collateralAmount, vars.compositeDebt);
		// Move the collateral to the Trove Manager
		vars.collateralToken.safeTransferFrom(msg.sender, address(troveManager), _collateralAmount);
		//  and mint the DebtAmount to the caller and gas compensation for Gas Pool
		debtToken.mintWithGasCompensation(account, vars.netDebt);
		emit TroveCreated(account, troveManager, id, _collateralAmount, vars.compositeDebt);
	}

	// Send collateral to a trove
	function addColl(ITroveManager troveManager, uint256 id, uint256 _collateralAmount) external {
		_adjustTrove(troveManager, id, _collateralAmount, 0, 0, false);
	}

	// Withdraw collateral from a trove
	function withdrawColl(ITroveManager troveManager, uint256 id, uint256 _collWithdrawal) external {
		_adjustTrove(troveManager, id, 0, _collWithdrawal, 0, false);
	}

	// Withdraw Debt tokens from a trove: mint new Debt tokens to the owner, and increase the trove's debt accordingly
	function withdrawDebt(ITroveManager troveManager, uint256 id, uint256 _debtAmount) external {
		_adjustTrove(troveManager, id, 0, 0, _debtAmount, true);
	}

	// Repay Debt tokens to a Trove: Burn the repaid Debt tokens, and reduce the trove's debt accordingly
	function repay(ITroveManager troveManager, uint256 id, uint256 _debtAmount) external {
		_adjustTrove(troveManager, id, 0, 0, _debtAmount, false);
	}

	function adjustTrove(ITroveManager troveManager, uint256 id, uint256 _collDeposit, uint256 _collWithdrawal, uint256 _debtChange, bool _isDebtIncrease) external {
		_adjustTrove(troveManager, id, _collDeposit, _collWithdrawal, _debtChange, _isDebtIncrease);
	}

	function _adjustTrove(ITroveManager troveManager, uint256 id, uint256 _collDeposit, uint256 _collWithdrawal, uint256 _debtChange, bool _isDebtIncrease) internal {
		require((_collDeposit == 0 && !_isDebtIncrease) || !YALA_CORE.paused(), "BorrowerOps: Trove adjustments are paused");
		require(_collDeposit == 0 || _collWithdrawal == 0, "BorrowerOps: Cannot withdraw and add coll");
		require(_collDeposit != 0 || _collWithdrawal != 0 || _debtChange != 0, "BorrowerOps: There must be either a collateral change or a debt change");
		LocalVariables_adjustTrove memory vars;
		vars.account = troveManager.ownerOf(id);
		if (_collDeposit != 0 || _collWithdrawal != 0 || _isDebtIncrease) {
			require(msg.sender == vars.account || troveManager.getApproved(id) == msg.sender || troveManager.isApprovedForAll(vars.account, msg.sender), "BorrowerOps: Not authorized");
		}
		if (_isDebtIncrease) {
			require(_debtChange > 0, "BorrowerOps: Debt increase requires non-zero debtChange");
		}
		(vars.coll, vars.debt, vars.interest) = troveManager.applyPendingRewards(id);
		(vars.collateralToken, vars.totalCollateral, vars.totalDebt, vars.totalInterest, vars.price) = _getCollateralAndTCRData(troveManager);
		(vars.debtChange, vars.MCR, vars.CCR) = (_debtChange, troveManager.MCR(), troveManager.CCR());
		uint256 TCR = YalaMath._computeCR(vars.totalCollateral, vars.totalDebt + vars.totalInterest, vars.price);
		vars.isBelowCriticalThreshold = TCR < vars.CCR;
		// Get the collChange based on whether or not collateral was sent in the transaction
		(vars.collChange, vars.isCollIncrease) = _getCollChange(_collDeposit, _collWithdrawal);
		if (!_isDebtIncrease && _debtChange > 0) {
			if (_debtChange > (vars.debt - minNetDebt)) {
				vars.debtChange = vars.debt - minNetDebt;
				_debtChange = _debtChange - vars.debtChange;
				vars.interestRepayment = YalaMath._min(_debtChange, vars.interest);
			} else {
				vars.debtChange = _debtChange;
			}
		}
		_requireValidAdjustment(_isDebtIncrease, vars);
		// If we are incrasing collateral, send tokens to the trove manager prior to adjusting the trove
		if (vars.isCollIncrease) vars.collateralToken.safeTransferFrom(msg.sender, address(troveManager), vars.collChange);
		troveManager.updateTroveFromAdjustment(id, _isDebtIncrease, vars.debtChange, vars.isCollIncrease, vars.collChange, vars.interestRepayment, msg.sender);
		emit AdjustTrove(vars.account, troveManager, id, _collDeposit, _collWithdrawal, vars.debtChange + vars.interestRepayment, _isDebtIncrease);
	}

	function closeTrove(ITroveManager troveManager, uint256 id, address receiver) external auth(troveManager, id) {
		LocalVariables_closeTrove memory vars;
		(vars.troveManager, vars.CCR, vars.account) = (troveManager, troveManager.CCR(), troveManager.ownerOf(id));
		(uint256 coll, uint256 debt, uint256 interest) = vars.troveManager.applyPendingRewards(id);
		(vars.collateralToken, vars.totalCollateral, vars.totalDebt, vars.totalInterest, vars.price) = _getCollateralAndTCRData(troveManager);
		vars.compositeDebt = debt + interest;
		if (!troveManager.hasShutdown()) {
			uint256 newTCR = _getNewTCRFromTroveChange(vars.totalCollateral * vars.price, vars.totalDebt + vars.totalInterest, coll * vars.price, false, vars.compositeDebt, false);
			_requireNewTCRisAboveCCR(newTCR, vars.CCR);
		}
		troveManager.closeTrove(id, receiver, coll, debt, interest);
		// Burn the repaid Debt from the user's balance and the gas compensation from the Gas Pool
		debtToken.burnWithGasCompensation(msg.sender, vars.compositeDebt - DEBT_GAS_COMPENSATION);
		emit CloseTrove(vars.account, troveManager, id, receiver, coll, debt, interest);
	}

	function _getCollChange(uint256 _collReceived, uint256 _requestedCollWithdrawal) internal pure returns (uint256 collChange, bool isCollIncrease) {
		if (_collReceived != 0) {
			collChange = _collReceived;
			isCollIncrease = true;
		} else {
			collChange = _requestedCollWithdrawal;
		}
	}

	function _requireValidAdjustment(bool _isDebtIncrease, LocalVariables_adjustTrove memory _vars) internal pure {
		uint256 newICR = _getNewICRFromTroveChange(_vars.coll, _vars.debt + _vars.interest, _vars.collChange, _vars.isCollIncrease, _vars.debtChange + _vars.interestRepayment, _isDebtIncrease, _vars.price);
		_requireICRisAboveMCR(newICR, _vars.MCR);
		uint256 newTCR = _getNewTCRFromTroveChange(_vars.totalCollateral * _vars.price, _vars.totalDebt + _vars.totalInterest, _vars.collChange * _vars.price, _vars.isCollIncrease, _vars.debtChange + _vars.interestRepayment, _isDebtIncrease);
		if (_vars.isBelowCriticalThreshold) {
			if (_isDebtIncrease) {
				_requireNewTCRisAboveCCR(newTCR, _vars.CCR);
			} else if (!_vars.isCollIncrease) {
				require((_vars.debtChange + _vars.interestRepayment) * DECIMAL_PRECISION >= _vars.collChange * _vars.price, "BorrowerOps: Cannot withdraw collateral without paying back debt");
			}
		} else {
			_requireNewTCRisAboveCCR(newTCR, _vars.CCR);
		}
	}

	function _requireICRisAboveMCR(uint256 _newICR, uint256 MCR) internal pure {
		require(_newICR >= MCR, "BorrowerOps: An operation that would result in ICR < MCR is not permitted");
	}

	function _requireICRisAboveCCR(uint256 _newICR, uint256 CCR) internal pure {
		require(_newICR >= CCR, "BorrowerOps: An operation that would result in ICR < CCR is not permitted");
	}

	function _requireNewTCRisAboveCCR(uint256 _newTCR, uint256 CCR) internal pure {
		require(_newTCR >= CCR, "BorrowerOps: An operation that would result in TCR < CCR is not permitted");
	}

	function _requireAtLeastMinNetDebt(uint256 _netDebt) internal view {
		require(_netDebt >= minNetDebt, "BorrowerOps: Trove's net debt must be greater than minimum");
	}

	// Compute the new collateral ratio, considering the change in coll and debt. Assumes 0 pending rewards.
	function _getNewICRFromTroveChange(uint256 _coll, uint256 _debt, uint256 _collChange, bool _isCollIncrease, uint256 _debtChange, bool _isDebtIncrease, uint256 _price) internal pure returns (uint256) {
		(uint256 newColl, uint256 newDebt) = _getNewTroveAmounts(_coll, _debt, _collChange, _isCollIncrease, _debtChange, _isDebtIncrease);
		uint256 newICR = YalaMath._computeCR(newColl, newDebt, _price);
		return newICR;
	}

	function _getNewTroveAmounts(uint256 _coll, uint256 _debt, uint256 _collChange, bool _isCollIncrease, uint256 _debtChange, bool _isDebtIncrease) internal pure returns (uint256, uint256) {
		uint256 newColl = _coll;
		uint256 newDebt = _debt;
		newColl = _isCollIncrease ? _coll + _collChange : _coll - _collChange;
		newDebt = _isDebtIncrease ? _debt + _debtChange : _debt - _debtChange;
		return (newColl, newDebt);
	}

	function _getNewTCRFromTroveChange(uint256 totalColl, uint256 totalDebt, uint256 _collChange, bool _isCollIncrease, uint256 _debtChange, bool _isDebtIncrease) internal pure returns (uint256) {
		totalDebt = _isDebtIncrease ? totalDebt + _debtChange : totalDebt - _debtChange;
		totalColl = _isCollIncrease ? totalColl + _collChange : totalColl - _collChange;
		uint256 newTCR = YalaMath._computeCR(totalColl, totalDebt);
		return newTCR;
	}

	function _getCollateralAndTCRData(ITroveManager troveManager) internal returns (IERC20 collateraToken, uint256 coll, uint256 debt, uint256 interest, uint256 price) {
		collateraToken = collateraTokens[troveManager];
		require(address(collateraToken) != address(0), "BorrowerOps: nonexistent collateral");
		(coll, debt, interest, price) = troveManager.getEntireSystemBalances();
	}

	function getTCR(ITroveManager troveManager) public returns (uint256) {
		return troveManager.getTCR();
	}
}
