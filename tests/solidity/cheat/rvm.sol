// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface Rvm {
  function loadVar(address, string calldata) external returns (bytes32);
  function loadVar(address, string calldata, bytes calldata) external returns (bytes32);
  function loadVar(address, bytes32, uint8, uint8) external returns (bytes32);
  function storeVar(address, string calldata, bytes32) external;
  function storeVar(address, string calldata, bytes calldata, bytes32) external;
  function storeVar(address, bytes32, uint8, uint8, bytes32) external;
  function registerStorageLayout(address, string calldata) external;
}

Rvm constant rvm = Rvm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

contract RvmTarget {
  struct Config {
    uint128 feeNumerator;
    bool paused;
  }

  uint8 private tiny = 0x11;
  bool private enabled = true;
  uint128 private counter = 0x1234;
  uint256 private totalDeposits = 777;
  Config private config = Config({feeNumerator: 25, paused: true});
  mapping(address => uint256) private balances;
  mapping(address => mapping(address => uint256)) private allowances;
  uint256[] private values;
  uint8[40] private fixedPackedValues;

  constructor(address user, address spender) {
    balances[user] = 1111;
    allowances[user][spender] = 2222;
    values.push(3333);
  }
}

contract TestRvm {
  address constant USER = address(0xBEEF);
  address constant SPENDER = address(0xCAFE);
  RvmTarget target;

  constructor() {
    target = new RvmTarget(USER, SPENDER);
    rvm.registerStorageLayout(
      address(target),
      "uint8 tiny, bool enabled, uint128 counter, uint256 totalDeposits, "
      "(uint128 feeNumerator, bool paused) config, "
      "mapping(address => uint256) balances, "
      "mapping(address => mapping(address => uint256)) allowances, uint256[] values"
      ", uint8[40] fixedPackedValues"
    );
  }

  function echidna_rvm_reads_named_packed_mapping_and_array() public returns (bool) {
    return uint256(rvm.loadVar(address(target), "totalDeposits")) == 777
      && uint256(rvm.loadVar(address(target), "config.feeNumerator")) == 25
      && uint256(rvm.loadVar(address(target), "config.paused")) == 1
      && uint256(rvm.loadVar(address(target), "balances", abi.encode(USER))) == 1111
      && uint256(rvm.loadVar(address(target), "allowances", abi.encode(USER, SPENDER))) == 2222
      && uint256(rvm.loadVar(address(target), "values", abi.encode(uint256(0)))) == 3333;
  }

  function echidna_rvm_reads_raw_packed_fields() public returns (bool) {
    bytes32 slot0 = bytes32(uint256(0));
    return uint256(rvm.loadVar(address(target), slot0, 0, 1)) == 0x11
      && uint256(rvm.loadVar(address(target), slot0, 1, 1)) == 1
      && uint256(rvm.loadVar(address(target), slot0, 2, 16)) == 0x1234;
  }

  function echidna_rvm_writes_preserve_adjacent_packed_fields() public returns (bool) {
    rvm.storeVar(address(target), "totalDeposits", bytes32(uint256(999)));
    rvm.storeVar(address(target), "config.paused", bytes32(uint256(0)));
    rvm.storeVar(address(target), "balances", abi.encode(USER), bytes32(uint256(4444)));
    rvm.storeVar(address(target), bytes32(uint256(0)), 1, 1, bytes32(uint256(0)));

    return uint256(rvm.loadVar(address(target), "totalDeposits")) == 999
      && uint256(rvm.loadVar(address(target), "config.paused")) == 0
      && uint256(rvm.loadVar(address(target), "balances", abi.encode(USER))) == 4444
      && uint256(rvm.loadVar(address(target), bytes32(uint256(0)), 0, 1)) == 0x11
      && uint256(rvm.loadVar(address(target), bytes32(uint256(0)), 2, 16)) == 0x1234;
  }

  function echidna_rvm_accepts_solc_json_layout() public returns (bool) {
    rvm.registerStorageLayout(
      address(target),
      '{"storage":[{"label":"totalDeposits","offset":0,"slot":"1","type":"t_uint256"}],'
      '"types":{"t_uint256":{"encoding":"inplace","label":"uint256","numberOfBytes":"32"}}}'
    );
    return uint256(rvm.loadVar(address(target), "totalDeposits")) == 777;
  }

  function echidna_rvm_resolution_errors_revert_only_the_call() public returns (bool) {
    (bool missingSucceeded,) = address(rvm).call(
      abi.encodeWithSignature("loadVar(address,string)", address(target), "missing")
    );
    (bool outOfBoundsSucceeded,) = address(rvm).call(
      abi.encodeWithSignature(
        "loadVar(address,string,bytes)", address(target), "fixedPackedValues", abi.encode(uint256(40))
      )
    );
    return !missingSucceeded && !outOfBoundsSucceeded;
  }

  function rvm_write_then_revert() external {
    require(msg.sender == address(this));
    rvm.storeVar(address(target), "config.paused", bytes32(uint256(0)));
    revert("rollback RVM write");
  }

  function echidna_rvm_store_is_rolled_back_on_revert() public returns (bool) {
    (bool succeeded,) = address(this).call(
      abi.encodeWithSelector(this.rvm_write_then_revert.selector)
    );
    return !succeeded && uint256(rvm.loadVar(address(target), "config.paused")) == 1;
  }
}
