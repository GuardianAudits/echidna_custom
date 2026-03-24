pragma solidity ^0.8.0;

contract ShrinkBug {
  uint256 public balance;

  function fuzz_deposit(uint256 amount) external {
    require(amount >= 10, "too small");
    balance += amount;
  }

  function fuzz_withdraw() external {
    require(balance > 0, "nothing to withdraw");
    uint256 mode = uint256(keccak256(abi.encode(block.number))) % 997;
    balance = 0;
    assert(mode != 42);
  }
}
