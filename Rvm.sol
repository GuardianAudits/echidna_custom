// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// Echidna's storage-aware extension of the HEVM cheatcode interface.
interface IRvm {
  function loadVar(address target, string calldata path) external returns (bytes32);
  function loadVar(address target, string calldata path, bytes calldata keys) external returns (bytes32);
  function loadVar(address target, bytes32 slot, uint8 offset, uint8 size) external returns (bytes32);

  function storeVar(address target, string calldata path, bytes32 value) external;
  function storeVar(address target, string calldata path, bytes calldata keys, bytes32 value) external;
  function storeVar(address target, bytes32 slot, uint8 offset, uint8 size, bytes32 value) external;

  function registerStorageLayout(address target, string calldata layout) external;
  function assignStorageLayout(address target, string calldata contractName) external;
  function registerNamespace(address target, string calldata namespace, string calldata layout) external;
  function registerNamespace(address target, uint256 baseSlot, string calldata layout) external;
}

IRvm constant rvm = IRvm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
