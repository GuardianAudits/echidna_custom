contract SnapshotStore {
  uint256 public slot0;
  function set(uint256 v) public { slot0 = v; }
  function add(uint256 v) public payable { slot0 += v; }
  function boom() public { revert(); }
  function echidna_true() public returns (bool) { return true; }
}
