// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IYalaCore {
	event NewOwnerCommitted(address owner, address pendingOwner, uint256 deadline);

	event NewOwnerAccepted(address oldOwner, address owner);

	event NewOwnerRevoked(address owner, address revokedOwner);

	event FeeReceiverSet(address feeReceiver);

	event GuardianSet(address guardian);

	event Paused();

	event Unpaused();

	function acceptTransferOwnership() external;

	function commitTransferOwnership(address newOwner) external;

	function revokeTransferOwnership() external;

	function setFeeReceiver(address _feeReceiver) external;

	function setGuardian(address _guardian) external;

	function setPaused(bool _paused) external;

	function OWNERSHIP_TRANSFER_DELAY() external view returns (uint256);

	function feeReceiver() external view returns (address);

	function guardian() external view returns (address);

	function owner() external view returns (address);

	function ownershipTransferDeadline() external view returns (uint256);

	function paused() external view returns (bool);

	function pendingOwner() external view returns (address);
}
