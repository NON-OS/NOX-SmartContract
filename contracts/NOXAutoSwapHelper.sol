// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IUniswapV2Router02 {
    function WETH() external view returns (address);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline
    ) external;
}

/// @title NOXAutoSwap - Instant tax swapping w/ manual/auto trigger-script 
/// @notice Receives NOX fees and swaps to ETH
contract NOXAutoSwap {
    address public immutable noxToken;
    address public immutable router;
    address public immutable liquidityCollector;
    address public immutable treasury; 
    address public immutable devWallet;
    uint16 public immutable liquidityShare; // 4000 = 40%
    uint16 public immutable treasuryShare;  // 2000 = 20%
    uint16 public immutable devShare;       // 3000 = 30%
    uint16 public constant BPS = 10000;
    
    bool private inSwap;
    modifier swapping() { inSwap = true; _; inSwap = false; }

    constructor(
        address _noxToken,
        address _router, 
        address _liquidityCollector,
        address _treasury,
        address _devWallet
    ) {
        noxToken = _noxToken;
        router = _router;
        liquidityCollector = _liquidityCollector;
        treasury = _treasury;
        devWallet = _devWallet;
        liquidityShare = 4000; // 40%
        treasuryShare = 2000;  // 20% 
        devShare = 3000;       // 30%
    }

    /// @notice Called automatically when NOX fees are sent here
    receive() external payable {
        // Handle ETH if needed
    }

    /// @notice Automatically swap any NOX received
    function autoSwap() external {
        if (inSwap) return;
        uint256 noxBalance = IERC20(noxToken).balanceOf(address(this));
        if (noxBalance > 0) {
            _swapAndDistribute(noxBalance);
        }
    }

    /// @notice Internal swap and distribute
    function _swapAndDistribute(uint256 amount) private swapping {
        // Approve router
        IERC20(noxToken).approve(router, amount);
        
        // Swap NOX -> ETH
        address[] memory path = new address[](2);
        path[0] = noxToken;
        path[1] = IUniswapV2Router02(router).WETH();
        
        try IUniswapV2Router02(router).swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount, 0, path, address(this), block.timestamp
        ) {
            // Distribute ETH
            uint256 ethBalance = address(this).balance;
            if (ethBalance > 0) {
                uint256 toLiq = (ethBalance * liquidityShare) / BPS;
                uint256 toTre = (ethBalance * treasuryShare) / BPS;
                uint256 toDev = ethBalance - toLiq - toTre;
                
                if (toLiq > 0) payable(liquidityCollector).transfer(toLiq);
                if (toTre > 0) payable(treasury).transfer(toTre);
                if (toDev > 0) payable(devWallet).transfer(toDev);
            }
        } catch {
            // If swap fails, do nothing (keep NOX)
        }
    }

    /// @notice Trigger swap manually if needed
    function triggerSwap() external {
        if (inSwap) return;
        uint256 noxBalance = IERC20(noxToken).balanceOf(address(this));
        if (noxBalance > 0) {
            _swapAndDistribute(noxBalance);
        }
    }
}
