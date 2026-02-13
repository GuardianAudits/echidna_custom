# Echidna Custom + HEVM - Release 2.2

This release extends HEVM's `deal` cheatcode to match Foundry/forge-std behavior for ERC20s, enabling deterministic ERC20 balance setting during Echidna fuzzing without mint/transfer calls. It also adds Foundry-compatible storage access recording cheatcodes (`record()` / `accesses(address)`) used by forge-std `StdStorage` workflows.

## Highlights
- Added forge-std compatible ERC20 overloads:
  - `deal(address token, address to, uint256 give)`
  - `deal(address token, address to, uint256 give, bool adjustTotalSupply)`
- Preserves existing native ETH `deal(address who, uint256 give)`
- Implements `StdStorage.checked_write`-style slot discovery + verification (like forge-std `StdCheats.deal`)
- Added Foundry-compatible storage access recording cheatcodes:
  - `record()`
  - `accesses(address)`

---

## 1) ERC20 `deal` Cheatcode (Foundry Parity)

### What it does
- Forces `token.balanceOf(to)` to return `give` by directly mutating the token's storage slot.
- Optionally adjusts `token.totalSupply()` by `(give - prevBal)` when `adjustTotalSupply=true` (Solidity checked arithmetic; reverts with `Panic(0x11)` on under/overflow).

### What it does not do
- No `mint`/`transfer` calls.
- No `Transfer` events.
- No allowance updates.

### Slot discovery + verification
Implements the same high-level algorithm used by forge-std:
- `STATICCALL` the target function (`balanceOf(to)` or `totalSupply()`) and collect storage reads.
- Probe candidate read slots by temporarily flipping values and requiring the function return value to change.
- Perform the write and verify by re-calling the function (revert + restore if verification fails).

Reference spec: `spec_deal.md`.

---

## 2) Solidity Interface + Usage

```solidity
interface IHevmCheatcodes {
    // native ETH
    function deal(address who, uint256 give) external;

    // ERC20
    function deal(address token, address to, uint256 give) external;
    function deal(address token, address to, uint256 give, bool adjustTotalSupply) external;

    // Foundry-compatible storage access recording
    function record() external;
    function accesses(address target) external returns (bytes32[] memory reads, bytes32[] memory writes);
}

IHevmCheatcodes hevm = IHevmCheatcodes(
    address(uint160(uint256(keccak256("hevm cheat code"))))
);
```

Example:
```solidity
hevm.deal(address(token), user, 1e18);
hevm.deal(address(token), user, 1e18, true);

hevm.record();
// ... run code that touches token storage ...
(bytes32[] memory reads, bytes32[] memory writes) = hevm.accesses(address(token));
```

---

## 3) Tests + Benchmarks

- HEVM concrete tests:
  - `hevm/test/test.hs` (ERC20 `deal` no-adjust + adjustTotalSupply increase/decrease)
  - `hevm/test/test.hs` (`record()` / `accesses(address)` read + write semantics)
- HEVM benchmark:
  - `hevm/bench/bench-perf.hs` (`dealErc20` benchmark group)

---

## 4) Known Limitations

- ERC20 `deal` is concrete-only in this custom branch.
- Tokens with packed balances, rebasing/custom accounting, or multi-slot balance computations may fail slot discovery and revert.

