// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "../interfaces/IBorrowerOperations.sol";
import "../interfaces/ITroveManager.sol";

contract MultiTroveGetters {
	struct Params {
		uint256 CCR;
		uint256 MCR;
		uint256 SCR;
		uint256 TCR;
		uint256 LIQUIDATION_PENALTY_SP;
		uint256 totalColl;
		uint256 totalDebt;
		uint256 totalInterest;
		uint256 price;
		uint256 maxSystemDebt;
		uint256 interestRate;
		uint256 minNetDebt;
		uint256 accountCollSurplus;
		bool hasShutdown;
		ITroveManager troveManager;
	}

	struct TroveState {
		uint256 ICR;
		uint256 id;
		address owner;
		uint256 entireDebt;
		uint256 maxDebtToMint;
		uint256 maxCollToWithdraw;
		uint256 liquidationPrice;
		ITroveManager.Trove trove;
	}

	IBorrowerOperations public borrowerOperations;

	constructor(IBorrowerOperations _borrowerOperations) {
		borrowerOperations = _borrowerOperations;
	}

	function getTroves(ITroveManager troveManager, uint256 startIndex, uint256 endIndex) external returns (Params memory params, TroveState[] memory states) {
		uint256 totalSupply = troveManager.totalSupply();
		if (endIndex > totalSupply) {
			endIndex = totalSupply;
		}
		require(endIndex > startIndex, "endIndex must be greater than startIndex");
		params.troveManager = troveManager;
		params.CCR = troveManager.CCR();
		params.MCR = troveManager.MCR();
		params.SCR = troveManager.SCR();
		params.TCR = troveManager.getTCR();
		params.maxSystemDebt = troveManager.maxSystemDebt();
		params.interestRate = troveManager.interestRate();
		params.LIQUIDATION_PENALTY_SP = troveManager.LIQUIDATION_PENALTY_SP();
		params.minNetDebt = borrowerOperations.minNetDebt();
		(params.totalColl, params.totalDebt, params.totalInterest, params.price) = params.troveManager.getEntireSystemBalances();
		params.hasShutdown = params.troveManager.hasShutdown();
		uint256 length = endIndex - startIndex;
		states = new TroveState[](length);
		for (uint256 i = 0; i < length; i++) {
			uint256 index = startIndex + i;
			uint256 id = troveManager.tokenByIndex(index);
			ITroveManager.Trove memory trove = troveManager.getCurrentTrove(id);
			states[i].trove = trove;
			states[i].id = id;
			states[i].entireDebt = trove.debt + trove.interest;
			address owner = troveManager.ownerOf(id);
			states[i].owner = owner;
			states[i].ICR = (trove.coll * params.price) / states[i].entireDebt;
			if (params.TCR > params.CCR) {
				calcMaxDebtToMint(params, states[i]);
				calcMaxCollToWithdraw(params, states[i]);
			}
			states[i].liquidationPrice = (params.MCR * states[i].entireDebt) / trove.coll;
		}
	}

	function getTrovesByOwner(ITroveManager troveManager, address owner) external returns (Params memory params, TroveState[] memory states) {
		uint256 balance = troveManager.balanceOf(owner);
		params.troveManager = troveManager;
		params.CCR = troveManager.CCR();
		params.MCR = troveManager.MCR();
		params.SCR = troveManager.SCR();
		params.TCR = troveManager.getTCR();
		params.maxSystemDebt = troveManager.maxSystemDebt();
		params.interestRate = troveManager.interestRate();
		params.LIQUIDATION_PENALTY_SP = troveManager.LIQUIDATION_PENALTY_SP();
		params.minNetDebt = borrowerOperations.minNetDebt();
		(params.totalColl, params.totalDebt, params.totalInterest, params.price) = params.troveManager.getEntireSystemBalances();
		params.hasShutdown = params.troveManager.hasShutdown();
		params.accountCollSurplus = troveManager.accountCollSurplus(owner);
		states = new TroveState[](balance);
		for (uint256 i = 0; i < balance; i++) {
			uint256 index = i;
			uint256 id = troveManager.tokenOfOwnerByIndex(owner, index);
			ITroveManager.Trove memory trove = troveManager.getCurrentTrove(id);
			states[i].trove = trove;
			states[i].id = id;
			states[i].owner = owner;
			states[i].entireDebt = trove.debt + trove.interest;
			states[i].ICR = (trove.coll * params.price) / states[i].entireDebt;
			if (params.TCR > params.CCR) {
				calcMaxDebtToMint(params, states[i]);
				calcMaxCollToWithdraw(params, states[i]);
			}
			states[i].liquidationPrice = (params.MCR * states[i].entireDebt) / trove.coll;
		}
	}

	function getSingleTrove(ITroveManager troveManager, uint256 id) external returns (Params memory params, TroveState memory state) {
		params.troveManager = troveManager;
		params.CCR = troveManager.CCR();
		params.MCR = troveManager.MCR();
		params.SCR = troveManager.SCR();
		params.TCR = troveManager.getTCR();
		params.maxSystemDebt = troveManager.maxSystemDebt();
		params.interestRate = troveManager.interestRate();
		params.LIQUIDATION_PENALTY_SP = troveManager.LIQUIDATION_PENALTY_SP();
		params.minNetDebt = borrowerOperations.minNetDebt();
		(params.totalColl, params.totalDebt, params.totalInterest, params.price) = params.troveManager.getEntireSystemBalances();
		params.hasShutdown = params.troveManager.hasShutdown();
		ITroveManager.Trove memory trove = troveManager.getCurrentTrove(id);
		state.trove = trove;
		state.id = id;
		state.entireDebt = trove.debt + trove.interest;
		address owner = troveManager.ownerOf(id);
		state.owner = owner;
		params.accountCollSurplus = troveManager.accountCollSurplus(owner);
		state.ICR = (trove.coll * params.price) / state.entireDebt;
		if (params.TCR > params.CCR) {
			calcMaxDebtToMint(params, state);
			calcMaxCollToWithdraw(params, state);
		}
		state.liquidationPrice = (params.MCR * state.entireDebt) / trove.coll;
	}

	function calcMaxDebtToMint(Params memory params, TroveState memory state) internal pure {
		if (state.ICR > params.MCR) {
			uint256 maxDebt = (state.trove.coll * params.price) / params.MCR;
			uint256 totalMaxDebt = (params.totalColl * params.price) / params.CCR;
			uint256 maxDebtMint = Math.min(maxDebt - state.entireDebt, totalMaxDebt - params.totalDebt - params.totalInterest);
			state.maxDebtToMint = maxDebtMint;
		}
	}

	function calcMaxCollToWithdraw(Params memory params, TroveState memory state) internal pure {
		if (state.ICR > params.MCR) {
			uint256 minColl = (state.entireDebt * params.MCR) / params.price;
			uint256 totalMinColl = ((params.totalDebt + params.totalInterest) * params.CCR) / params.price;
			uint256 collWithdraw = Math.min(state.trove.coll - minColl, params.totalColl - totalMinColl);
			state.maxCollToWithdraw = collWithdraw;
		}
	}
}
