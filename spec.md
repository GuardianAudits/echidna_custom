# Logical Coverage (Echidna‑only) — Specification

**Goal:** Provide *logical coverage from the first run* by tracking call success/failure ratios and **parameter ranges** per function, without relying on any hevm cheatcode. This is entirely implemented inside Echidna.

---

## 1) Scope

- **In scope**: Tracking outcomes and input distributions for all calls Echidna generates.
- **Out of scope**: VM changes, Solidity changes, and hevm cheatcodes.
- **Primary user value**:
  - Success rate per function
  - Parameter ranges that succeed vs. fail
  - Revert reasons (aggregated)

---

## 2) Data model

### 2.1 Keying
Each method is keyed by **full signature**:
```
<ContractName>.<methodName>(<canonical types>)
```
If name collisions exist, key by `selector + types + contract`.

### 2.2 CallStats (per method)
```
CallStats
  totalCalls        :: Int
  successCalls      :: Int
  failedCalls       :: Int
  firstSuccessAt    :: Maybe Int   -- iteration index
  lastSuccessAt     :: Maybe Int
  revertReasons     :: TopNMap ReasonKey Int
  calldataLenMin    :: Int
  calldataLenMax    :: Int
  argStatsSuccess   :: [ParamStats]
  argStatsFailure   :: [ParamStats]
```

### 2.3 ParamStats (per argument)
For each ABI arg (per success/failure bucket):

- **Numeric** (uint/int):
  - min, max, count
  - optional histogram buckets (N=10)
- **Bool**:
  - trueCount / falseCount
- **Address**:
  - min/max (lexicographic)
  - approxUnique (HyperLogLog or capped set)
- **Bytes/String**:
  - minLen, maxLen
  - optional hash samples (bounded)
- **Array/Tuple**:
  - length min/max
  - per‑element ParamStats (bounded depth/size)

All ParamStats should support **merge** (for multi‑worker aggregation).

---

## 3) Revert reason decoding

If a call fails:
- If `returndata` matches `Error(string)`, record reason string
- If `Panic(uint256)`, record panic code
- Otherwise record: `CustomError(selector)` or `UnknownRevert(len)`

Reasons are stored in a **Top‑N** map to cap memory.

---

## 4) Integration points (Echidna)

We capture stats **after each executed call**, at the point Echidna already has:
- the ABI `Method`
- the `AbiValue` list (actual arguments)
- the execution result (success/failure + returndata)

Candidate hook points:
- `Echidna/Campaign.hs` (after tx execution / result integration)
- `Echidna/Exec.hs` (after VM run result)

**Requirement:** stats update must happen regardless of revert so that failure ranges are captured.

---

## 5) Output & UI

### 5.1 End‑of‑run summary
Add a “Logical coverage” section, e.g.:
```
Logical coverage:
  operate(uint256,bytes): 72% success (36/50)
    arg0 success range: [1..1_000_000]
    arg0 failure range: [0..0]
    revert reasons: Error("insufficient collateral") x8, Panic(0x11) x3
```

### 5.2 Live UI (interactive)
Add a compact line for the **top failing** or **most called** method:
```
logic: operate(uint256,bytes) 36/50 ok, arg0=[1..1e6]
```

### 5.3 JSON artifact
Write a JSON report under the **corpus directory** (if configured):
```
<corpusDir>/logical_coverage.json
```
If `corpusDir` is not set, write to:
```
./logical_coverage.json
```

---

## 6) Performance & limits

To keep memory bounded:
- Limit top‑N methods in UI (default: 10)
- Limit revert reasons per method (default: 10)
- Limit bytes/string samples (default: 20)
- Array/tuple depth limit (default: 2)
- Optional: drop stats after N methods (or keep most‑called)

---

## 7) Configuration

Add optional CLI flags / config:
- `logicalCoverage: true|false` (default: true)
- `logicalCoverageTopN: Int`
- `logicalCoverageMaxReasons: Int`
- `logicalCoverageMaxSamples: Int`
- `logicalCoverageMaxDepth: Int`

---

## 8) Merge behavior (multi‑worker)

Stats must merge across workers:
- Sum counters
- Merge min/max
- Merge histograms
- Merge top‑N revert reason maps

---

## 9) Minimal MVP

MVP (fast to ship):
- Per‑method total/success/failure
- Per‑method calldata length min/max
- Revert reason Top‑N
- ParamStats only for numeric + bool

Later: add bytes/address/arrays/tuples

---

## 10) Decisions (confirmed)

The following choices are confirmed by the user and will be used in implementation:

1) **Method key**: `Contract.method(types)` (human‑readable)  
2) **Top‑N policy**: show **methods with any failures** first  
3) **Output priority**: highlight **top failures** in summary  
4) **Numeric ranges**: **min/max only** (no histograms in v1)  
5) **Revert reason storage**: store **full strings** (Error(string)) and Panic codes  
6) **JSON output**: **aggregated stats only** (no raw samples)  
7) **Default config**: **enabled by default**  

---

If you confirm the answers above, I can implement this without touching hevm.
