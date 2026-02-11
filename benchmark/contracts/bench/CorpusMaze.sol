// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// A stateful "maze" intended for measuring how quickly coverage-guided fuzzing
// (and distributed corpus sync) converges on a deep state.
//
// This contract is intentionally not "secure"; it is a benchmark target.
contract CorpusMaze {
    uint256 public state;

    uint256 internal constant FINAL_STATE = 16;

    function step(uint256 x) public {
        // Each state requires the low nibble of x to match the state index.
        // Expected attempts per state ~= 16, so reaching FINAL_STATE is non-trivial
        // but still feasible with reasonable seqLen/workers.
        if (state == 0) {
            if ((x & 0xF) == 0) state = 1;
        } else if (state == 1) {
            if ((x & 0xF) == 1) state = 2;
        } else if (state == 2) {
            if ((x & 0xF) == 2) state = 3;
        } else if (state == 3) {
            if ((x & 0xF) == 3) state = 4;
        } else if (state == 4) {
            if ((x & 0xF) == 4) state = 5;
        } else if (state == 5) {
            if ((x & 0xF) == 5) state = 6;
        } else if (state == 6) {
            if ((x & 0xF) == 6) state = 7;
        } else if (state == 7) {
            if ((x & 0xF) == 7) state = 8;
        } else if (state == 8) {
            if ((x & 0xF) == 8) state = 9;
        } else if (state == 9) {
            if ((x & 0xF) == 9) state = 10;
        } else if (state == 10) {
            if ((x & 0xF) == 10) state = 11;
        } else if (state == 11) {
            if ((x & 0xF) == 11) state = 12;
        } else if (state == 12) {
            if ((x & 0xF) == 12) state = 13;
        } else if (state == 13) {
            if ((x & 0xF) == 13) state = 14;
        } else if (state == 14) {
            if ((x & 0xF) == 14) state = 15;
        } else if (state == 15) {
            if ((x & 0xF) == 15) state = 16;
        } else {
            // solved
        }
    }

    // Benchmark oracle: falsified once the maze is solved.
    function echidna_maze_unsolved() public returns (bool) {
        return state != FINAL_STATE;
    }
}
