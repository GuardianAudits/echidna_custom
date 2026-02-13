# Cheatcode Spec: `deal` (Native ETH + ERC20)

## Goal

Extend HEVM's existing `deal(address,uint256)` cheatcode (native ETH balance) with Foundry/forge-std compatible ERC20 overloads so tests/fuzzing can set ERC20 balances deterministically by mutating token storage.

Compatibility target:

- Match the observable behavior of `forge-std`'s `StdCheats.deal(token,to,give[,adjust])`, which uses `StdStorage.stdstore...checked_write(...)` under the hood.

## Non-Goals

- Do not perform on-chain transactions or depend on RPC.
- Do not call into token contracts to mint/transfer; this is a direct storage mutation.
- Do not guarantee support for every exotic token implementation (rebasing, packed balances, custom accounting).

## Cheatcode Address

HEVM cheatcodes are invoked by calling:

- `0x7109709ECfa91a80626fF3989D68f67F5b1DD12D`
- `address(uint160(uint256(keccak256("hevm cheat code"))))`

## Solidity API

### Existing (native ETH)

- `deal(address who, uint256 give)`

### New (ERC20)

Foundry-compatible overloads:

- `deal(address token, address to, uint256 give)`
- `deal(address token, address to, uint256 give, bool adjustTotalSupply)`

Notes:

- `give` is an absolute post-state balance (not a delta).
- Overloads are distinguished by selector; the 2-arg ETH `deal` must remain unchanged.

## Semantics

### 1) Native ETH: `deal(address who, uint256 give)`

Behavior (unchanged):

- Ensure `who` exists in the VM world state (create if missing per baseState rules).
- Set `who.balance = give`.
- No events, no gas accounting, no calls.

### 2) ERC20: `deal(address token, address to, uint256 give)`

Behavior (must match `forge-std`):

- Read the current balance via `STATICCALL`:
  - Call `token` with selector `0x70a08231` and argument `to`.
  - Decode returned bytes as `uint256 prevBal` (same behavior as Solidity `abi.decode`).
  - If decoding fails, revert.
- Update the balance using `StdStorage`-style *checked write* (see "Storage Resolution + Checked Write"):
  - Force `token.balanceOf(to)` to return `give`.
- No `Transfer` event, no allowance updates.

### 3) ERC20 + supply: `deal(address token, address to, uint256 give, bool adjustTotalSupply)`

- If `adjustTotalSupply == false`: same behavior as the 3-arg ERC20 overload.
- If `adjustTotalSupply == true`:
  - Read `prevBal` exactly as in the 3-arg ERC20 overload.
  - Write `balanceOf(to) = give` using checked write.
  - Read total supply via `STATICCALL`:
    - Call `token` with selector `0x18160ddd`.
    - Decode returned bytes as `uint256 totSup` (same behavior as Solidity `abi.decode`).
    - If decoding fails, revert.
  - Adjust `totSup` with Solidity-checked arithmetic semantics (revert on underflow/overflow):
    - if `give < prevBal`: `totSup = totSup - (prevBal - give)`
    - else: `totSup = totSup + (give - prevBal)`
  - Write `totalSupply() = totSup` using checked write.

Rationale:

- Many ERC20 implementations rely on `sum(balanceOf) == totalSupply`. Making this explicit avoids surprising behavior.

## Storage Resolution + Checked Write (Foundry Parity)

In `forge-std`, ERC20 `deal` is implemented via:

- `stdstore.target(token).sig(0x70a08231).with_key(to).checked_write(give);`
- (optional) `stdstore.target(token).sig(0x18160ddd).checked_write(totSup);`

HEVM's ERC20 `deal` overloads MUST behave equivalently at the EVM state level:

- If `balanceOf(to)` returns `x` before the cheat, it returns `give` after the cheat.
- If `adjustTotalSupply == true`, `totalSupply()` is updated by `give - prevBal` using checked arithmetic.
- Slot resolution and writes must be "checked" (verified) as described below.

### `checked_write` contract-level semantics

Given:

- `target` = token address
- `sig` = function selector (e.g. `0x70a08231` or `0x18160ddd`)
- `keys` = ABI-flattened keys (for `balanceOf(to)`: one key = `bytes32(uint256(uint160(to)))`; for `totalSupply()`: no keys)
- `set` = desired `bytes32` value (for uint256: `bytes32(give)` / `bytes32(totSup)`)
- `depth` = 0 (first return word only; matches forge-std defaults used by `deal`)

The implementation MUST:

1. Compute calldata `cd = sig || keys` (same as forge-std `StdStorage.callTarget` with default params).
2. Implement a helper `callTarget()`:
   - Execute `STATICCALL(target, cd)` producing `(success, returndata)`.
   - Extract `result = bytesToBytes32(returndata, 32 * depth)`.
     - For `deal`, `depth` is 0, so this is the first 32-byte return word.
     - If `returndata` is shorter than `32 * (depth + 1)`, treat `result` as `bytes32(0)` (matches forge-std behavior).
   - Return `(success, result)`.
