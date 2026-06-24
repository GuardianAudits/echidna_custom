// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface Hevm {
    function envString(string calldata) external view returns (string memory);
    function label(address, string calldata) external;
    function setEnv(string calldata, string calldata) external;
}

contract TestInvalidUtf8String {
    address constant HEVM_ADDRESS = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D;
    Hevm constant hevm = Hevm(HEVM_ADDRESS);

    function echidna_invalid_utf8_cheatcode_string_is_escaped() public returns (bool) {
        bytes memory raw = hex"fd";
        string memory invalidUtf8;
        assembly {
            invalidUtf8 := raw
        }

        hevm.label(address(0xBEEF), invalidUtf8);
        hevm.setEnv(invalidUtf8, "survived");

        return keccak256(bytes(hevm.envString(invalidUtf8))) == keccak256("survived");
    }
}
