// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IERC20Like {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract MockPair {
    uint112 public r0;
    uint112 public r1;
    address public _t0;

    function setReserves(uint112 a, uint112 b) external {
        r0 = a;
        r1 = b;
    }

    function setToken0(address t) external {
        _t0 = t;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (r0, r1, uint32(block.timestamp));
    }

    function token0() external view returns (address) {
        return _t0;
    }
}

contract MockFactory {
    mapping(address => mapping(address => address)) public pairs;

    function setPair(address a, address b, address p) external {
        pairs[a][b] = p;
        pairs[b][a] = p;
    }

    function getPair(address a, address b) external view returns (address) {
        return pairs[a][b];
    }
}

contract MockRouter {
    address public weth;
    address public _factory;
    bool public revertOnSwap;
    uint256 public ethToReturn;

    constructor(address _weth, address fac) payable {
        weth = _weth;
        _factory = fac;
    }

    receive() external payable {}

    function setRevert(bool b) external {
        revertOnSwap = b;
    }

    function setEthToReturn(uint256 v) external {
        ethToReturn = v;
    }

    function factory() external view returns (address) {
        return _factory;
    }

    function WETH() external view returns (address) {
        return weth;
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external {
        if (revertOnSwap) revert("router-revert");
        require(IERC20Like(path[0]).transferFrom(msg.sender, address(this), amountIn), "pull");
        require(ethToReturn >= amountOutMin, "INSUFFICIENT_OUTPUT_AMOUNT");
        (bool ok,) = payable(to).call{value: ethToReturn}("");
        require(ok, "send");
    }
}

contract RevertOnReceive {
    receive() external payable {
        revert("nope");
    }
}

contract ToggleReceive {
    bool public reverts = true;

    function flip() external {
        reverts = !reverts;
    }

    function callClaim(address nox) external {
        (bool ok,) = nox.call(abi.encodeWithSignature("claimFailedEth()"));
        require(ok, "claim failed");
    }

    receive() external payable {
        if (reverts) revert("nope");
    }
}
