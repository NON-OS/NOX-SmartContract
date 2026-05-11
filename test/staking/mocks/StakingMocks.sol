// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MockNOX is ERC20 {
    constructor() ERC20("MockNOX", "MNOX") {
        _mint(msg.sender, 1_000_000_000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockZeroStatePass is ERC721 {
    uint256 public nextId = 1;

    constructor() ERC721("MockZSP", "MZSP") {}

    function mint(address to, uint256 count) external {
        for (uint256 i = 0; i < count; i++) {
            _mint(to, nextId++);
        }
    }
}
