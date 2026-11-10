// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.20;

contract Child {
    uint256 public immutable value;
    constructor(uint256 x) { value = x; }
}

// Models a factory using initcode built earlier, such as a forked Wildcat factory.
contract Factory {
    bytes private storedInitcode;
    constructor() { storedInitcode = hex"60b738038060b760e03960e001601f01601f191660405260e08060b738030190602001113417603e5760e05160c05260758060425f3960c0516014525ff35b5f5ffd34603a575f3560e01c80633fa4f24503603a577f00000000000000000000000000000000000000000000000000000000000000005f5260205ff35b5f5ffdfea26469706673582212204fbe4423d375d277b498ecee2b51f183fc2797f1f3f26df10f7e330b6f95acd465736f6c6172430003000034"; }
    function deploy(uint256 x) external {
        bytes memory initcode = abi.encodePacked(storedInitcode, abi.encode(x));
        address child;
        assembly { child := create(0, add(initcode, 32), mload(initcode)) }
        require(child != address(0));
        require(Child(child).value() == x);
    }
    function echidna_ok() external pure returns (bool) { return true; }
}
