// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Microbenchmarks for Foundry-compatible cheatcodes implemented in this custom
// Echidna/HEVM branch:
// - deal(address token, address to, uint256 give[, bool adjustTotalSupply])
// - readFile(string)
// - parseJsonBytes(string,string)
// - getCode(string)
// - snapshot()
// - revertTo(uint256)
// - record()
// - accesses(address)
//
// Intended usage: run Echidna in property mode with seqLen=1 and a fixed
// testLimit; each sequence will execute one state-changing tx (step) and then
// the property (echidna_bench_*) which performs a fixed amount of cheatcode
// work. The benchmark script measures wall-clock runtime and derives ops/sec.

interface Vm {
    function deal(address token, address to, uint256 give) external;
    function readFile(string calldata path) external returns (string memory contents);
    function parseJsonBytes(string calldata json, string calldata keyPath) external returns (bytes memory out);
    function getCode(string calldata artifactRef) external returns (bytes memory creationBytecode);
    function snapshot() external returns (uint256 id);
    function revertTo(uint256 id) external returns (bool success);
    function record() external;
    function accesses(address target) external returns (bytes32[] memory reads, bytes32[] memory writes);
}

contract BenchToken {
    mapping(address => uint256) public balanceOf; // slot 0
    uint256 public totalSupply; // slot 1 (unused by benches)

    function setBalance(address to, uint256 amt) external {
        balanceOf[to] = amt;
    }
}

contract DealErc20Bench {
    Vm private constant vm = Vm(address(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D));
    BenchToken private immutable token;
    address private constant USER = address(0xBEEF);

    // Ensure Echidna always has a tx to execute.
    uint256 public touch;

    // Number of vm.deal(...) calls per property check.
    uint256 private constant DEAL_LOOPS = 10;

    constructor() {
        token = new BenchToken();
        token.setBalance(USER, 1);
    }

    function step(uint256 x) public {
        touch ^= x;
    }

    function echidna_bench_deal_erc20() public returns (bool) {
        // Using a changing `give` makes the checked_write verification do real work.
        for (uint256 i = 0; i < DEAL_LOOPS; i++) {
            vm.deal(address(token), USER, i);
        }
        return true;
    }
}

contract RecordBench {
    Vm private constant vm = Vm(address(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D));

    uint256 public touch;

    // Number of vm.record() calls per property check.
    uint256 private constant RECORD_LOOPS = 200;

    function step(uint256 x) public {
        touch ^= x;
    }

    function echidna_bench_record() public returns (bool) {
        for (uint256 i = 0; i < RECORD_LOOPS; i++) {
            vm.record();
        }
        return true;
    }
}

contract AccessesBench {
    Vm private constant vm = Vm(address(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D));
    BenchToken private immutable token;

    uint256 public touch;
    uint256 public sink;

    // Number of unique storage slots (mapping keys) touched after record().
    uint256 private constant SLOTS = 64;

    // Number of vm.accesses(...) calls per property check (same recorded set).
    uint256 private constant ACCESSES_CALLS = 5;

    constructor() {
        token = new BenchToken();
    }

    function step(uint256 x) public {
        touch ^= x;
    }

    function echidna_bench_accesses() public returns (bool) {
        vm.record();

        // Generate many write-only storage accesses to stress encoding/dedup.
        for (uint256 i = 0; i < SLOTS; i++) {
            token.setBalance(address(uint160(i + 1)), i);
        }

        uint256 acc = 0;
        for (uint256 i = 0; i < ACCESSES_CALLS; i++) {
            (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(token));
            // Prevent the optimizer from discarding returndata processing.
            acc += reads.length + writes.length;
        }
        sink = acc;
        return true;
    }
}

contract SnapshotBench {
    Vm private constant vm = Vm(address(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D));

    uint256 public touch;

    // Number of vm.snapshot() calls per property check.
    uint256 private constant SNAPSHOT_LOOPS = 20;

    function step(uint256 x) public {
        touch ^= x;
    }

    function echidna_bench_snapshot() public returns (bool) {
        for (uint256 i = 0; i < SNAPSHOT_LOOPS; i++) {
            vm.snapshot();
        }
        return true;
    }
}

contract RevertToBench {
    Vm private constant vm = Vm(address(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D));
    BenchToken private immutable token;
    address private constant USER = address(0xBEEF);

    uint256 public touch;

    // Number of snapshot + mutation + revertTo(...) cycles per property check.
    uint256 private constant REVERT_LOOPS = 20;

    constructor() {
        token = new BenchToken();
        token.setBalance(USER, 1);
    }

    function step(uint256 x) public {
        touch ^= x;
    }

    function echidna_bench_revert_to() public returns (bool) {
        for (uint256 i = 0; i < REVERT_LOOPS; i++) {
            uint256 snap = vm.snapshot();
            token.setBalance(USER, i);
            if (!vm.revertTo(snap)) {
                return false;
            }
        }
        return true;
    }
}

contract ReadFileBench {
    Vm private constant vm = Vm(address(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D));
    string private constant READ_FILE_PATH = "contracts/bench/fixtures/read_file_payload.json";

    uint256 public touch;
    uint256 public sink;

    // Number of vm.readFile(...) calls per property check.
    uint256 private constant READFILE_LOOPS = 50;

    function step(uint256 x) public {
        touch ^= x;
    }

    function echidna_bench_read_file() public returns (bool) {
        uint256 acc;
        for (uint256 i = 0; i < READFILE_LOOPS; i++) {
            string memory text = vm.readFile(READ_FILE_PATH);
            acc += bytes(text).length;
        }
        sink = acc;
        return true;
    }
}

contract ParseJsonBytesBench {
    Vm private constant vm = Vm(address(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D));
    string private constant JSON_TEXT = "{\"a\":{\"bytes\":\"0x68656c6c6f\",\"nums\":[1,2,3]}}";

    uint256 public touch;
    uint256 public sink;

    // Number of vm.parseJsonBytes(...) calls per property check.
    uint256 private constant PARSEJSON_LOOPS = 200;

    function step(uint256 x) public {
        touch ^= x;
    }

    function echidna_bench_parse_json_bytes() public returns (bool) {
        uint256 acc;
        for (uint256 i = 0; i < PARSEJSON_LOOPS; i++) {
            bytes memory fromHex = vm.parseJsonBytes(JSON_TEXT, ".a.bytes");
            bytes memory fromArray = vm.parseJsonBytes(JSON_TEXT, ".a.nums");
            acc += fromHex.length + fromArray.length;
        }
        sink = acc;
        return true;
    }
}

contract GetCodeBench {
    Vm private constant vm = Vm(address(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D));
    string private constant ARTIFACT_REF = "contracts/bench/getcode_artifacts/GetCodeWidget.0.8.18.json";

    uint256 public touch;
    uint256 public sink;

    // Number of vm.getCode(...) calls per property check.
    uint256 private constant GETCODE_LOOPS = 25;

    function step(uint256 x) public {
        touch ^= x;
    }

    function echidna_bench_get_code() public returns (bool) {
        uint256 acc;
        for (uint256 i = 0; i < GETCODE_LOOPS; i++) {
            bytes memory code = vm.getCode(ARTIFACT_REF);
            acc += code.length;
        }
        sink = acc;
        return true;
    }
}
