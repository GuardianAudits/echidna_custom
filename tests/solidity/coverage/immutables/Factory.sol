// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.20;

contract Child {
    uint256 public immutable value;
    constructor(uint256 x) { value = x; }
}

contract Factory {
    function deploy(uint256 x) external {
        Child child = new Child(x);
        require(child.value() == x);
    }
    function echidna_ok() external pure returns (bool) { return true; }
}