3. Resolve the storage slot (forge-std `StdStorage.find` behavior):
   - Enable recording of storage accesses for the next call.
   - Execute `(_, callResult) = callTarget()` (forge-std ignores `success` here).
   - Obtain the list of storage read slots `reads[]` from the recorded call.
     - If `reads.length == 0`, revert (equivalent to forge-std: "No storage use detected for target.").
   - Iterate `reads` from last to first, and pick the first slot `slot` such that:
     - Let `prev = LOAD(target, slot)` (the current slot value).
     - The slot mutates the call result (forge-std `checkSlotMutatesCall` behavior):
       - Let `prevSlotValue = LOAD(target, slot)`.
       - Let `(success0, prevReturnValue) = callTarget()`.
       - Choose `testVal` exactly like forge-std:
         - if `prevReturnValue == 0`: `testVal = type(uint256).max`
         - else: `testVal = 0`
       - Write `STORE(target, slot, testVal)`.
       - Execute `(_, newReturnValue) = callTarget()` (forge-std ignores `success` here).
       - Restore: `STORE(target, slot, prevSlotValue)`.
       - Require `success0 == true` and `prevReturnValue != newReturnValue`.
     - Require `prev == callResult` (unpacked slot; no packed-offset logic).
   - If no `slot` matches, revert (equivalent to forge-std: "Slot(s) not found.").
4. Perform the write and verify (forge-std `checked_write` behavior):
   - Let `curVal = LOAD(target, slot)`.
   - Write `STORE(target, slot, set)`.
   - Execute `(success1, callResult1) = callTarget()`.
   - If `success1 == false` or `callResult1 != set`, restore `STORE(target, slot, curVal)` and revert (equivalent to forge-std: "Failed to write value.").

Notes:

- Packed slot support is intentionally out-of-scope for ERC20 `deal` parity: forge-std does not enable packed slots in `StdCheats.deal`.
- The `STATICCALL` used for slot discovery is allowed to revert; in forge-std this typically results in "slot not found" later, but `StdCheats.deal` usually fails earlier at `abi.decode` if return data is not a uint256.
- This algorithm works for mapping-based balances and for any token where `balanceOf(to)` is sourced from a single storage slot read.

### Caching (optional, recommended)

Forge-std caches discovered slots by `(target, sig, keccak256(params, depth), depth)`, where `params` are the flattened keys bytes.

HEVM may cache similarly for performance, but MUST NOT change observable behavior.

## Proxy Considerations

If `token` is a delegatecall-based proxy, the algorithm still applies as long as `STATICCALL(token, balanceOf/to)` executes and results in storage reads against `token`'s storage.

## Symbolic Execution Behavior

Minimum acceptable behavior:

- ERC20 `deal` is supported in concrete execution.
- In symbolic execution:
  - If `token` and `to` are not concretizable, revert with a clear "not supported in symbolic mode for symbolic addresses" error, or mark the path partial (implementation choice).

Rationale:

- Slot resolution depends on concrete execution (addresses, calldata, and storage keys must be concretizable).

## Errors / Reverts

ERC20 `deal` failures MUST revert/raise a cheatcode error (do not silently no-op). For Foundry parity, the failure conditions should align with `StdStorage.find` / `StdStorage.checked_write`:

- no storage reads detected for the target call
- slot(s) not found among read slots
- write verification failed (after writing, the call does not return the requested value)

Do not silently no-op.

## Determinism / Safety

- No host IO, no FFI gating required, no network.
- Slot discovery may temporarily mutate candidate slots but MUST restore them before returning (matching forge-std behavior).

## Minimal Test Plan

1. Standard ERC20 mapping.
   - Deploy a simple token with `mapping(address => uint256) public balanceOf;`
   - Call `deal(token, user, amount)`
   - Assert `balanceOf(user) == amount`

2. Total supply adjustment.
   - Record `oldBalance` and `oldTotalSupply`
   - Call `deal(token, user, newBalance, true)`
   - Assert `balanceOf(user) == newBalance`
   - Assert `totalSupply == oldTotalSupply +/- delta` (checked arithmetic; revert on underflow/overflow)

3. Failure modes.
   - Token without `balanceOf(address)` selector: must revert with clear error.
   - Token whose `balanceOf` reverts: must revert with clear error.

4. Cache hit.
   - Call `deal` twice for same token and different users; second call should not need probing (validate via internal counters/logging if available).

## Manual Fallback (Documentation)

If automatic resolution fails for a token, users can set balances manually with existing storage cheats:

- `store(token, slot, value)`

Where `slot` can be obtained from compiler storage layout, source inspection, or external tooling.
