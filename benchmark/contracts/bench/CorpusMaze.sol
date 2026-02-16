// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// A stateful "maze" intended for measuring how quickly coverage-guided fuzzing
// (and distributed corpus sync) converges on a deep state.
//
// This contract is intentionally not "secure"; it is a benchmark target.
contract CorpusMaze {
    uint256 public state;
    uint256 internal marker;

    uint256 internal constant FINAL_STATE = 4;
    uint256 internal constant STEP_MASK_5 = 0x1f; // 1/32
    uint256 internal constant STEP_MASK_6 = 0x3f; // 1/64

    function step(uint256 x) public {
        if (state == FINAL_STATE) {
            assert(false);
        }
        // State transitions use hash predicates that are intentionally less common:
        // 0 -> 1: 1/32
        // 1 -> 2: 1/64 with matching parity against prior input marker
        // 2 -> 3: 1/64 (with x parity)
        // 3 -> 4: 1/64
        uint256 hashed = uint256(keccak256(abi.encodePacked(x, state)));
        if (state == 0) {
            if ((hashed & STEP_MASK_5) == 0x0d) {
                state = 1;
                marker = x;
            }
        } else if (state == 1) {
            if ((hashed & STEP_MASK_6) == 0x3a && (x & 1) == (marker & 1)) {
                state = 2;
            } else if ((hashed & STEP_MASK_5) == 0x17) {
                // A noisy detour makes reaching the success path slightly less direct.
                state = 0;
            }
        } else if (state == 2) {
            if ((hashed & STEP_MASK_5) == 0x15 && (x & 1) == 1) {
                state = 3;
            }
        } else if (state == 3) {
            if ((hashed & STEP_MASK_6) == 0x22) {
                state = FINAL_STATE;
            }
        }
    }

    // Benchmark oracle: falsified once the maze is solved.
    function echidna_maze_unsolved() public returns (bool) {
        return state != FINAL_STATE;
    }
}
