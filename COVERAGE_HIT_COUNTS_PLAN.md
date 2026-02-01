# Per-Line Coverage Hit Counts — Design Plan

Goal: show **line hit counts** for every line already present in the coverage reports (protocol-wide, not just tests), without changing coverage semantics.

---

## 1) Data model & collection

**Change:** store a hit counter per opcode in coverage.

**Files**
- `lib/Echidna/Types/Coverage.hs`
- `lib/Echidna/Exec.hs`

**Plan**
- Extend coverage info:
  - From: `type CoverageInfo = (OpIx, StackDepths, TxResults)`
  - To:   `type CoverageInfo = (OpIx, StackDepths, TxResults, HitCount)` where `HitCount = Word64`
- Initialize `hitCount = 0` for every instruction.
- Increment hitCount on **every EVM step** inside `execTxWithCov` when PC is in bounds.
- Keep existing “new coverage” logic (opIx/depth/txResult) unchanged.

---

## 2) Line-level aggregation

**Files**
- `lib/Echidna/Output/Source.hs`

**Plan**
- Update `srcMapCov` to aggregate **both**:
  - `hitCount` per line (sum of opcode hits mapped to that line)
  - `TxResults` per line (existing markers)
- Use a line-level structure:
  - `LineCov { hits :: Word64, results :: [TxResult] }`

---

## 3) Output formats

### HTML coverage
**Files**
- `lib/Echidna/Output/Source.hs`
- `lib/Echidna/Output/assets/coverage.mustache`
- `lib/Echidna/Output/assets/styles.mustache`

**Plan**
- Add a **hits column** in the code table.
- Show hit count per line; non-executable lines display blank or `—`.
- Tooltip: `Hit count: N`.

### TXT coverage
**Files**
- `lib/Echidna/Output/Source.hs`

**Plan**
- Expand line format from:
  ```
  <line> | <markers> | <code>
  ```
  to:
  ```
  <line> | <hits> | <markers> | <code>
  ```

### LCOV coverage
**Files**
- `lib/Echidna/Output/Source.hs`

**Plan**
- Use **actual hit count** for `DA:<line>,<count>` instead of `length results`.

---

## 4) JSON output (optional, recommended)

**Files**
- `src/Main.hs` or `lib/Echidna/Output/JSON.hs`

**Plan**
- Add new `coverage_hits.json` next to coverage reports:
  ```json
  {
    "path/to/File.sol": {
      "42": 128,
      "43": 0
    }
  }
  ```
- Keeps current JSON output backward compatible.

---

## 5) Config / flags

**Recommended behavior:** always collect hit counts when coverage is enabled (low overhead).

**Display toggle**
- Config: `coverageLineHits: true` (default true)
- CLI: `--coverage-line-hits true|false`

If false, output is identical to current (no hit counts printed).

---

## 6) Tests / regression

**Files**
- `src/test/Tests/Coverage.hs` (or new small fixture)

**Plan**
- Add a small contract with a few lines.
- Assert HTML/TXT/LCOV include expected line hit counts.

---

## Decisions (recommended)

1) **Always collect hit counts when coverage is enabled?**  
   Recommended: **Yes**.

2) **Add `coverage_hits.json`?**  
   Recommended: **Yes**, to avoid breaking current JSON consumers.

