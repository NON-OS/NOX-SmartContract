// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {MockERC20} from "../../mocks/MockERC20.sol";

contract MockSwapRouter {
    uint256 public immutable rate;
    address public immutable token;
    bool public failNext;

    constructor(address tok, uint256 rate_) { token = tok; rate = rate_; }
    function setFailNext(bool v) external { failNext = v; }
    receive() external payable {}

    function buyTokenWithEth(address to, uint256 minOut) external payable returns (uint256 out) {
        if (failNext) { failNext = false; revert("MOCK_REVERT"); }
        out = (msg.value * rate) / 1e18;
        require(out >= minOut, "MIN_OUT");
        MockERC20(token).mint(to, out);
    }

    function sellTokenForEth(uint256 amountIn, address to, uint256 minOut) external returns (uint256 out) {
        if (failNext) { failNext = false; revert("MOCK_REVERT"); }
        MockERC20(token).transferFrom(msg.sender, address(this), amountIn);
        out = (amountIn * rate) / 1e18;
        require(out >= minOut, "MIN_OUT");
        (bool ok, ) = to.call{value: out}("");
        require(ok, "ETH_FAIL");
    }
}

contract MockBondingToken is MockERC20 {
    address public immutable nox;
    uint256 public immutable rate;
    constructor(address nox_, uint256 rate_) MockERC20("APP", "APP") { nox = nox_; rate = rate_; }

    function buy(uint256 noxIn, uint256 minOut) external returns (uint256 out) {
        MockERC20(nox).transferFrom(msg.sender, address(this), noxIn);
        out = (noxIn * rate) / 1e18;
        require(out >= minOut, "MIN_OUT");
        this.mint(msg.sender, out);
    }
    function sell(uint256 tokIn, uint256 minOut) external returns (uint256 out) {
        MockERC20(this).transferFrom(msg.sender, address(this), tokIn);
        out = (tokIn * 1e18) / rate;
        require(out >= minOut, "MIN_OUT");
        MockERC20(nox).transfer(msg.sender, out);
    }
}

contract MockFoTERC20 {
    string public name = "FoT";
    string public symbol = "FoT";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    uint16 public feeBps = 500;
    address public sink = address(0xFEE);
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 v);
    event Approval(address indexed o, address indexed s, uint256 v);

    function mint(address to, uint256 a) external {
        balanceOf[to] += a; totalSupply += a; emit Transfer(address(0), to, a);
    }
    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a; emit Approval(msg.sender, s, a); return true;
    }
    function transfer(address to, uint256 a) external returns (bool) { return _xfer(msg.sender, to, a); }
    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[from][msg.sender]; require(al >= a, "alw");
        if (al != type(uint256).max) allowance[from][msg.sender] = al - a;
        return _xfer(from, to, a);
    }
    function _xfer(address from, address to, uint256 a) internal returns (bool) {
        uint256 f = (a * feeBps) / 10000;
        balanceOf[from] -= a;
        balanceOf[to] += (a - f);
        balanceOf[sink] += f;
        emit Transfer(from, to, a - f);
        emit Transfer(from, sink, f);
        return true;
    }
}

contract MockAppTokenFactory {
    mapping(address => bool) public knownToken;
    function setKnown(address t, bool v) external { knownToken[t] = v; }
    function isAppToken(address t) external view returns (bool) { return knownToken[t]; }
}

contract MockPartialPull {
    address public token;
    uint256 public takeBps;
    constructor(address t, uint256 bps) { token = t; takeBps = bps; }
    function partialPull(address from, uint256 declared, address /*to*/) external {
        uint256 take = (declared * takeBps) / 10000;
        MockERC20(token).transferFrom(from, address(this), take);
    }
}

contract MockEthRefunder {
    address public token;
    uint256 public refundWei;
    constructor(address t, uint256 r) { token = t; refundWei = r; }
    function buyAndRefund(address to, uint256 minOut) external payable returns (uint256 out) {
        out = msg.value * 100;
        require(out >= minOut, "min");
        MockERC20(token).mint(to, out);
        if (refundWei > 0 && address(this).balance >= refundWei) {
            (bool ok, ) = msg.sender.call{value: refundWei}("");
            require(ok, "refund");
        }
    }
    receive() external payable {}
}
