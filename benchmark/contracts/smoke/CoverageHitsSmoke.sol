// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// A tiny contract that exercises a few distinct source lines so per-line hit counts
// are non-trivial in coverage outputs.
contract CoverageHitsSmoke {
    uint256 public acc;
    uint256 public last;

    constructor() payable {}

    function step(uint256 v) public {
        last = v;

        unchecked {
            if ((v & 1) == 0) {
                acc += v;
            } else {
                acc ^= v;
            }

            if (v % 5 == 0) {
                acc += 1;
            } else if (v % 5 == 1) {
                acc += 2;
            } else {
                acc += 3;
            }

            for (uint256 i = 0; i < 2; i++) {
                acc += i;
            }
        }
    }

    function echidna_always_true() public returns (bool) {
        return true;
    }
}
