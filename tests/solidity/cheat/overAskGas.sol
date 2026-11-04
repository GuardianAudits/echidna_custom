// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface Hevm {
    function warp(uint256) external;
}

// Solar reads GAS before it builds a call's calldata, so the gas it asks a
// cheatcode call to forward is more than is left at the CALL. The EVM caps
// a call at all but 1/64th of the remaining gas, so the call must succeed.
contract TestCheatOverAskGas {
    address constant HEVM_ADDRESS = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D;

    bool public warpedInConstructor;
    bool public warpedInCall = true;

    constructor() {
        warpedInConstructor = overAskWarp(1000);
    }

    function warpOverAsking(uint8 t) public {
        warpedInCall = overAskWarp(2000 + uint256(t));
    }

    // A cheatcode call that forwards less than is left must not hand the
    // caller back more gas than it had before the call.
    bool public mintedGas;

    function warpUnderAsking(uint8 t) public {
        uint256 before = gasleft();
        (bool ok,) = HEVM_ADDRESS.call{gas: 100000}(abi.encodeWithSelector(Hevm.warp.selector, 3000 + uint256(t)));
        if (ok && gasleft() > before) {
            mintedGas = true;
        }
    }

    // A cheatcode that fails must leave the caller its gas, as in Foundry:
    // suites probe cheatcodes hevm may not have (here signP256) this way.
    bool public failedCheatBurnedGas;

    function callMissingCheat(uint8 k) public {
        uint256 before = gasleft();
        (bool ok,) = HEVM_ADDRESS.call(abi.encodeWithSignature("signP256(uint256,bytes32)", 1 + uint256(k), bytes32(0)));
        if (!ok && gasleft() * 2 < before) {
            failedCheatBurnedGas = true;
        }
    }

    function overAskWarp(uint256 t) internal returns (bool) {
        (bool ok,) = HEVM_ADDRESS.call{gas: gasleft() + 1000}(abi.encodeWithSelector(Hevm.warp.selector, t));
        return ok && block.timestamp == t;
    }

    function echidna_over_ask_in_constructor() public view returns (bool) {
        return warpedInConstructor;
    }

    function echidna_over_ask_in_call() public view returns (bool) {
        return warpedInCall;
    }

    function echidna_under_ask_keeps_gas() public view returns (bool) {
        return !mintedGas;
    }

    function echidna_failed_cheat_keeps_gas() public view returns (bool) {
        return !failedCheatBurnedGas;
    }
}
