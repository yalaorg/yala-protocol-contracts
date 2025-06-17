// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";

import "../dependencies/YalaOwnable.sol";
import "../dependencies/YalaMath.sol";
import "../dependencies/EnumerableCollateral.sol";
import "../interfaces/IDebtToken.sol";
import "../interfaces/ITroveManager.sol";
import "../interfaces/IStabilityPool.sol";

/**
    @title Yala Stability Pool
    @notice Based on Liquity's `StabilityPool`
            https://github.com/liquity/dev/blob/main/packages/contracts/contracts/StabilityPool.sol

            Yala's implementation is modified to support multiple collaterals. Deposits into
            the stability pool may be used to liquidate any supported collateral type.
 */
contract StabilityPool is IStabilityPool, Multicall, ReentrancyGuard, YalaOwnable {
	using SafeERC20 for IERC20;
	using EnumerableCollateral for EnumerableCollateral.TroveManagerToCollateral;

	uint256 public constant DECIMAL_PRECISION = 1e18;
	IDebtToken public immutable debtToken;
	address public immutable factory;
	uint256 internal totalDebtTokenDeposits;
	uint8 internal constant TARGET_DIGITS = 18;

	/*  Product 'P': Running product by which to multiply an initial deposit, in order to find the current compounded deposit,
	 * after a series of liquidations have occurred, each of which cancel some debt with the deposit.
	 *
	 * During its lifetime, a deposit's value evolves from d_t to d_t * P / P_t , where P_t
	 * is the snapshot of P taken at the instant the deposit was made. 18 decimal.
	 */
	uint256 public P = DECIMAL_PRECISION;

	uint256 public constant SCALE_FACTOR = 1e9;

	// Each time the scale of P shifts by SCALE_FACTOR, the scale is incremented by 1
	uint128 public currentScale;

	// With each offset that fully empties the Pool, the epoch is incremented by 1
	uint128 public currentEpoch;

	uint256 public yieldGainsPending;
	uint256 public lastDebtLossErrorByP_Offset;
	uint256 public lastDebtLossError_TotalDeposits;
	uint256 public lastYieldError;

	EnumerableCollateral.TroveManagerToCollateral internal collateralTokens;

	// Error trackers for the error correction in the offset calculation
	mapping(IERC20 => uint256) public lastCollateralError_Offset;
	mapping(IERC20 => uint8) public collateralDecimals;
	mapping(address => AccountDeposit) public accountDeposits; // depositor address -> initial deposit
	mapping(address => Snapshots) public depositSnapshots; // depositor address -> snapshots struct

	// index values are mapped against the values within `collateralTokens`
	mapping(address => mapping(IERC20 => uint256)) public depositSums; // depositor address -> sums

	mapping(address => mapping(IERC20 => uint256)) public collateralGainsByDepositor;

	mapping(address => uint256) public storedPendingYield;

	/* collateral Gain sum 'S': During its lifetime, each deposit d_t earns a collateral gain of ( d_t * [S - S_t] )/P_t, where S_t
	 * is the depositor's snapshot of S taken at the time t when the deposit was made.
	 *
	 * The 'S' sums are stored in a nested mapping (epoch => scale => sum):
	 *
	 * - The inner mapping records the sum S at different scales
	 * - The outer mapping records the (scale => sum) mappings, for different epochs.
	 */
	mapping(uint128 => mapping(uint128 => mapping(IERC20 => uint256))) public epochToScaleToSums;

	/*
	 * Similarly, the sum 'G' is used to calculate yield gains. During it's lifetime, each deposit d_t earns a yield gain of
	 *  ( d_t * [G - G_t] )/P_t, where G_t is the depositor's snapshot of G taken at time t when  the deposit was made.
	 *
	 *  Yala reward events occur are triggered by depositor operations (new deposit, topup, withdrawal), and liquidations.
	 *  In each case, the Yala reward is issued (i.e. G is updated), before other state changes are made.
	 */
	mapping(uint128 => mapping(uint128 => uint256)) public epochToScaleToG;

	constructor(address _yalaCore, address _factory, IDebtToken _debtTokenAddress) YalaOwnable(_yalaCore) {
		factory = _factory;
		debtToken = _debtTokenAddress;
	}

	function enableTroveManager(address troveManager) external {
		require(msg.sender == factory, "StabilityPool: Not factory");
		IERC20 token = ITroveManager(troveManager).collateralToken();
		collateralTokens.set(troveManager, token);
		collateralDecimals[token] = IERC20Metadata(address(token)).decimals();
	}

	function provideToSP(uint256 _amount) external nonReentrant {
		require(!YALA_CORE.paused(), "StabilityPool: Deposits are paused");
		require(_amount > 0, "StabilityPool: Amount must be non-zero");
		uint256 initialDeposit = accountDeposits[msg.sender].amount;
		_accrueRewards(msg.sender, initialDeposit);
		uint256 compoundedDebtDeposit = _getCompoundedDebtDeposit(msg.sender, initialDeposit);
		debtToken.sendToSP(msg.sender, _amount);
		uint256 newTotalDebtTokenDeposits = totalDebtTokenDeposits + _amount;
		totalDebtTokenDeposits = newTotalDebtTokenDeposits;
		emit StabilityPoolDebtBalanceUpdated(newTotalDebtTokenDeposits);

		uint256 newDeposit = compoundedDebtDeposit + _amount;
		accountDeposits[msg.sender] = AccountDeposit({ amount: uint128(newDeposit), timestamp: uint128(block.timestamp) });
		_updateSnapshots(msg.sender, newDeposit);
		emit Deposit(msg.sender, newDeposit, _amount);
	}

	function withdrawFromSP(uint256 _amount) external nonReentrant {
		uint256 initialDeposit = accountDeposits[msg.sender].amount;
		uint128 depositTimestamp = accountDeposits[msg.sender].timestamp;
		require(initialDeposit > 0, "StabilityPool: User must have a non-zero deposit");
		require(depositTimestamp < block.timestamp, "StabilityPool: !Deposit and withdraw same block");
		_accrueRewards(msg.sender, initialDeposit);
		uint256 compoundedDebtDeposit = YalaMath._min(totalDebtTokenDeposits, _getCompoundedDebtDeposit(msg.sender, initialDeposit));
		uint256 debtToWithdraw = YalaMath._min(_amount, compoundedDebtDeposit);
		uint256 newDeposit = compoundedDebtDeposit - debtToWithdraw;
		accountDeposits[msg.sender] = AccountDeposit({ amount: uint128(newDeposit), timestamp: depositTimestamp });
		if (debtToWithdraw > 0) {
			debtToWithdraw = YalaMath._min(debtToken.balanceOf(address(this)), debtToWithdraw);
			debtToken.returnFromPool(address(this), msg.sender, debtToWithdraw);
			_decreaseDebt(debtToWithdraw);
		}
		_updateSnapshots(msg.sender, newDeposit);
		emit Withdraw(msg.sender, newDeposit, debtToWithdraw);
	}

	/*
	 * Cancels out the specified debt against the Debt contained in the Stability Pool (as far as possible)
	 */
	function offset(uint256 _debtToOffset, uint256 _collToAdd) external {
		IERC20 collateral = collateralTokens.get(msg.sender);
		require(address(collateral) != address(0), "StabilityPool: nonexistent collateral");
		_accrueAllYieldGains();
		_collToAdd = _computeCollateralAmount(collateral, _collToAdd);
		_offset(collateral, _debtToOffset, _collToAdd);
	}

	function _offset(IERC20 collateral, uint256 _debtToOffset, uint256 _collToAdd) internal {
		uint256 totalDebt = totalDebtTokenDeposits; // cached to save an SLOAD
		if (totalDebt == 0 || _debtToOffset == 0) {
			return;
		}
		_updateCollRewardSumAndProduct(collateral, _collToAdd, _debtToOffset, totalDebt); // updates S and P
		// Cancel the liquidated Debt debt with the Debt in the stability pool
		_decreaseDebt(_debtToOffset);
	}

	function _computeCollRewardsPerUnitStaked(IERC20 collateral, uint256 _collToAdd, uint256 _debtToOffset, uint256 _totalDebtDeposits) internal returns (uint256 collGainPerUnitStaked, uint256 debtLossPerUnitStaked, uint256 newLastDebtLossErrorOffset) {
		/*
		 * Compute the Debt and Coll rewards. Uses a "feedback" error correction, to keep
		 * the cumulative error in the P and S state variables low:
		 *
		 * 1) Form numerators which compensate for the floor division errors that occurred the last time this
		 * function was called.
		 * 2) Calculate "per-unit-staked" ratios.
		 * 3) Multiply each ratio back by its denominator, to reveal the current floor division error.
		 * 4) Store these errors for use in the next correction when this function is called.
		 * 5) Note: static analysis tools complain about this "division before multiplication", however, it is intended.
		 */
		uint256 collNumerator = _collToAdd * DECIMAL_PRECISION + lastCollateralError_Offset[collateral];

		assert(_debtToOffset <= _totalDebtDeposits);
		if (_debtToOffset == _totalDebtDeposits) {
			debtLossPerUnitStaked = DECIMAL_PRECISION; // When the Pool depletes to 0, so does each deposit
			newLastDebtLossErrorOffset = 0;
		} else {
			uint256 debtLossNumerator = _debtToOffset * DECIMAL_PRECISION;
			/*
			 * Add 1 to make error in quotient positive. We want "slightly too much" Debt loss,
			 * which ensures the error in any given compoundedDebtDeposit favors the Stability Pool.
			 */
			debtLossPerUnitStaked = debtLossNumerator / _totalDebtDeposits + 1;
			newLastDebtLossErrorOffset = debtLossPerUnitStaked * _totalDebtDeposits - debtLossNumerator;
		}

		collGainPerUnitStaked = collNumerator / _totalDebtDeposits;
		lastCollateralError_Offset[collateral] = collNumerator - collGainPerUnitStaked * _totalDebtDeposits;
		return (collGainPerUnitStaked, debtLossPerUnitStaked, newLastDebtLossErrorOffset);
	}

	// Update the Stability Pool reward sum S and product P
	function _updateCollRewardSumAndProduct(IERC20 collateral, uint256 _collToAdd, uint256 _debtToOffset, uint256 _totalDeposits) internal {
		(uint256 collGainPerUnitStaked, uint256 debtLossPerUnitStaked, uint256 newLastDebtLossErrorOffset) = _computeCollRewardsPerUnitStaked(collateral, _collToAdd, _debtToOffset, _totalDeposits);

		uint256 currentP = P;
		uint256 newP;

		assert(debtLossPerUnitStaked <= DECIMAL_PRECISION);
		/*
		 * The newProductFactor is the factor by which to change all deposits, due to the depletion of Stability Pool Debt in the liquidation.
		 * We make the product factor 0 if there was a pool-emptying. Otherwise, it is (1 - debtLossPerUnitStaked)
		 */
		uint256 newProductFactor = uint256(DECIMAL_PRECISION) - debtLossPerUnitStaked;

		uint128 currentScaleCached = currentScale;
		uint128 currentEpochCached = currentEpoch;
		uint256 currentS = epochToScaleToSums[currentEpochCached][currentScaleCached][collateral];

		/*
		 * Calculate the new S first, before we update P.
		 * The Coll gain for any given depositor from a liquidation depends on the value of their deposit
		 * (and the value of totalDeposits) prior to the Stability being depleted by the debt in the liquidation.
		 *
		 * Since S corresponds to Coll gain, and P to deposit loss, we update S first.
		 */
		IERC20 collateralCached = collateral;
		uint256 marginalCollGain = collGainPerUnitStaked * (currentP - 1);
		uint256 newS = currentS + marginalCollGain;
		epochToScaleToSums[currentEpochCached][currentScaleCached][collateralCached] = newS;
		emit S_Updated(collateralCached, newS, currentEpochCached, currentScaleCached);

		// If the Stability Pool was emptied, increment the epoch, and reset the scale and product P
		if (newProductFactor == 0) {
			currentEpoch = currentEpochCached + 1;
			emit EpochUpdated(currentEpoch);
			currentScale = 0;
			emit ScaleUpdated(currentScale);
			newP = DECIMAL_PRECISION;
		} else {
			uint256 lastDebtLossErrorByP_Offset_Cached = lastDebtLossErrorByP_Offset;
			uint256 lastDebtLossError_TotalDeposits_Cached = lastDebtLossError_TotalDeposits;
			newP = _getNewPByScale(currentP, newProductFactor, lastDebtLossErrorByP_Offset_Cached, lastDebtLossError_TotalDeposits_Cached, 1);

			// If multiplying P by a non-zero product factor would reduce P below the scale boundary, increment the scale
			if (newP < SCALE_FACTOR) {
				newP = _getNewPByScale(currentP, newProductFactor, lastDebtLossErrorByP_Offset_Cached, lastDebtLossError_TotalDeposits_Cached, SCALE_FACTOR);
				currentScale = currentScaleCached + 1;

				// Increment the scale again if it's still below the boundary. This ensures the invariant P >= 1e9 holds and
				// addresses this issue from Liquity v1: https://github.com/liquity/dev/security/advisories/GHSA-m9f3-hrx8-x2g3
				if (newP < SCALE_FACTOR) {
					newP = _getNewPByScale(currentP, newProductFactor, lastDebtLossErrorByP_Offset_Cached, lastDebtLossError_TotalDeposits_Cached, SCALE_FACTOR * SCALE_FACTOR);
					currentScale = currentScaleCached + 2;
				}
				emit ScaleUpdated(currentScale);
			}
			// If there's no scale change and no pool-emptying, just do a standard multiplication
		}
		lastDebtLossErrorByP_Offset = currentP * newLastDebtLossErrorOffset;
		lastDebtLossError_TotalDeposits = _totalDeposits;

		assert(newP > 0);
		P = newP;

		emit P_Updated(newP);
	}

	function _getNewPByScale(uint256 _currentP, uint256 _newProductFactor, uint256 _lastDebtLossErrorByP_Offset, uint256 _lastDebtLossError_TotalDeposits, uint256 _scale) internal pure returns (uint256) {
		uint256 errorFactor;
		if (_lastDebtLossErrorByP_Offset > 0) {
			errorFactor = (_lastDebtLossErrorByP_Offset * _newProductFactor * _scale) / _lastDebtLossError_TotalDeposits / DECIMAL_PRECISION;
		}
		return (_currentP * _newProductFactor * _scale + errorFactor) / DECIMAL_PRECISION;
	}

	function _decreaseDebt(uint256 _amount) internal {
		uint256 newTotalDebtTokenDeposits = totalDebtTokenDeposits - _amount;
		totalDebtTokenDeposits = newTotalDebtTokenDeposits;
		emit StabilityPoolDebtBalanceUpdated(newTotalDebtTokenDeposits);
	}

	/* Calculates the collateral gain earned by the deposit since its last snapshots were taken.
	 * Given by the formula:  E = d0 * (S - S(0))/P(0)
	 * where S(0) and P(0) are the depositor's snapshots of the sum S and product P, respectively.
	 * d0 is the last recorded deposit value.
	 */
	function getDepositorCollateralGain(address _depositor) external view returns (IERC20[] memory collaterals, uint256[] memory collateralGains) {
		uint256 length = collateralTokens.length();
		collaterals = new IERC20[](length);
		collateralGains = new uint256[](length);
		uint256 P_Snapshot = depositSnapshots[_depositor].P;
		if (P_Snapshot == 0) {
			for (uint256 i = 0; i < length; i++) {
				(, IERC20 collateral) = collateralTokens.at(i);
				collaterals[i] = collateral;
				collateralGains[i] = collateralGainsByDepositor[_depositor][collateral];
			}
			return (collaterals, collateralGains);
		}
		uint256 initialDeposit = accountDeposits[_depositor].amount;
		uint128 epochSnapshot = depositSnapshots[_depositor].epoch;
		uint128 scaleSnapshot = depositSnapshots[_depositor].scale;
		for (uint256 i = 0; i < length; i++) {
			(, IERC20 collateral) = collateralTokens.at(i);
			collaterals[i] = collateral;
			collateralGains[i] = collateralGainsByDepositor[_depositor][collateral];
			uint256 sum = epochToScaleToSums[epochSnapshot][scaleSnapshot][collateral];
			uint256 nextSum = epochToScaleToSums[epochSnapshot][scaleSnapshot + 1][collateral];
			uint256 depSum = depositSums[_depositor][collateral];
			if (sum == 0) continue;
			uint256 firstPortion = sum - depSum;
			uint256 secondPortion = nextSum / SCALE_FACTOR;
			collateralGains[i] += (initialDeposit * (firstPortion + secondPortion)) / P_Snapshot / DECIMAL_PRECISION;
		}
		return (collaterals, collateralGains);
	}

	/*
	 * Calculate the yield gain earned by a deposit since its last snapshots were taken.
	 * Given by the formula:  Yield = d0 * (G - G(0))/P(0)
	 * where G(0) and P(0) are the depositor's snapshots of the sum G and product P, respectively.
	 * d0 is the last recorded deposit value.
	 */
	function getYieldGains(address _depositor) external view returns (uint256 gains) {
		uint256 initialDeposit = accountDeposits[_depositor].amount;
		if (initialDeposit == 0) {
			return storedPendingYield[_depositor];
		}
		uint256 pendingYield = yieldGainsPending;
		uint256 length = collateralTokens.length();
		for (uint256 i = 0; i < length; i++) {
			(address troveManager, ) = collateralTokens.at(i);
			uint256 yieldSP = ITroveManager(troveManager).getPendingYieldSP();
			pendingYield += yieldSP;
		}
		uint256 firstPortionPending;
		uint256 secondPortionPending;
		Snapshots memory snapshots = depositSnapshots[_depositor];
		if (pendingYield > 0 && snapshots.epoch == currentEpoch && totalDebtTokenDeposits >= DECIMAL_PRECISION) {
			uint256 yieldNumerator = pendingYield * DECIMAL_PRECISION + lastYieldError;
			uint256 yieldPerUnitStaked = yieldNumerator / totalDebtTokenDeposits;
			uint256 marginalYieldGain = yieldPerUnitStaked * (P - 1);
			if (currentScale == snapshots.scale) firstPortionPending = marginalYieldGain;
			else if (currentScale == snapshots.scale + 1) secondPortionPending = marginalYieldGain;
		}
		uint256 firstPortion = epochToScaleToG[snapshots.epoch][snapshots.scale] + firstPortionPending - snapshots.G;
		uint256 secondPortion = (epochToScaleToG[snapshots.epoch][snapshots.scale + 1] + secondPortionPending) / SCALE_FACTOR;
		gains = storedPendingYield[_depositor] + (initialDeposit * (firstPortion + secondPortion)) / snapshots.P / DECIMAL_PRECISION;
	}

	// --- Sender functions for Debt deposit, collateral gains and Yala gains ---
	function claimAllCollateralGains(address recipient) external nonReentrant {
		uint256 initialDeposit = accountDeposits[msg.sender].amount;
		uint128 depositTimestamp = accountDeposits[msg.sender].timestamp;
		require(depositTimestamp < block.timestamp, "StabilityPool: !Deposit and claim collateral gains same block");
		_accrueRewards(msg.sender, initialDeposit);
		uint256 newDeposit = _getCompoundedDebtDeposit(msg.sender, initialDeposit);
		accountDeposits[msg.sender].amount = uint128(newDeposit);
		_updateSnapshots(msg.sender, newDeposit);
		uint256 length = collateralTokens.length();
		for (uint256 i = 0; i < length; i++) {
			(, IERC20 collateral) = collateralTokens.at(i);
			uint256 gains = collateralGainsByDepositor[msg.sender][collateral];
			if (gains > 0) {
				collateralGainsByDepositor[msg.sender][collateral] = 0;
				gains = YalaMath._min(collateral.balanceOf(address(this)), _computeCollateralWithdrawable(collateral, gains));
				collateral.safeTransfer(recipient, gains);
				emit CollateralGainWithdrawn(msg.sender, collateral, gains);
			}
		}
	}

	function claimYield(address recipient) external nonReentrant returns (uint256 amount) {
		uint256 initialDeposit = accountDeposits[msg.sender].amount;
		_accrueRewards(msg.sender, initialDeposit);
		uint256 newDeposit = _getCompoundedDebtDeposit(msg.sender, initialDeposit);
		accountDeposits[msg.sender].amount = uint128(newDeposit);
		_updateSnapshots(msg.sender, newDeposit);
		amount = storedPendingYield[msg.sender];
		if (amount > 0) {
			storedPendingYield[msg.sender] = 0;
			amount = YalaMath._min(debtToken.balanceOf(address(this)), amount);
			debtToken.returnFromPool(address(this), recipient, amount);
			emit YieldClaimed(msg.sender, recipient, amount);
		}
		return amount;
	}

	function _computeCollateralAmount(IERC20 collateral, uint256 amount) internal view returns (uint256) {
		uint8 decimals = collateralDecimals[collateral];
		if (decimals <= TARGET_DIGITS) {
			return amount * (10 ** (TARGET_DIGITS - decimals));
		}
		return amount / (10 ** (decimals - TARGET_DIGITS));
	}

	function _computeCollateralWithdrawable(IERC20 collateral, uint256 amount) internal view returns (uint256) {
		uint8 decimals = collateralDecimals[collateral];
		if (decimals <= TARGET_DIGITS) {
			return amount / (10 ** (TARGET_DIGITS - decimals));
		}
		return amount * (10 ** (decimals - TARGET_DIGITS));
	}

	function _accrueRewards(address depositor, uint256 initialDeposit) internal {
		_accrueAllYieldGains();
		_accrueDepositorYield(depositor, initialDeposit);
		_accrueDepositorCollateralGains(depositor, initialDeposit);
	}

	function triggerSPYield(uint256 _yield) external {
		require(collateralTokens.contains(msg.sender), "StabilityPool: Nonexistent TM");
		uint256 accumulatedYieldGains = yieldGainsPending + _yield;
		if (accumulatedYieldGains == 0) return;
		if (totalDebtTokenDeposits < DECIMAL_PRECISION) {
			yieldGainsPending = accumulatedYieldGains;
			return;
		}
		yieldGainsPending = 0;
		uint256 yieldNumerator = accumulatedYieldGains * DECIMAL_PRECISION + lastYieldError;
		uint256 yieldPerUnitStaked = yieldNumerator / totalDebtTokenDeposits;
		lastYieldError = yieldNumerator - yieldPerUnitStaked * totalDebtTokenDeposits;
		uint256 marginalYieldGain = yieldPerUnitStaked * (P - 1);
		epochToScaleToG[currentEpoch][currentScale] = epochToScaleToG[currentEpoch][currentScale] + marginalYieldGain;
		emit G_Updated(epochToScaleToG[currentEpoch][currentScale], currentEpoch, currentScale);
	}

	function _accrueAllYieldGains() internal {
		uint256 length = collateralTokens.length();
		for (uint256 i = 0; i < length; i++) {
			(address troveManager, ) = collateralTokens.at(i);
			// trigger SP yiled
			ITroveManager(troveManager).accrueInterests();
		}
	}

	function _accrueDepositorYield(address account, uint256 initialDeposit) internal {
		if (initialDeposit == 0) {
			return;
		}
		Snapshots memory snapshots = depositSnapshots[account];
		uint128 epochSnapshot = snapshots.epoch;
		uint128 scaleSnapshot = snapshots.scale;
		uint256 G_Snapshot = snapshots.G;
		uint256 P_Snapshot = snapshots.P;
		uint256 firstPortion = epochToScaleToG[epochSnapshot][scaleSnapshot] - G_Snapshot;
		uint256 secondPortion = epochToScaleToG[epochSnapshot][scaleSnapshot + 1] / SCALE_FACTOR;
		uint256 amount = (initialDeposit * (firstPortion + secondPortion)) / P_Snapshot / DECIMAL_PRECISION;
		storedPendingYield[account] += amount;
	}

	function _accrueDepositorCollateralGains(address _depositor, uint256 initialDeposit) internal {
		if (initialDeposit == 0) {
			return;
		}
		uint256 length = collateralTokens.length();
		address depositor = _depositor;
		uint256 deposit = initialDeposit;
		for (uint256 i = 0; i < length; i++) {
			(, IERC20 collateral) = collateralTokens.at(i);
			uint128 epochSnapshot = depositSnapshots[depositor].epoch;
			uint128 scaleSnapshot = depositSnapshots[depositor].scale;
			uint256 P_Snapshot = depositSnapshots[depositor].P;
			uint256 sum = epochToScaleToSums[epochSnapshot][scaleSnapshot][collateral];
			uint256 nextSum = epochToScaleToSums[epochSnapshot][scaleSnapshot + 1][collateral];
			uint256 depSum = depositSums[depositor][collateral];
			if (sum == 0 || sum == depSum) return;
			uint256 firstPortion = sum - depSum;
			uint256 secondPortion = nextSum / SCALE_FACTOR;
			uint256 gains = (deposit * (firstPortion + secondPortion)) / P_Snapshot / DECIMAL_PRECISION;
			collateralGainsByDepositor[depositor][collateral] += gains;
		}
	}

	function getCompoundedDebtDeposit(address _depositor) public view returns (uint256) {
		return _getCompoundedDebtDeposit(_depositor, accountDeposits[_depositor].amount);
	}

	function _getCompoundedDebtDeposit(address _depositor, uint256 initialDeposit) internal view returns (uint256) {
		if (initialDeposit == 0) {
			return 0;
		}
		Snapshots memory snapshots = depositSnapshots[_depositor];
		uint256 snapshot_P = snapshots.P;
		uint128 scaleSnapshot = snapshots.scale;
		uint128 epochSnapshot = snapshots.epoch;
		// If stake was made before a pool-emptying event, then it has been fully cancelled with debt -- so, return 0
		if (epochSnapshot < currentEpoch) {
			return 0;
		}
		uint256 compoundedStake;
		uint128 scaleDiff = currentScale - scaleSnapshot;
		uint256 cachedP = P;
		uint256 currentPToUse = cachedP != snapshot_P ? cachedP - 1 : cachedP;
		/* Compute the compounded stake. If a scale change in P was made during the stake's lifetime,
		 * account for it. If more than one scale change was made, then the stake has decreased by a factor of
		 * at least 1e-9 -- so return 0.
		 */
		if (scaleDiff == 0) {
			compoundedStake = (initialDeposit * currentPToUse) / snapshot_P;
		} else if (scaleDiff == 1) {
			compoundedStake = (initialDeposit * currentPToUse) / snapshot_P / SCALE_FACTOR;
		} else {
			compoundedStake = 0;
		}

		if (compoundedStake < initialDeposit / 1e9) {
			return 0;
		}

		return compoundedStake;
	}

	function _computeYieldPerUnitStaked(uint256 _yield, uint256 _totalDebtTokenDeposits) internal returns (uint256) {
		/*
		 * Calculate the Yala-per-unit staked.  Division uses a "feedback" error correction, to keep the
		 * cumulative error low in the running total G:
		 *
		 * 1) Form a numerator which compensates for the floor division error that occurred the last time this
		 * function was called.
		 * 2) Calculate "per-unit-staked" ratio.
		 * 3) Multiply the ratio back by its denominator, to reveal the current floor division error.
		 * 4) Store this error for use in the next correction when this function is called.
		 * 5) Note: static analysis tools complain about this "division before multiplication", however, it is intended.
		 */
		uint256 yieldNumerator = (_yield * DECIMAL_PRECISION) + lastYieldError;
		uint256 yieldPerUnitStaked = yieldNumerator / _totalDebtTokenDeposits;
		lastYieldError = yieldNumerator - (yieldPerUnitStaked * _totalDebtTokenDeposits);
		return yieldPerUnitStaked;
	}

	function _updateSnapshots(address _depositor, uint256 _newValue) internal {
		uint256 length = collateralTokens.length();
		if (_newValue == 0) {
			delete depositSnapshots[_depositor];
			for (uint256 i = 0; i < length; i++) {
				(, IERC20 collateral) = collateralTokens.at(i);
				depositSums[_depositor][collateral] = 0;
			}
			emit DepositSnapshotUpdated(_depositor, 0, 0);
			return;
		}
		uint128 currentScaleCached = currentScale;
		uint128 currentEpochCached = currentEpoch;
		uint256 currentG = epochToScaleToG[currentEpochCached][currentScaleCached];
		uint256 currentP = P;
		// Record new snapshots of the latest running product P, sum S, and sum G, for the depositor
		depositSnapshots[_depositor].P = currentP;
		depositSnapshots[_depositor].G = currentG;
		depositSnapshots[_depositor].scale = currentScaleCached;
		depositSnapshots[_depositor].epoch = currentEpochCached;
		for (uint256 i = 0; i < length; i++) {
			(, IERC20 collateral) = collateralTokens.at(i);
			// Get S and G for the current epoch and current scale
			uint256 currentS = epochToScaleToSums[currentEpochCached][currentScaleCached][collateral];
			depositSums[_depositor][collateral] = currentS;
		}
		emit DepositSnapshotUpdated(_depositor, currentP, currentG);
	}

	function getTotalDeposits() external view returns (uint256) {
		return totalDebtTokenDeposits;
	}
}
