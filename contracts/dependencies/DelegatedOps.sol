// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

contract DelegatedOps {
	event DelegateApprovalSet(address indexed caller, address indexed delegate, bool isApproved);

	mapping(address owner => mapping(address caller => bool isApproved)) public isApprovedDelegate;

	modifier callerOrDelegated(address _account) {
		require(msg.sender == _account || isApprovedDelegate[_account][msg.sender], "Delegate not approved");
		_;
	}

	function setDelegateApproval(address _delegate, bool _isApproved) external {
		isApprovedDelegate[msg.sender][_delegate] = _isApproved;
		emit DelegateApprovalSet(msg.sender, _delegate, _isApproved);
	}
}
