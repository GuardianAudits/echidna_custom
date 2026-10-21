// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface Hevm {
    function record() external;
    function accesses(address) external returns (bytes32[] memory reads, bytes32[] memory writes);
}

contract TestRecordReset {
    address constant HEVM_ADDRESS = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D;
    Hevm constant hevm = Hevm(HEVM_ADDRESS);

    mapping(uint256 => uint256) public m;

    // Leaves recording on, like forge-std's deal() does during setUp.
    constructor() {
        hevm.record();
        m[1] = 1;
    }

    // Recording started in an earlier transaction must not carry into this one.
    function recordingEndsWithTx(uint8 x) public {
        m[uint256(x) + 100] = 1;
        (bytes32[] memory reads, bytes32[] memory writes) = hevm.accesses(address(this));
        assert(reads.length == 0 && writes.length == 0);
    }

    // record() and accesses() in the same transaction still work (what deal() relies on).
    function recordWithinTx() public {
        hevm.record();
        uint256 v = m[1];
        (bytes32[] memory reads, ) = hevm.accesses(address(this));
        assert(v == 1 && reads.length == 1 && reads[0] == keccak256(abi.encode(uint256(1), uint256(0))));
    }
}
