// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Smoke tests for Foundry-compatible cheatcodes implemented in this custom
// Echidna/HEVM branch:
// - deal(address token, address to, uint256 give[, bool adjustTotalSupply])
// - readFile(string)
// - parseJsonBytes(string,string)
// - getCode(string)
// - snapshot()
// - revertTo(uint256)
// - record()
// - accesses(address)

interface Vm {
    function deal(address token, address to, uint256 give) external;
    function deal(address token, address to, uint256 give, bool adjustTotalSupply) external;
    function readFile(string calldata path) external returns (string memory contents);
    function parseJsonBytes(string calldata json, string calldata keyPath) external returns (bytes memory out);
    function getCode(string calldata artifactPath) external returns (bytes memory creationBytecode);
    function snapshot() external returns (uint256 id);
    function revertTo(uint256 id) external returns (bool success);
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

    // ------------------------------------------------------------------------
    // snapshot / revertTo
    // ------------------------------------------------------------------------

    function echidna_snapshot_and_revert() public returns (bool) {
        token.setBalance(USER, 100);
        uint256 snap = vm.snapshot();
        token.setBalance(USER, 999);

        if (!vm.revertTo(snap)) return false;
        return token.balanceOf(USER) == 100;
    }

    function echidna_revert_unknown_id_fails() public returns (bool) {
        uint256 snap = vm.snapshot();
        return !vm.revertTo(snap + 1);
    }

    // ------------------------------------------------------------------------
    // readFile / parseJsonBytes / getCode
    // ------------------------------------------------------------------------

    function echidna_read_file() public returns (bool) {
        string memory text = vm.readFile("contracts/bench/fixtures/read_file_payload.json");
        return keccak256(bytes(text)) == keccak256(bytes("{\"message\":\"cheatcode-fixtures\"}"));
    }

    function echidna_parse_json_bytes() public returns (bool) {
        string memory json = "{\"a\":{\"bytes\":\"0x68656c6c6f\",\"nums\":[1,2,3]}}";
        bytes memory fromHex = vm.parseJsonBytes(json, ".a.bytes");
        bytes memory fromArray = vm.parseJsonBytes(json, ".a.nums");

        if (keccak256(fromHex) != keccak256(bytes("hello"))) return false;
        if (fromArray.length != 3) return false;
        return fromArray[0] == 0x01 && fromArray[1] == 0x02 && fromArray[2] == 0x03;
    }

    function echidna_get_code() public returns (bool) {
        bytes memory code = vm.getCode("contracts/bench/getcode_artifacts/GetCodeWidget.0.8.18.json");
        return keccak256(code) == keccak256(hex"60016000556002600055");
    }

    function _contains(bytes32[] memory arr, bytes32 x) internal pure returns (bool) {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == x) return true;
        }
        return false;
    }
}
