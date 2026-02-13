// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Smoke tests for Foundry-compatible cheatcodes implemented in this custom
// Echidna/HEVM branch:
// - deal(address token, address to, uint256 give[, bool adjustTotalSupply])
// - record()
// - accesses(address)

interface Vm {
    function deal(address token, address to, uint256 give) external;
    function deal(address token, address to, uint256 give, bool adjustTotalSupply) external;
    function record() external;
    function accesses(address target) external returns (bytes32[] memory reads, bytes32[] memory writes);
}

contract CheatToken {
    mapping(address => uint256) public balanceOf; // slot 0
    uint256 public totalSupply; // slot 1

    function setBalance(address to, uint256 amt) external {
        balanceOf[to] = amt;
    }

    function setTotalSupply(uint256 amt) external {
        totalSupply = amt;
    }
}

contract CheatcodesSmoke {
    Vm private constant vm = Vm(address(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D));

    CheatToken private immutable token;
    address private constant USER = address(0xBEEF);

    // A dummy state mutation so Echidna always has at least one tx it can make.
    uint256 public touch;

    constructor() {
        token = new CheatToken();
    }

    function step(uint256 x) public {
        touch ^= x;
    }

    // ------------------------------------------------------------------------
    // deal (ERC20)
    // ------------------------------------------------------------------------

    function echidna_deal_erc20_no_adjust() public returns (bool) {
        token.setBalance(USER, 100);
        token.setTotalSupply(999);

        vm.deal(address(token), USER, 50);

        return (token.balanceOf(USER) == 50) && (token.totalSupply() == 999);
    }

    function echidna_deal_erc20_adjust_total_supply() public returns (bool) {
        // Decrease supply (give < prevBal).
        token.setBalance(USER, 100);
        token.setTotalSupply(1000);

        vm.deal(address(token), USER, 25, true);
        if (token.balanceOf(USER) != 25) return false;
        if (token.totalSupply() != 1000 - (100 - 25)) return false;

        // Increase supply (give > prevBal).
        token.setBalance(USER, 10);
        token.setTotalSupply(1000);

        vm.deal(address(token), USER, 25, true);
        if (token.balanceOf(USER) != 25) return false;
        if (token.totalSupply() != 1000 + (25 - 10)) return false;

        return true;
    }

    // ------------------------------------------------------------------------
    // record/accesses
    // ------------------------------------------------------------------------

    function echidna_record_accesses_read_slot() public returns (bool) {
        // Foundry gotcha: accesses() before record() should be empty.
        (bytes32[] memory r0, bytes32[] memory w0) = vm.accesses(address(token));
        if (r0.length != 0 || w0.length != 0) return false;

        vm.record();
        token.balanceOf(USER);

        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(token));
        if (writes.length != 0) return false;

        bytes32 expected = keccak256(abi.encode(USER, uint256(0))); // mapping slot 0
        return _contains(reads, expected);
    }

    function echidna_record_accesses_write_is_read() public returns (bool) {
        vm.record();
        token.setBalance(USER, 123); // write-only path (no explicit SLOAD)

        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(token));

        bytes32 expected = keccak256(abi.encode(USER, uint256(0))); // mapping slot 0
        return _contains(reads, expected) && _contains(writes, expected);
    }

    function _contains(bytes32[] memory arr, bytes32 x) internal pure returns (bool) {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == x) return true;
        }
        return false;
    }
}

