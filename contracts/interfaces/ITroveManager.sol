// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import "./IPriceFeed.sol";
import "./IMetadataNFT.sol";

interface ITroveManager is IERC721Enumerable {
	// Store the necessary data for a trove
	struct Trove {
		uint256 debt;
		uint256 coll;
		uint256 stake;
		uint256 interest;
	}

	struct LocalTroveUpdateVariables {
		uint256 id;
		uint256 debtChange;
		uint256 collChange;
		uint256 interestRepayment;
		bool isCollIncrease;
		bool isDebtIncrease;
		address receiver;
	}

	struct DeploymentParams {
		uint256 interestRate; // 1e16 (1%)
		uint256 maxDebt;
		uint256 spYieldPCT;
		uint256 liquidationPenaltySP;
		uint256 liquidationPenaltyRedistribution;
		uint256 maxCollGasCompensation;
		uint256 MCR; // 11e17  (110%)
		uint256 SCR;
		uint256 CCR;
		IMetadataNFT metadataNFT;
	}

	// Object containing the collateral and debt snapshots for a given active trove
	struct RewardSnapshot {
		uint256 collateral;
		uint256 debt;
		uint256 activeInterest;
		uint256 defaultedInterest;
	}

	struct LiquidationValues {
		uint256 collOffset;
		uint256 debtOffset;
		uint256 interestOffset;
		uint256 collRedist;
		uint256 debtRedist;
		uint256 interestRedist;
		uint256 debtGasCompensation;
		uint256 collGasCompensation;
		uint256 remainingDeposits;
		uint256 collSurplus;
	}

	struct SingleLiquidation {
		uint256 coll;
		uint256 debt;
		uint256 interest;
		uint256 collGasCompensation;
		uint256 debtGasCompensation;
		uint256 collToLiquidate;
		uint256 collOffset;
		uint256 debtOffset;
		uint256 interestOffset;
		uint256 collRedist;
		uint256 debtRedist;
		uint256 interestRedist;
		uint256 collSurplus;
	}

	enum TroveManagerOperation {
		open,
		close,
		adjust,
		liquidate
	}
	event CRUpdated(uint256 _MCR, uint256 _SCR, uint256 _CCR);
	event ShutDown();
	event PauseUpdated(bool _paused);
	event PriceFeedUpdated(IPriceFeed priceFeed);
	event MetadataNFTUpdated(IMetadataNFT _metadataNFT);
	event InterestRateUpdated(uint256 _interestRate);
	event MaxSystemDebtUpdated(uint256 _cap);
	event SPYieldPCTUpdated(uint256 _spYielPCT);
	event LIQUIDATION_PENALTY_SP_Updated(uint256 _penaltySP);
	event LIQUIDATION_PENALTY_REDISTRIBUTION_Updated(uint256 _penaltyRedist);
	event MAX_COLL_GAS_COMPENSATION_Updated(uint256 _maxCollGasCompensation);

	event TroveOpened(uint256 id, address owner, uint256 _collateralAmount, uint256 _compositeDebt, uint256 stake);
	event TroveUpdated(uint256 id, uint256 newColl, uint256 newDebt, uint256 newStake, uint256 newInterest, address _receiver, TroveManagerOperation operation);
	event TotalStakesUpdated(uint256 newTotalStakes);
	event LTermsUpdated(uint256 new_L_collateral, uint256 new_L_debt, uint256 new_L_defaulted_interest);
	event Liquidated(address owner, uint256 id, uint256 coll, uint256 debt, uint256 interest, uint256 collSurplus);
	event CollateralSent(address _account, uint256 _amount);
	event CollSurplusClaimed(address _account, uint256 _amount);
	event TroveClosed(uint256 id);
	event InterestAccrued(uint256 interest);
	event SPYieldAccrued(uint256 yieldFee);
	function accrueInterests() external returns (uint256 yieldSP, uint256 yieldFee);
	function collateralToken() external view returns (IERC20);
	function totalActiveDebt() external view returns (uint256);
	function defaultedDebt() external view returns (uint256);
	function shutdownAt() external view returns (uint256);
	function getEntireSystemDebt() external view returns (uint256);
	function getEntireSystemBalances() external returns (uint256 coll, uint256 debt, uint256 interest, uint256 price);
	function interestRate() external view returns (uint256);
	function MCR() external view returns (uint256);
	function SCR() external view returns (uint256);
	function CCR() external view returns (uint256);
	function maxSystemDebt() external view returns (uint256);
	function SP_YIELD_PCT() external view returns (uint256);
	function MAX_COLL_GAS_COMPENSATION() external view returns (uint256);
	function LIQUIDATION_PENALTY_SP() external view returns (uint256);
	function LIQUIDATION_PENALTY_REDISTRIBUTION() external view returns (uint256);
	function getTCR() external returns (uint256);
	function setParameters(IPriceFeed _priceFeed, IERC20 _collateral, DeploymentParams memory params) external;
	function openTrove(address owner, uint256 _collateralAmount, uint256 _compositeDebt) external returns (uint256 id);
	function updateTroveFromAdjustment(uint256 id, bool _isDebtIncrease, uint256 _debtChange, bool _isCollIncrease, uint256 _collChange, uint256 _interestRepayment, address _receiver) external returns (uint256, uint256, uint256, uint256);
	function closeTrove(uint256 id, address _receiver, uint256 collAmount, uint256 debtAmount, uint256 interest) external;
	function applyPendingRewards(uint256 id) external returns (uint256 coll, uint256 debt, uint256 interest);
	function fetchPrice() external returns (uint256);
	function getCurrentTrove(uint256 id) external view returns (Trove memory);
	function getPendingYieldSP() external view returns (uint256);
	function accountCollSurplus(address account) external view returns (uint256);
	function hasShutdown() external view returns (bool);
	function batchLiquidate(uint256[] memory ids) external;
}
