// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "./ITroveManager.sol";

interface IBorrowerOperations {
	struct LocalVariables_openTrove {
		IERC20 collateralToken;
		uint256 price;
		uint256 totalCollateral;
		uint256 totalDebt;
		uint256 totalInterest;
		uint256 netDebt;
		uint256 compositeDebt;
		uint256 MCR;
		uint256 CCR;
		uint256 ICR;
	}

	struct LocalVariables_adjustTrove {
		IERC20 collateralToken;
		uint256 price;
		uint256 totalCollateral;
		uint256 totalDebt;
		uint256 totalInterest;
		uint256 collChange;
		bool isCollIncrease;
		uint256 debt;
		uint256 coll;
		uint256 interest;
		uint256 newDebt;
		uint256 newColl;
		uint256 stake;
		uint256 debtChange;
		uint256 interestRepayment;
		address account;
		uint256 MCR;
		uint256 CCR;
		bool isBelowCriticalThreshold;
	}

	struct LocalVariables_closeTrove {
		ITroveManager troveManager;
		IERC20 collateralToken;
		address account;
		uint256 totalCollateral;
		uint256 totalDebt;
		uint256 totalInterest;
		uint256 compositeDebt;
		uint256 price;
		uint256 CCR;
	}

	enum BorrowerOperation {
		openTrove,
		closeTrove,
		adjustTrove
	}

	event MinNetDebtUpdated(uint256 minNetDebt);
	event CollateralConfigured(ITroveManager troveManager, IERC20 collateralToken);
	event TroveManagerRemoved(ITroveManager troveManager);
	event TroveCreated(address borrower, ITroveManager troveManager, uint256 id, uint256 _collateralAmount, uint256 _debtAmount);
	event AdjustTrove(address borrower, ITroveManager troveManager, uint256 id, uint256 _collDeposit, uint256 _collWithdrawal, uint256 _debtChange, bool _isDebtIncrease);
	event CloseTrove(address borrower, ITroveManager troveManager, uint256 id, address receiver, uint256 coll, uint256 debt, uint256 interest);

	function minNetDebt() external view returns (uint256);
	function collateraTokens(ITroveManager troveManager) external view returns (IERC20);
	function repay(ITroveManager troveManager, uint256 id, uint256 _debtAmount) external;
	function configureCollateral(ITroveManager troveManager, IERC20 collateralToken) external;
}
