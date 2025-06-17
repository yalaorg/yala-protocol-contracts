// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "../interfaces/ITroveManager.sol";
import "../interfaces/IStabilityPool.sol";
import "../interfaces/IDebtToken.sol";
import "../interfaces/IPriceFeed.sol";

import "../dependencies/YalaBase.sol";
import "../dependencies/YalaMath.sol";
import "../dependencies/YalaOwnable.sol";

/**
    @title Yala Trove Manager
    @notice Based on Liquity's `TroveManager`
            https://github.com/liquity/dev/blob/main/packages/contracts/contracts/TroveManager.sol
 */
contract TroveManager is ITroveManager, Multicall, ERC721Enumerable, YalaBase, YalaOwnable {
	using SafeERC20 for IERC20;

	// --- Connected contract declarations ---
	address public immutable factoryAddress;
	address public immutable borrowerOperationsAddress;
	address public immutable gasPoolAddress;
	IDebtToken public immutable debtToken;
	IStabilityPool public immutable stabilityPool;
	IPriceFeed public priceFeed;
	IERC20 public collateralToken;
	IMetadataNFT public metadataNFT;
	uint256 public shutdownAt;

	uint256 public MCR;
	uint256 public SCR;
	uint256 public CCR;
	uint256 public maxSystemDebt;
	uint256 public interestRate;
	uint256 public SP_YIELD_PCT;
	uint256 public MAX_COLL_GAS_COMPENSATION;
	uint256 public LIQUIDATION_PENALTY_SP;
	uint256 public LIQUIDATION_PENALTY_REDISTRIBUTION;
	uint256 public constant INTEREST_PRECISION = 1e18;
	uint256 public constant SECONDS_IN_YEAR = 365 days;
	uint256 public constant COLL_GAS_COMPENSATION_DIVISOR = 200; // 0.5%
	bool public paused;

	uint256 public totalStakes;

	// Snapshot of the value of totalStakes, taken immediately after the latest liquidation
	uint256 public totalStakesSnapshot;

	// Snapshot of the total collateral taken immediately after the latest liquidation.
	uint256 public totalCollateralSnapshot;

	/*
	 * L_collateral and L_debt track the sums of accumulated liquidation rewards per unit staked. During its lifetime, each stake earns:
	 *
	 * An collateral gain of ( stake * [L_collateral - L_collateral(0)] )
	 * A debt increase  of ( stake * [L_debt - L_debt(0)] )
	 * A defaulted interest increase of ( stake * [L_defaulted_interest - L_defaulted_interest(0)] )
	 * Where L_collateral(0) and L_debt(0) are snapshots of L_collateral and L_debt for the active Trove taken at the instant the stake was made
	 */
	uint256 public L_collateral;
	uint256 public L_debt;
	uint256 public L_defaulted_interest;
	/**
	 * A interest increase  of ( debt * [L_active_interest - L_active_interest(0)] )
	 */
	uint256 public L_active_interest;

	// Error trackers for the trove redistribution calculation
	uint256 public lastCollateralError_Redistribution;
	uint256 public lastDebtError_Redistribution;
	uint256 public lastActiveInterestError_Redistribution;
	uint256 public lastDefaultedInterestError_Redistribution;

	uint256 public totalActiveCollateral;
	uint256 public totalActiveDebt;
	uint256 public totalActiveInterest;
	uint256 public defaultedCollateral;
	uint256 public defaultedDebt;
	uint256 public defaultedInterest;
	uint256 public lastInterestUpdate;

	mapping(uint256 => Trove) public Troves;

	// Map trove id with active troves to their RewardSnapshot
	mapping(uint256 => RewardSnapshot) public rewardSnapshots;

	mapping(address => uint256) public accountCollSurplus;

	uint256 public nonce;

	modifier whenNotPaused() {
		require(!paused, "TM: Collateral Paused");
		_;
	}

	modifier whenNotShutdown() {
		require(!hasShutdown(), "TM: Collateral Shutdown");
		_;
	}

	constructor(
		address _yalaCore,
		address _factoryAddress,
		address _gasPoolAddress,
		IDebtToken _debtToken,
		address _borrowerOperationsAddress,
		IStabilityPool _stabilityPool,
		uint256 _gasCompensation,
		uint256 _maxCollGasCompensation
	) ERC721("Yala NFT", "Yala") YalaOwnable(_yalaCore) YalaBase(_gasCompensation) {
		factoryAddress = _factoryAddress;
		gasPoolAddress = _gasPoolAddress;
		debtToken = _debtToken;
		borrowerOperationsAddress = _borrowerOperationsAddress;
		stabilityPool = _stabilityPool;
		MAX_COLL_GAS_COMPENSATION = _maxCollGasCompensation;
	}

	function setParameters(IPriceFeed _priceFeed, IERC20 _collateral, DeploymentParams memory params) external {
		require(address(collateralToken) == address(0) && msg.sender == factoryAddress, "TM: parameters set");
		require(params.interestRate < DECIMAL_PRECISION, "TM: interest rate too high");
		require(params.maxDebt > 0, "TM: interest rate too high");
		require(params.spYieldPCT <= DECIMAL_PRECISION, "TM: sp yield pct too high");
		require(params.MCR > DECIMAL_PRECISION && params.SCR >= params.MCR && params.CCR >= params.SCR, "TM: invalid cr parameters");
		collateralToken = _collateral;
		_setPriceFeed(_priceFeed);
		_setMetadataNFT(params.metadataNFT);
		_setInterestRate(params.interestRate);
		_setMaxSystemDebt(params.maxDebt);
		_setSPYielPCT(params.spYieldPCT);
		_setMaxCollGasCompensation(params.maxCollGasCompensation);
		_setLiquidationPenaltySP(params.liquidationPenaltySP);
		_setLiquidationPenaltyRedist(params.liquidationPenaltyRedistribution);
		MCR = params.MCR;
		SCR = params.SCR;
		CCR = params.CCR;
		emit CRUpdated(MCR, SCR, CCR);
	}

	function shutdown() external whenNotShutdown {
		require(msg.sender == owner() || getTCR() < SCR, "TM: Not allowed");
		shutdownAt = block.timestamp;
		accrueInterests();
		maxSystemDebt = 0;
		emit ShutDown();
	}

	function setPaused(bool _paused) external {
		require((_paused && msg.sender == guardian()) || msg.sender == owner(), "TM: Unauthorized");
		_setPaused(_paused);
	}

	function _setPaused(bool _paused) internal {
		paused = _paused;
		emit PauseUpdated(_paused);
	}

	function setPriceFeed(IPriceFeed _priceFeed) external onlyOwner {
		_setPriceFeed(_priceFeed);
	}

	function _setPriceFeed(IPriceFeed _priceFeed) internal {
		priceFeed = _priceFeed;
		emit PriceFeedUpdated(_priceFeed);
	}

	function setMetadataNFT(IMetadataNFT _metadataNFT) external onlyOwner {
		_setMetadataNFT(_metadataNFT);
	}

	function _setMetadataNFT(IMetadataNFT _metadataNFT) internal {
		metadataNFT = _metadataNFT;
		emit MetadataNFTUpdated(_metadataNFT);
	}

	function setInterestRate(uint256 _interestRate) external onlyOwner {
		accrueInterests();
		_setInterestRate(_interestRate);
	}

	function _setInterestRate(uint256 _interestRate) internal {
		interestRate = _interestRate;
		emit InterestRateUpdated(_interestRate);
	}

	function setMaxSystemDebt(uint256 _cap) external onlyOwner {
		_setMaxSystemDebt(_cap);
	}

	function _setMaxSystemDebt(uint256 _cap) internal {
		maxSystemDebt = _cap;
		emit MaxSystemDebtUpdated(_cap);
	}

	function setSPYielPCT(uint256 _spYielPCT) external onlyOwner {
		accrueInterests();
		_setSPYielPCT(_spYielPCT);
	}

	function _setSPYielPCT(uint256 _spYielPCT) internal {
		require(_spYielPCT <= DECIMAL_PRECISION, "TM: SP yield pct too high");
		SP_YIELD_PCT = _spYielPCT;
		emit SPYieldPCTUpdated(_spYielPCT);
	}

	function setLiquidationPenaltySP(uint256 _penaltySP) external onlyOwner {
		_setLiquidationPenaltySP(_penaltySP);
	}

	function _setLiquidationPenaltySP(uint256 _penaltySP) internal {
		LIQUIDATION_PENALTY_SP = _penaltySP;
		emit LIQUIDATION_PENALTY_SP_Updated(_penaltySP);
	}

	function setLiquidationPenaltyRedist(uint256 _penaltyRedist) external onlyOwner {
		_setLiquidationPenaltyRedist(_penaltyRedist);
	}

	function _setLiquidationPenaltyRedist(uint256 _penaltyRedist) internal {
		LIQUIDATION_PENALTY_REDISTRIBUTION = _penaltyRedist;
		emit LIQUIDATION_PENALTY_REDISTRIBUTION_Updated(_penaltyRedist);
	}

	function setMaxCollGasCompensation(uint256 _maxCollGasCompensation) external onlyOwner {
		_setMaxCollGasCompensation(_maxCollGasCompensation);
	}

	function _setMaxCollGasCompensation(uint256 _maxCollGasCompensation) internal {
		MAX_COLL_GAS_COMPENSATION = _maxCollGasCompensation;
		emit MAX_COLL_GAS_COMPENSATION_Updated(_maxCollGasCompensation);
	}

	function fetchPrice() public returns (uint256) {
		return priceFeed.fetchPrice(address(collateralToken));
	}

	function troveExists(uint256 id) external view returns (bool) {
		return _exists(id);
	}

	function tokenURI(uint256 id) public view override returns (string memory) {
		Trove memory t = getCurrentTrove(id);
		return metadataNFT.uri(IMetadataNFT.TroveData({ tokenId: id, owner: ownerOf(id), collToken: collateralToken, debtToken: debtToken, collAmount: t.coll, debtAmount: t.debt, interest: t.interest }));
	}

	function getTroveStake(uint256 id) external view returns (uint256) {
		return Troves[id].stake;
	}

	function getEntireSystemColl() public view returns (uint256) {
		return totalActiveCollateral + defaultedCollateral - lastCollateralError_Redistribution / DECIMAL_PRECISION;
	}

	function getEntireSystemDebt() public view returns (uint256) {
		return totalActiveDebt + defaultedDebt - lastDebtError_Redistribution / DECIMAL_PRECISION;
	}

	function getEntireSystemInterest() public view returns (uint256) {
		return totalActiveInterest + defaultedInterest - lastDefaultedInterestError_Redistribution / DECIMAL_PRECISION;
	}

	function getEntireSystemBalances() external returns (uint256 coll, uint256 debt, uint256 interest, uint256 price) {
		return (getEntireSystemColl(), getEntireSystemDebt(), getEntireSystemInterest(), fetchPrice());
	}

	function getTCR() public returns (uint256) {
		accrueInterests();
		return YalaMath._computeCR(getEntireSystemColl(), getEntireSystemDebt() + getEntireSystemInterest(), fetchPrice());
	}

	function getTotalActiveCollateral() public view returns (uint256) {
		return totalActiveCollateral;
	}

	function getPendingRewards(uint256 id) public view returns (uint256, uint256, uint256) {
		RewardSnapshot memory snapshot = rewardSnapshots[id];
		uint256 coll = L_collateral - snapshot.collateral;
		uint256 debt = L_debt - snapshot.debt;
		uint256 defaulted = L_defaulted_interest - snapshot.defaultedInterest;
		if (coll + debt + defaulted == 0 || !_exists(id)) return (0, 0, 0);
		uint256 stake = Troves[id].stake;
		return ((stake * coll) / DECIMAL_PRECISION, (stake * debt) / DECIMAL_PRECISION, (stake * defaulted) / DECIMAL_PRECISION);
	}

	function openTrove(address owner, uint256 _collateralAmount, uint256 _compositeDebt) external whenNotPaused whenNotShutdown returns (uint256 id) {
		_requireCallerIsBO();
		uint256 supply = totalActiveDebt;
		id = nonce++;
		Trove storage t = Troves[id];
		_mint(owner, id);
		t.coll = _collateralAmount;
		t.debt = _compositeDebt;
		_updateTroveRewardSnapshots(id);
		uint256 stake = _updateStakeAndTotalStakes(t);
		totalActiveCollateral = totalActiveCollateral + _collateralAmount;
		uint256 _newTotalDebt = supply + _compositeDebt;
		require(_newTotalDebt + defaultedDebt <= maxSystemDebt, "TM: Collateral debt limit reached");
		totalActiveDebt = _newTotalDebt;
		emit TroveOpened(id, owner, _collateralAmount, _compositeDebt, stake);
	}

	function updateTroveFromAdjustment(uint256 id, bool _isDebtIncrease, uint256 _debtChange, bool _isCollIncrease, uint256 _collChange, uint256 _interestRepayment, address _receiver) external whenNotPaused whenNotShutdown returns (uint256, uint256, uint256, uint256) {
		_requireCallerIsBO();
		require(!paused, "TM: Collateral Paused");
		require(_exists(id), "TM: Nonexistent trove");
		LocalTroveUpdateVariables memory vars = LocalTroveUpdateVariables(id, _debtChange, _collChange, _interestRepayment, _isCollIncrease, _isDebtIncrease, _receiver);
		Trove storage t = Troves[vars.id];
		uint256 newDebt = t.debt;
		uint256 newInterest = t.interest;
		if (vars.debtChange > 0 || vars.interestRepayment > 0) {
			if (vars.isDebtIncrease) {
				newDebt = newDebt + vars.debtChange;
				_increaseDebt(vars.receiver, vars.debtChange);
			} else {
				newDebt = newDebt - vars.debtChange;
				_decreaseDebt(vars.receiver, vars.debtChange);
				newInterest -= vars.interestRepayment;
				_decreaseInterest(vars.receiver, vars.interestRepayment);
			}
			t.debt = newDebt;
			t.interest = newInterest;
		}

		uint256 newColl = t.coll;
		if (vars.collChange > 0) {
			if (vars.isCollIncrease) {
				newColl = newColl + vars.collChange;
				totalActiveCollateral = totalActiveCollateral + vars.collChange;
			} else {
				newColl = newColl - vars.collChange;
				_sendCollateral(vars.receiver, vars.collChange);
			}
			t.coll = newColl;
		}
		uint256 newStake = _updateStakeAndTotalStakes(t);
		emit TroveUpdated(vars.id, newColl, newDebt, newStake, newInterest, vars.receiver, TroveManagerOperation.adjust);
		return (newColl, newDebt, newInterest, newStake);
	}

	function batchLiquidate(uint256[] memory ids) external whenNotPaused whenNotShutdown {
		uint256 price = fetchPrice();
		LiquidationValues memory totals;
		totals.remainingDeposits = stabilityPool.getTotalDeposits();
		for (uint256 i = 0; i < ids.length; i++) {
			uint256 id = ids[i];
			SingleLiquidation memory singleLiquidation;
			(singleLiquidation.coll, singleLiquidation.debt, singleLiquidation.interest) = applyPendingRewards(id);
			_liquidate(id, totals, singleLiquidation, price);
		}
		require(totalSupply() > 0, "TM: at least one trove to redistribute coll and debt");
		require(totals.debtGasCompensation > 0, "TM: nothing to liquidate");
		totals.interestOffset = YalaMath._min(totalActiveInterest, totals.interestOffset);
		totalActiveInterest = totalActiveInterest - totals.interestOffset;
		totalActiveDebt = totalActiveDebt - totals.debtOffset;
		uint256 totalOffset = totals.debtOffset + totals.interestOffset;
		if (totalOffset > 0) {
			_sendCollateral(address(stabilityPool), totals.collOffset);
			debtToken.burn(address(stabilityPool), totalOffset);
			stabilityPool.offset(totalOffset, totals.collOffset);
		}
		_redistribute(totals.collRedist, totals.debtRedist, totals.interestRedist);
		totalActiveCollateral = totalActiveCollateral - totals.collSurplus;
		totalCollateralSnapshot = totalActiveCollateral - totals.collGasCompensation + defaultedCollateral;
		totalStakesSnapshot = totalStakes;
		debtToken.returnFromPool(gasPoolAddress, msg.sender, totals.debtGasCompensation);
		_sendCollateral(msg.sender, totals.collGasCompensation);
	}

	function claimCollSurplus(address account, uint256 _amount) external {
		require(accountCollSurplus[account] >= _amount, "TM: insufficient coll surplus");
		accountCollSurplus[account] -= _amount;
		collateralToken.safeTransfer(account, _amount);
		emit CollSurplusClaimed(account, _amount);
	}

	function _getCollGasCompensation(uint256 _entireColl) internal view returns (uint256) {
		return YalaMath._min(_entireColl / COLL_GAS_COMPENSATION_DIVISOR, MAX_COLL_GAS_COMPENSATION);
	}

	function _accrueGasCompensation(LiquidationValues memory totals, SingleLiquidation memory singleLiquidation) internal view {
		singleLiquidation.debtGasCompensation = DEBT_GAS_COMPENSATION;
		totals.debtGasCompensation += singleLiquidation.debtGasCompensation;
		singleLiquidation.collGasCompensation = _getCollGasCompensation(singleLiquidation.coll);
		totals.collGasCompensation += singleLiquidation.collGasCompensation;
		singleLiquidation.collToLiquidate = singleLiquidation.coll - singleLiquidation.collGasCompensation;
	}

	function _liquidatePenalty(LiquidationValues memory totals, SingleLiquidation memory singleLiquidation, uint256 _price) internal view {
		uint256 collSPPortion;
		if (totals.remainingDeposits > 0) {
			singleLiquidation.debtOffset = YalaMath._min(singleLiquidation.debt, totals.remainingDeposits);
			totals.remainingDeposits -= singleLiquidation.debtOffset;
			if (totals.remainingDeposits > 0) {
				singleLiquidation.interestOffset = YalaMath._min(singleLiquidation.interest, totals.remainingDeposits);
				totals.remainingDeposits -= singleLiquidation.interestOffset;
			}
			collSPPortion = (singleLiquidation.collToLiquidate * (singleLiquidation.debtOffset + singleLiquidation.interestOffset)) / (singleLiquidation.debt + singleLiquidation.interest);
			(singleLiquidation.collOffset, singleLiquidation.collSurplus) = _getCollPenaltyAndSurplus(collSPPortion, singleLiquidation.debtOffset + singleLiquidation.interestOffset, LIQUIDATION_PENALTY_SP, _price);
		}
		// Redistribution
		singleLiquidation.debtRedist = singleLiquidation.debt - singleLiquidation.debtOffset;
		singleLiquidation.interestRedist = singleLiquidation.interest - singleLiquidation.interestOffset;
		if (singleLiquidation.debtRedist > 0 || singleLiquidation.interestRedist > 0) {
			uint256 collRedistPortion = singleLiquidation.collToLiquidate - collSPPortion;
			if (collRedistPortion > 0) {
				(singleLiquidation.collRedist, singleLiquidation.collSurplus) = _getCollPenaltyAndSurplus(
					collRedistPortion + singleLiquidation.collSurplus, // Coll surplus from offset can be eaten up by red. penalty
					singleLiquidation.debtRedist + singleLiquidation.interestRedist,
					LIQUIDATION_PENALTY_REDISTRIBUTION, // _penaltyRatio
					_price
				);
			}
		}
		totals.debtOffset += singleLiquidation.debtOffset;
		totals.debtRedist += singleLiquidation.debtRedist;
		totals.collOffset += singleLiquidation.collOffset;
		totals.collRedist += singleLiquidation.collRedist;
		totals.interestOffset += singleLiquidation.interestOffset;
		totals.interestRedist += singleLiquidation.interestRedist;
		// assert(singleLiquidation.collToLiquidate == singleLiquidation.collOffset + singleLiquidation.collRedist + singleLiquidation.collSurplus);
	}

	function _getCollPenaltyAndSurplus(uint256 _collToLiquidate, uint256 _debt, uint256 _penaltyRatio, uint256 _price) internal pure returns (uint256 seizedColl, uint256 collSurplus) {
		uint256 maxSeizedColl = (_debt * (DECIMAL_PRECISION + _penaltyRatio)) / _price;
		if (_collToLiquidate > maxSeizedColl) {
			seizedColl = maxSeizedColl;
			collSurplus = _collToLiquidate - maxSeizedColl;
		} else {
			seizedColl = _collToLiquidate;
			collSurplus = 0;
		}
	}

	function _liquidate(uint256 id, LiquidationValues memory totals, SingleLiquidation memory singleLiquidation, uint256 price) internal {
		uint256 entireDebt = singleLiquidation.debt + singleLiquidation.interest;
		uint256 ICR = YalaMath._computeCR(singleLiquidation.coll, entireDebt, price);
		if (ICR < MCR) {
			_accrueGasCompensation(totals, singleLiquidation);
			_liquidatePenalty(totals, singleLiquidation, price);
			address owner = ownerOf(id);
			if (singleLiquidation.collSurplus > 0) {
				accountCollSurplus[owner] += singleLiquidation.collSurplus;
				totals.collSurplus = totals.collSurplus + singleLiquidation.collSurplus;
			}
			_closeTrove(id);
			emit Liquidated(owner, id, singleLiquidation.coll, singleLiquidation.debt, singleLiquidation.interest, singleLiquidation.collSurplus);
		}
	}

	function closeTrove(uint256 id, address _receiver, uint256 collAmount, uint256 debtAmount, uint256 interest) external {
		_requireCallerIsBO();
		require(_exists(id), "TM: nonexistent trove");
		totalActiveDebt = totalActiveDebt - debtAmount;
		totalActiveInterest = totalActiveInterest - interest;
		_sendCollateral(_receiver, collAmount);
		_removeStake(id);
		_closeTrove(id);
		_resetState();
	}

	function _resetState() private {
		if (totalSupply() == 0) {
			totalStakes = 0;
			totalStakesSnapshot = 0;
			totalCollateralSnapshot = 0;
			L_collateral = 0;
			L_debt = 0;
			L_defaulted_interest = 0;
			L_active_interest = 0;
			lastCollateralError_Redistribution = 0;
			lastDebtError_Redistribution = 0;
			lastActiveInterestError_Redistribution = 0;
			lastDefaultedInterestError_Redistribution = 0;
			totalActiveCollateral = 0;
			totalActiveDebt = 0;
			totalActiveInterest = 0;
			defaultedCollateral = 0;
			defaultedDebt = 0;
			defaultedInterest = 0;
			lastInterestUpdate = 0;
			nonce = 0;
		}
	}

	// This function must be called any time the debt or the interest changes
	function accrueInterests() public returns (uint256 yieldSP, uint256 yieldFee) {
		(uint256 applicable, uint256 mintAmount) = getPendingInterest();
		lastInterestUpdate = applicable;
		if (mintAmount > 0) {
			uint256 interestNumerator = (mintAmount * DECIMAL_PRECISION) + lastActiveInterestError_Redistribution;
			uint256 interestRewardPerUnit = interestNumerator / totalActiveDebt;
			lastActiveInterestError_Redistribution = interestNumerator - totalActiveDebt * interestRewardPerUnit;
			L_active_interest += interestRewardPerUnit;
			yieldFee = (totalActiveDebt * interestRewardPerUnit) / DECIMAL_PRECISION;
			totalActiveInterest += yieldFee;
			if (SP_YIELD_PCT > 0 && stabilityPool.getTotalDeposits() >= DECIMAL_PRECISION) {
				yieldSP = (yieldFee * SP_YIELD_PCT) / DECIMAL_PRECISION;
				yieldFee -= yieldSP;
				debtToken.mint(address(stabilityPool), yieldSP);
				stabilityPool.triggerSPYield(yieldSP);
				emit SPYieldAccrued(yieldSP);
			}
			debtToken.mint(YALA_CORE.feeReceiver(), yieldFee);
			emit InterestAccrued(yieldFee);
		}
	}

	function _accrueTroveInterest(uint256 id) internal returns (uint256 total, uint256 accrued) {
		accrueInterests();
		Trove storage t = Troves[id];
		if (rewardSnapshots[id].activeInterest < L_active_interest) {
			accrued = ((L_active_interest - rewardSnapshots[id].activeInterest) * t.debt) / DECIMAL_PRECISION;
			t.interest += accrued;
		}
		total = t.interest;
	}

	function getPendingInterest() public view returns (uint256 applicable, uint256 amount) {
		applicable = hasShutdown() ? shutdownAt : block.timestamp;
		if (lastInterestUpdate == 0 || lastInterestUpdate == applicable) {
			return (applicable, amount);
		}
		uint256 diff = applicable - lastInterestUpdate;
		if (diff == 0) {
			return (applicable, amount);
		}
		if (diff > 0) {
			amount = (totalActiveDebt * diff * interestRate) / SECONDS_IN_YEAR / DECIMAL_PRECISION;
		}
		return (applicable, amount);
	}

	function getPendingYieldSP() public view returns (uint256) {
		if (SP_YIELD_PCT == 0 || stabilityPool.getTotalDeposits() < DECIMAL_PRECISION) {
			return 0;
		}
		(, uint256 amount) = getPendingInterest();
		return (amount * SP_YIELD_PCT) / DECIMAL_PRECISION;
	}

	function getCurrentICR(uint256 id, uint256 price) public view returns (uint256) {
		Trove memory trove = getCurrentTrove(id);
		return YalaMath._computeCR(trove.coll, trove.debt + trove.interest, price);
	}

	function getCurrentTrove(uint256 id) public view returns (Trove memory) {
		require(_exists(id), "TM: nonexistent trove");
		(, uint256 mintAmount) = getPendingInterest();
		uint256 interestNumerator = (mintAmount * DECIMAL_PRECISION) + lastActiveInterestError_Redistribution;
		uint256 interestRewardPerUnit = interestNumerator / totalActiveDebt;
		uint256 new_L_active_interest = L_active_interest + interestRewardPerUnit;
		RewardSnapshot memory snapshot = rewardSnapshots[id];
		Trove memory t = Troves[id];
		uint256 interest = ((new_L_active_interest - rewardSnapshots[id].activeInterest) * t.debt) / DECIMAL_PRECISION;
		uint256 coll = L_collateral - snapshot.collateral;
		uint256 debt = L_debt - snapshot.debt;
		uint256 defaulted = L_defaulted_interest - snapshot.defaultedInterest;
		uint256 stake = t.stake;
		(uint256 pendingColl, uint256 pendingDebt, uint256 pendingInterest) = ((stake * coll) / DECIMAL_PRECISION, (stake * debt) / DECIMAL_PRECISION, (stake * defaulted) / DECIMAL_PRECISION);
		interest += pendingInterest;
		return Trove({ coll: t.coll + pendingColl, debt: t.debt + pendingDebt, stake: t.stake, interest: t.interest + interest });
	}

	function _closeTrove(uint256 id) internal {
		totalStakes -= Troves[id].stake;
		delete Troves[id];
		delete rewardSnapshots[id];
		_burn(id);
		emit TroveClosed(id);
	}

	function applyPendingRewards(uint256 id) public returns (uint256 coll, uint256 debt, uint256 interest) {
		Trove storage t = Troves[id];
		if (_exists(id)) {
			debt = t.debt;
			coll = t.coll;
			(interest, ) = _accrueTroveInterest(id);
			if (rewardSnapshots[id].collateral < L_collateral || rewardSnapshots[id].debt < L_debt || rewardSnapshots[id].defaultedInterest < L_defaulted_interest) {
				// Compute pending rewards
				(uint256 pendingCollateralReward, uint256 pendingDebtReward, uint256 pendingDefaultedInterest) = getPendingRewards(id);
				// Apply pending rewards to trove's state
				coll = coll + pendingCollateralReward;
				t.coll = coll;
				debt = debt + pendingDebtReward;
				t.debt = debt;
				interest = interest + pendingDefaultedInterest;
				_movePendingTroveRewardsToActiveBalance(pendingDebtReward, pendingCollateralReward, pendingDefaultedInterest);
			}
			t.interest = YalaMath._min(totalActiveInterest, interest);
			_updateTroveRewardSnapshots(id);
		}
		return (coll, debt, t.interest);
	}

	function _updateTroveRewardSnapshots(uint256 id) internal {
		rewardSnapshots[id].collateral = L_collateral;
		rewardSnapshots[id].debt = L_debt;
		rewardSnapshots[id].activeInterest = L_active_interest;
		rewardSnapshots[id].defaultedInterest = L_defaulted_interest;
	}

	// Remove borrower's stake from the totalStakes sum, and set their stake to 0
	function _removeStake(uint256 id) internal {
		uint256 stake = Troves[id].stake;
		totalStakes = totalStakes - stake;
		Troves[id].stake = 0;
	}

	// Update borrower's stake based on their latest collateral value
	function _updateStakeAndTotalStakes(Trove storage t) internal returns (uint256) {
		uint256 newStake = _computeNewStake(t.coll);
		uint256 oldStake = t.stake;
		t.stake = newStake;
		uint256 newTotalStakes = totalStakes - oldStake + newStake;
		totalStakes = newTotalStakes;
		emit TotalStakesUpdated(newTotalStakes);

		return newStake;
	}

	// Calculate a new stake based on the snapshots of the totalStakes and totalCollateral taken at the last liquidation
	function _computeNewStake(uint256 _coll) internal view returns (uint256) {
		uint256 stake;
		if (totalCollateralSnapshot == 0) {
			stake = _coll;
		} else {
			/*
			 * The following assert() holds true because:
			 * - The system always contains >= 1 trove
			 * - When we close or liquidate a trove, we redistribute the pending rewards, so if all troves were closed/liquidated,
			 * rewards would’ve been emptied and totalCollateralSnapshot would be zero too.
			 */
			stake = (_coll * totalStakesSnapshot) / totalCollateralSnapshot;
		}
		return stake;
	}

	function _movePendingTroveRewardsToActiveBalance(uint256 _debt, uint256 _collateral, uint256 _defaultedInterest) internal {
		defaultedDebt -= _debt;
		totalActiveDebt += _debt;
		defaultedCollateral -= _collateral;
		totalActiveCollateral += _collateral;
		defaultedInterest -= _defaultedInterest;
		totalActiveInterest += _defaultedInterest;
	}

	function _redistribute(uint256 _coll, uint256 _debt, uint256 _interest) internal {
		if (_debt == 0 && _interest == 0) {
			return;
		}
		/*
		 * Add distributed coll and debt rewards-per-unit-staked to the running totals. Division uses a "feedback"
		 * error correction, to keep the cumulative error low in the running totals L_collateral and L_debt:
		 *
		 * 1) Form numerators which compensate for the floor division errors that occurred the last time this
		 * function was called.
		 * 2) Calculate "per-unit-staked" ratios.
		 * 3) Multiply each ratio back by its denominator, to reveal the current floor division error.
		 * 4) Store these errors for use in the next correction when this function is called.
		 * 5) Note: static analysis tools complain about this "division before multiplication", however, it is intended.
		 */
		uint256 collateralNumerator = (_coll * DECIMAL_PRECISION) + lastCollateralError_Redistribution;
		uint256 debtNumerator = (_debt * DECIMAL_PRECISION) + lastDebtError_Redistribution;
		uint256 interestNumerator = (_interest * DECIMAL_PRECISION) + lastDefaultedInterestError_Redistribution;
		uint256 totalStakesCached = totalStakes;
		// Get the per-unit-staked terms
		uint256 collateralRewardPerUnitStaked = collateralNumerator / totalStakesCached;
		uint256 debtRewardPerUnitStaked = debtNumerator / totalStakesCached;
		uint256 defaultedInterestRewardPerUnitStaked = interestNumerator / totalStakesCached;

		lastCollateralError_Redistribution = collateralNumerator - (collateralRewardPerUnitStaked * totalStakesCached);
		lastDebtError_Redistribution = debtNumerator - (debtRewardPerUnitStaked * totalStakesCached);
		lastDefaultedInterestError_Redistribution = interestNumerator - (defaultedInterestRewardPerUnitStaked * totalStakesCached);
		// Add per-unit-staked terms to the running totals
		uint256 new_L_collateral = L_collateral + collateralRewardPerUnitStaked;
		uint256 new_L_debt = L_debt + debtRewardPerUnitStaked;
		uint256 new_L_defaulted_interest = L_defaulted_interest + defaultedInterestRewardPerUnitStaked;

		L_collateral = new_L_collateral;
		L_debt = new_L_debt;
		L_defaulted_interest = new_L_defaulted_interest;
		emit LTermsUpdated(new_L_collateral, new_L_debt, new_L_defaulted_interest);

		totalActiveDebt -= _debt;
		defaultedDebt += _debt;
		defaultedCollateral += _coll;
		totalActiveCollateral -= _coll;
		totalActiveInterest -= _interest;
		defaultedInterest += _interest;
	}

	function _sendCollateral(address _account, uint256 _amount) private {
		if (_amount > 0) {
			totalActiveCollateral = totalActiveCollateral - _amount;
			collateralToken.safeTransfer(_account, _amount);
			emit CollateralSent(_account, _amount);
		}
	}

	function _increaseDebt(address account, uint256 debtAmount) internal {
		uint256 _newTotalDebt = totalActiveDebt + debtAmount;
		require(_newTotalDebt + defaultedDebt <= maxSystemDebt, "Collateral debt limit reached");
		totalActiveDebt = _newTotalDebt;
		debtToken.mint(account, debtAmount);
	}

	function _decreaseDebt(address account, uint256 amount) internal {
		debtToken.burn(account, amount);
		totalActiveDebt = totalActiveDebt - amount;
	}

	function _decreaseInterest(address account, uint256 amount) internal {
		debtToken.burn(account, amount);
		totalActiveInterest = totalActiveInterest - amount;
	}

	function hasShutdown() public view returns (bool) {
		return shutdownAt != 0;
	}

	function _requireCallerIsBO() internal view {
		require(msg.sender == borrowerOperationsAddress, "Caller not BO");
	}
}
