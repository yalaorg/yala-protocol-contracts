// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IStabilityPool {
	struct AccountDeposit {
		uint128 amount;
		uint128 timestamp; // timestamp of the last deposit
	}

	struct Snapshots {
		uint256 P;
		uint256 G;
		uint128 scale;
		uint128 epoch;
	}

	event StabilityPoolDebtBalanceUpdated(uint256 _newBalance);
	event P_Updated(uint256 _P);
	event S_Updated(IERC20 collateral, uint256 _S, uint128 _epoch, uint128 _scale);
	event G_Updated(uint256 _G, uint128 _epoch, uint128 _scale);
	event EpochUpdated(uint128 _currentEpoch);
	event ScaleUpdated(uint128 _currentScale);

	event DepositSnapshotUpdated(address indexed _depositor, uint256 _P, uint256 _G);
	event Deposit(address indexed _depositor, uint256 _newDeposit, uint256 amount);
	event Withdraw(address indexed _depositor, uint256 _newDeposit, uint256 amount);

	event TriggerYiedRewards(address troveManager, uint256 amount);

	event CollateralGainWithdrawn(address indexed _depositor, IERC20 collateral, uint256 gains);
	event YieldClaimed(address indexed account, address indexed recipient, uint256 claimed);
	function enableTroveManager(address troveManager) external;
	function getTotalDeposits() external view returns (uint256);
	function offset(uint256 _debtToOffset, uint256 _collToAdd) external;
	function triggerSPYield(uint256 _yield) external;
	function provideToSP(uint256 _amount) external;
	function withdrawFromSP(uint256 _amount) external;
	function getCompoundedDebtDeposit(address _depositor) external view returns (uint256);
	function claimYield(address recipient) external returns (uint256 amount);
	function claimAllCollateralGains(address recipient) external;
	function getYieldGains(address _depositor) external view returns (uint256);
	function getDepositorCollateralGain(address _depositor) external view returns (IERC20[] memory collaterals, uint256[] memory collateralGains);
}
