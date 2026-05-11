// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {IUniswapV2Factory, IUniswapV2Pair, IUniswapV2Router02} from "../../../contracts/marketplace/interfaces/IUniswapV2.sol";
import {IFeeRouter} from "../../../contracts/marketplace/interfaces/IFeeRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockFeeRouter is IFeeRouter {
    event Routed(RevenueSource src, bytes32 capsuleId, address publisher, uint256 amount);
    uint256 public totalRouted;
    receive() external payable {}

    function routeETH(RevenueSource src, bytes32 capsuleId, address publisher) external payable override {
        totalRouted += msg.value;
        emit Routed(src, capsuleId, publisher, msg.value);
    }
    function routeERC20(RevenueSource, bytes32, address, address, uint256) external pure override {}
    function getSplitProfile(RevenueSource) external pure override returns (SplitProfile memory) {
        return SplitProfile({publisherBps: 0, nftHoldersBps: 0, stakersBps: 0, treasuryBps: 0, configured: false});
    }
    function setSplitProfile(RevenueSource, SplitProfile calldata) external pure override {}
    function capsuleRevenue(bytes32, address) external pure override returns (uint256) { return 0; }
    function publisherRevenue(address, address) external pure override returns (uint256) { return 0; }
}

contract MockPair is IUniswapV2Pair {
    address public override token0;
    address public override token1;
    uint112 r0;
    uint112 r1;
    uint32  bts;
    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }
    function getReserves() external view override returns (uint112, uint112, uint32) { return (r0, r1, bts); }
    function setReservesFor(address tokenA, uint112 amtA, uint112 amtB) external {
        if (tokenA == token0) { r0 = amtA; r1 = amtB; }
        else                  { r0 = amtB; r1 = amtA; }
        bts = uint32(block.timestamp);
    }
    function setReserves(uint112 a, uint112 b) external { r0 = a; r1 = b; bts = uint32(block.timestamp); }
}

contract MockUniV2Factory is IUniswapV2Factory {
    mapping(address => mapping(address => address)) internal _pairs;

    function getPair(address a, address b) external view override returns (address) {
        return _pairs[a][b];
    }
    function createPair(address a, address b) external override returns (address) {
        require(_pairs[a][b] == address(0), "EXISTS");
        MockPair p = new MockPair(a, b);
        _pairs[a][b] = address(p);
        _pairs[b][a] = address(p);
        return address(p);
    }
    function setPreSeededPair(address a, address b, address p, uint112 r0, uint112 r1) external {
        _pairs[a][b] = p;
        _pairs[b][a] = p;
        if (r0 != 0 || r1 != 0) MockPair(p).setReserves(r0, r1);
    }
}

contract MockUniV2Router is IUniswapV2Router02 {
    address public override factory;
    address public immutable wethAddr;

    constructor(address f, address w) { factory = f; wethAddr = w; }
    function WETH() external view override returns (address) { return wethAddr; }

    bool public failNext;
    uint256 public dustEth;
    uint256 public dustToken;
    function setFailNext(bool v) external { failNext = v; }
    function setDust(uint256 e, uint256 t) external { dustEth = e; dustToken = t; }

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable override returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        require(!failNext, "MOCK_FAIL");
        require(deadline >= block.timestamp, "EXPIRED");

        amountToken = amountTokenDesired - dustToken;
        amountETH   = msg.value - dustEth;

        require(amountToken >= amountTokenMin, "TKN_MIN");
        require(amountETH >= amountETHMin, "ETH_MIN");

        IERC20(token).transferFrom(msg.sender, address(this), amountToken);

        liquidity = amountToken + amountETH;
        address pair = IUniswapV2Factory(factory).getPair(token, wethAddr);
        if (pair == address(0)) {
            pair = IUniswapV2Factory(factory).createPair(token, wethAddr);
        }
        MockPair(pair).setReservesFor(token, uint112(amountToken), uint112(amountETH));

        if (dustEth > 0) {
            (bool ok, ) = msg.sender.call{value: dustEth}("");
            require(ok, "refund");
        }
    }
}
