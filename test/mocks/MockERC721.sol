// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

contract MockERC721 {
    string public name;
    string public symbol;
    mapping(address => uint256) public balanceOf;
    mapping(uint256 => address) public ownerOf;
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == address(0), "exists");
        ownerOf[tokenId] = to;
        balanceOf[to] += 1;
        totalSupply += 1;
        emit Transfer(address(0), to, tokenId);
    }
}
