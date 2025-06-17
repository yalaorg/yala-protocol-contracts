// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "../dependencies/YalaOwnable.sol";
import "../interfaces/ITroveManager.sol";
import "../interfaces/IBorrowerOperations.sol";
import "../interfaces/IDebtToken.sol";
import "../interfaces/IStabilityPool.sol";
import "../interfaces/IPSM.sol";

contract Factory is YalaOwnable {
	using Clones for address;

	IDebtToken public immutable debtToken;
	IStabilityPool public immutable stabilityPool;
	IBorrowerOperations public immutable borrowerOperations;

	address public troveManagerImpl;
	address public psmImpl;

	ITroveManager[] public troveManagers;
	address[] public psms;

	event NewCDPDeployment(IERC20 collateral, IPriceFeed priceFeed, ITroveManager troveManager);
	event NewPSMDeployment(address psm, IERC20Metadata pegToken, uint256 feeIn, uint256 feeOut, uint256 supplyCap);

	constructor(address _yalaCore, IDebtToken _debtToken, IStabilityPool _stabilityPool, IBorrowerOperations _borrowerOperations, address _troveManager, address _psm) YalaOwnable(_yalaCore) {
		debtToken = _debtToken;
		stabilityPool = _stabilityPool;
		borrowerOperations = _borrowerOperations;
		troveManagerImpl = _troveManager;
		psmImpl = _psm;
	}

	function psmCount() external view returns (uint256) {
		return psms.length;
	}

	function troveManagerCount() external view returns (uint256) {
		return troveManagers.length;
	}

	function deployNewCDP(IERC20 collateral, bytes32 salt, IPriceFeed priceFeed, address customTroveManagerImpl, ITroveManager.DeploymentParams memory params) external onlyOwner returns (ITroveManager troveManager) {
		address implementation = customTroveManagerImpl == address(0) ? troveManagerImpl : customTroveManagerImpl;
		troveManager = ITroveManager(implementation.cloneDeterministic(keccak256(abi.encodePacked(address(collateral), salt))));
		troveManagers.push(troveManager);
		troveManager.setParameters(priceFeed, collateral, params);
		// verify that the oracle is correctly working
		troveManager.fetchPrice();

		stabilityPool.enableTroveManager(address(troveManager));
		debtToken.enableTroveManager(address(troveManager));
		borrowerOperations.configureCollateral(troveManager, collateral);

		emit NewCDPDeployment(collateral, priceFeed, troveManager);
	}

	function deployNewPSM(address customPSMImpl, IERC20Metadata pegToken, uint256 feeIn, uint256 feeOut, uint256 supplyCap) external onlyOwner returns (address psm) {
		address implementation = customPSMImpl == address(0) ? psmImpl : customPSMImpl;
		psm = implementation.cloneDeterministic(bytes32(bytes20(address(pegToken))));
		IPSM(psm).initialize(pegToken, feeIn, feeOut, supplyCap);
		debtToken.enablePSM(psm);
		psms.push(psm);
		emit NewPSMDeployment(psm, pegToken, feeIn, feeOut, supplyCap);
	}

	function setTroveMangerImpl(address _troveManagerImpl) external onlyOwner {
		troveManagerImpl = _troveManagerImpl;
	}

	function setPSMImpl(address _psmImpl) external onlyOwner {
		psmImpl = _psmImpl;
	}
}
