pragma solidity >=0.8.0;

interface VmInvalidUtf8 {
  function setEnv(string calldata key, string calldata value) external;
  function envString(string calldata key) external returns (string memory value);
}

contract TestInvalidUtf8String {
  address constant HEVM_ADDRESS = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D;
  VmInvalidUtf8 constant vm = VmInvalidUtf8(HEVM_ADDRESS);

  function invalidUtf8() internal pure returns (string memory value) {
    bytes memory raw = hex"fd";
    assembly {
      value := raw
    }
  }

  function echidna_invalid_utf8_env_key_is_escaped() public returns (bool) {
    string memory key = invalidUtf8();
    string memory expected = "value";

    vm.setEnv(key, expected);
    return keccak256(bytes(vm.envString(key))) == keccak256(bytes(expected));
  }
}
