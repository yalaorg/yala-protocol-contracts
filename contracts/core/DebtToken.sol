// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "@layerzerolabs/oft-evm/contracts/OFT.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "../interfaces/IYalaCore.sol";
import "../interfaces/IDebtToken.sol";

contract DebtToken is IDebtToken, OFT, ERC20Permit {
	// --- Addresses ---
	address public immutable stabilityPoolAddress;
	address public immutable borrowerOperationsAddress;
	address public immutable factory;
	address public immutable gasPool;

	mapping(address => bool) public troveManager;
	mapping(address => bool) public psm;
	// Amount of debt to be locked in gas pool on opening troves
	uint256 public immutable DEBT_GAS_COMPENSATION;

	constructor(string memory _name, string memory _symbol, address _stabilityPoolAddress, address _borrowerOperationsAddress, address _lzEndpoint, address _delegate, address _factory, address _gasPool, uint256 _gasCompensation) OFT(_name, _symbol, _lzEndpoint, _delegate) ERC20Permit(_name) {
		stabilityPoolAddress = _stabilityPoolAddress;
		borrowerOperationsAddress = _borrowerOperationsAddress;
		factory = _factory;
		gasPool = _gasPool;
		DEBT_GAS_COMPENSATION = _gasCompensation;
	}

	function enableTroveManager(address _troveManager) external {
		require(msg.sender == factory, "DebtToken: !Factory");
		troveManager[_troveManager] = true;
	}

	function enablePSM(address _psm) external {
		require(msg.sender == factory, "DebtToken: !Factory");
		psm[_psm] = true;
	}

	function mintWithGasCompensation(address _account, uint256 _amount) external returns (bool) {
		require(msg.sender == borrowerOperationsAddress);
		_mint(_account, _amount);
		_mint(gasPool, DEBT_GAS_COMPENSATION);
		return true;
	}

	function burnWithGasCompensation(address _account, uint256 _amount) external returns (bool) {
		require(msg.sender == borrowerOperationsAddress);
		_burn(_account, _amount);
		_burn(gasPool, DEBT_GAS_COMPENSATION);
		return true;
	}

	function mint(address _account, uint256 _amount) external {
		require(msg.sender == borrowerOperationsAddress || troveManager[msg.sender] || psm[msg.sender], "Debt: Caller not BO/TM/PSM");
		_mint(_account, _amount);
	}

	function burn(address _account, uint256 _amount) external {
		require(troveManager[msg.sender] || psm[msg.sender], "DebtToken: Caller not TM/PSM");
		_burn(_account, _amount);
	}

	function sendToSP(address _sender, uint256 _amount) external {
		require(msg.sender == stabilityPoolAddress, "DebtToken: Caller not StabilityPool");
		_transfer(_sender, msg.sender, _amount);
	}

	function returnFromPool(address _poolAddress, address _receiver, uint256 _amount) external {
		require(msg.sender == stabilityPoolAddress || troveManager[msg.sender], "DebtToken: Caller not TM/SP");
		_transfer(_poolAddress, _receiver, _amount);
	}

	function transfer(address recipient, uint256 amount) public override(ERC20, IERC20) returns (bool) {
		_requireValidRecipient(recipient);
		return super.transfer(recipient, amount);
	}

	function transferFrom(address sender, address recipient, uint256 amount) public override(ERC20, IERC20) returns (bool) {
		_requireValidRecipient(recipient);
		return super.transferFrom(sender, recipient, amount);
	}

	function _requireValidRecipient(address _recipient) internal view {
		require(_recipient != address(0) && _recipient != address(this), "DebtToken: Cannot transfer tokens directly to the Debt token contract or the zero address");
		require(_recipient != stabilityPoolAddress && !troveManager[_recipient] && _recipient != borrowerOperationsAddress, "DebtToken: Cannot transfer tokens directly to the StabilityPool, TroveManager or BorrowerOps");
	}
}
