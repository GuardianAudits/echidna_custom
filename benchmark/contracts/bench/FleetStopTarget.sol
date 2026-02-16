// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Target for testing distributed failure propagation + fleet_stop behavior.
contract FleetStopTarget {
    uint256 public state;
    uint256 public noiseAcc;

    uint256 internal constant FINAL_STATE = 2;
    uint256 internal constant STEP_MASK = 0x01;

    function step(uint256 x) public {
        if (state == FINAL_STATE) {
            assert(false);
        }
        // Same maze as CorpusMaze (keep deterministic + comparable).
        // Each state now requires a 1-bit hash bucket match.
        // Expected attempts per state ~= 2.
        uint256 hashed = uint256(keccak256(abi.encodePacked(x, state)));
        if (state == 0) {
            if ((hashed & STEP_MASK) == 0) state = 1;
        } else if (state == 1) {
            if ((hashed & STEP_MASK) == 1) state = 2;
        }
    }

    // "Noise" function used for fleet_stop listener nodes: whitelisting this
    // method prevents progressing toward the failing state.
    function noise(uint256 x) public {
        unchecked {
            noiseAcc ^= x;
        }
    }

    // Failure oracle: once any node finds this, it should publish a failure and
    // the hub can broadcast fleet_stop to stop other nodes.
    function echidna_target_unsolved() public returns (bool) {
        return state != FINAL_STATE;
    }
}
