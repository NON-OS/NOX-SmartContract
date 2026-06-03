// SPDX-License-Identifier: MIT
// ███╗   ██╗ ██████╗ ███╗   ██╗ ██████╗ ███████╗
// ████╗  ██║██╔═══██╗████╗  ██║██╔═══██╗██╔════╝
// ██╔██╗ ██║██║   ██║██╔██╗ ██║██║   ██║███████╗
// ██║╚██╗██║██║   ██║██║╚██╗██║██║   ██║╚════██║
// ██║ ╚████║╚██████╔╝██║ ╚████║╚██████╔╝███████║
// ╚═╝  ╚═══╝ ╚═════╝ ╚═╝  ╚═══╝ ╚═════╝ ╚══════╝
//
//  NONOS  ::  NOX TOKEN  ::  V3
//  Hardened, fee-capped (max 3%), auto-liquidity ERC-20.
//  Native asset of the NONOS operating system.
//
//  - No pause / no freeze / no seize / no anti-whale traps.
//  - Buy 0% / Sell 3% : 10% burned, 90% paired into locked NOX/WETH liquidity.
//  - Blacklist is one-way renounceable. UUPS, governed by a 3-of-5 multisig.
//
pragma solidity 0.8.24;


import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20BurnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {
    ERC20PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

interface IPriceImpactController {
    function onBeforeSell(address from, uint256 amount) external view;
}

interface IUniswapV2Router02 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
}

contract NONOS_NOX_MAINNET_V3 is
    Initializable,
    UUPSUpgradeable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ERC20PermitUpgradeable,
    ERC20PausableUpgradeable,
    AccessControlUpgradeable
{
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    uint256 public constant MAX_SUPPLY = 800_000_000e18;
    uint16 public constant BPS = 10_000;
    uint16 public constant MAX_FEE_BPS = 300;
    uint16 public constant MAX_DEF_BPS = 200;
    uint16 public constant MAX_SUM_BPS = 2_000;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct FeeConfig {
        uint16 buyBps;
        uint16 sellBps;
        uint16 transferBps;
        uint16 burnShareBps;
        uint16 liquidityShareBps;
        uint16 treasuryShareBps;
        uint16 devShareBps;
    }
    FeeConfig public fees;

    uint16 public deflationBps;
    uint16 public alphaBps;
    uint16 public emaDecayBps;
    uint256 public vEmaBps;
    uint256 public totalBurned;

    address public devWallet;
    address public stakingVault;
    address public daoWallet;
    address public liquidityCollector;
    address public cexListingsWallet;
    address public contributorsWallet;
    address public nftsWallet;
    address public marketingWallet;
    address public treasury;

    mapping(address => bool) private _isLpPair;
    address[] private _lpPairsList;
    mapping(address => bool) public feeExempt;
    mapping(address => bool) public limitsExempt;
    mapping(address => bool) public blacklisted;
    mapping(address => uint256) public lastTxBlock;
    mapping(address => uint64) public lastSellTime;

    bool public sameBlockGuardEnabled;
    bool public txLimitEnabled;
    bool public walletLimitEnabled;
    uint16 public maxTxBps;
    uint16 public maxWalletBps;
    uint64 public sellCooldown;
    bool public emergencyStop;

    IPriceImpactController public priceImpactController;

    IUniswapV2Router02 public uniswapRouter;
    address public uniswapPair;
    uint256 public autoSwapThreshold;
    uint16 public autoSwapSlippageBps;
    bool public autoSwapEnabled;
    bool private _inSwap;
    bool public v2Initialized;

    uint256 public maxAutoSwapChunk;
    address public ethFallbackRecipient;
    mapping(address => uint256) public failedEth;
    uint256 public totalFailedEth;

    uint256[28] private __noxGapV2;
    bool public blacklistRenounced;

    event FeesUpdated(FeeConfig fees);
    event DeflationUpdated(uint16 deflationBps, uint16 alphaBps, uint16 emaDecayBps);
    event RecipientsUpdated(address devWallet, address stakingVault, address daoWallet, address liquidityCollector);
    event AuxRecipientsUpdated(
        address cexListingsWallet, address contributorsWallet, address nftsWallet, address marketingWallet
    );
    event PairStatusUpdated(address indexed pair, bool isPair);
    event ExemptionsUpdated(address indexed account, bool feeExempt, bool limitsExempt);
    event GuardsUpdated(
        bool sameBlock, bool txLimit, bool walletLimit, uint16 maxTxBps, uint16 maxWalletBps, uint64 sellCooldown
    );
    event PriceImpactControllerSet(address controller);
    event BlacklistUpdated(address indexed account, bool isBlacklisted);
    event EmergencyStopChanged(bool stopped);
    event SellCooldownEnforced(address indexed seller, uint64 timestamp);
    event AutoSwapExecuted(uint256 tokensSwapped, uint256 ethReceived);
    event AutoLiquify(uint256 tokensIntoLp, uint256 ethIntoLp);
    event BlacklistRenounced();
    event V2Initialized(address router);

    event AutoSwapConfigUpdated(uint256 threshold, uint16 slippageBps, bool enabled);
    event MaxAutoSwapChunkUpdated(uint256 maxChunk);
    event AutoSwapForwardFailed(address indexed recipient, uint256 amount);
    event AutoSwapFailed(uint256 tokenAmount, uint256 amountOutMin);
    event EthFallbackRecipientUpdated(address recipient);
    event RescueETH(address indexed to, uint256 amount);
    event FailedEthClaimed(address indexed recipient, uint256 amount);
    event V2_1Initialized(uint256 maxAutoSwapChunk, address ethFallbackRecipient);

    modifier lockTheSwap() {
        _inSwap = true;
        _;
        _inSwap = false;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address mainReceiver,
        address _devWallet,
        address _stakingVault,
        address _daoWallet,
        address _liquidityCollector,
        address _cexListingsWallet,
        address _contributorsWallet,
        address _nftsWallet,
        address _marketingWallet
    ) public initializer {
        require(
            mainReceiver != address(0) && _devWallet != address(0) && _stakingVault != address(0)
                && _daoWallet != address(0) && _liquidityCollector != address(0) && _cexListingsWallet != address(0)
                && _contributorsWallet != address(0) && _nftsWallet != address(0) && _marketingWallet != address(0),
            "0"
        );
        devWallet = _devWallet;
        stakingVault = _stakingVault;
        daoWallet = _daoWallet;
        liquidityCollector = _liquidityCollector;
        cexListingsWallet = _cexListingsWallet;
        contributorsWallet = _contributorsWallet;
        nftsWallet = _nftsWallet;
        marketingWallet = _marketingWallet;
        treasury = _daoWallet;
        _initOZ();
        _initRoles();
        _initMintsAndExempts(mainReceiver);
        _initFeeAndGuards();
    }

    function _initOZ() private {
        __UUPSUpgradeable_init();
        __ERC20_init("NONOS", "NOX");
        __ERC20Burnable_init();
        __ERC20Permit_init("NONOS");
        __ERC20Pausable_init();
        __AccessControl_init();
    }

    function _initRoles() private {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(GOVERNOR_ROLE, _msgSender());
        _grantRole(UPGRADER_ROLE, _msgSender());
        _grantRole(EMERGENCY_ROLE, _msgSender());
    }

    function _initMintsAndExempts(address mainReceiver) private {
        _mint(devWallet, (MAX_SUPPLY * 300) / BPS);
        _mint(stakingVault, (MAX_SUPPLY * 400) / BPS);
        _mint(daoWallet, (MAX_SUPPLY * 300) / BPS);
        _mint(liquidityCollector, (MAX_SUPPLY * 400) / BPS);
        _mint(cexListingsWallet, (MAX_SUPPLY * 400) / BPS);
        _mint(contributorsWallet, (MAX_SUPPLY * 300) / BPS);
        _mint(nftsWallet, (MAX_SUPPLY * 150) / BPS);
        _mint(marketingWallet, (MAX_SUPPLY * 250) / BPS);
        _mint(mainReceiver, MAX_SUPPLY - (MAX_SUPPLY * 2500) / BPS);
        _setExempt(_msgSender(), true, true);
        _setExempt(address(this), true, true);
        _setExempt(mainReceiver, true, true);
        _setExempt(devWallet, true, true);
        _setExempt(stakingVault, true, true);
        _setExempt(daoWallet, true, true);
        _setExempt(liquidityCollector, true, true);
        _setExempt(cexListingsWallet, true, true);
        _setExempt(contributorsWallet, true, true);
        _setExempt(nftsWallet, true, true);
        _setExempt(marketingWallet, true, true);
    }

    function _initFeeAndGuards() private {
        fees.buyBps = 250;
        fees.sellBps = 250;
        fees.transferBps = 0;
        fees.burnShareBps = 1000;
        fees.liquidityShareBps = 4000;
        fees.treasuryShareBps = 2000;
        fees.devShareBps = 3000;
        sameBlockGuardEnabled = true;
        txLimitEnabled = true;
        walletLimitEnabled = true;
        maxTxBps = 50;
        maxWalletBps = 400;
        sellCooldown = 20;
    }

    function initializeV2(address _router, uint256 _swapThreshold, uint16 _slippageBps)
        external
        onlyRole(GOVERNOR_ROLE)
    {
        require(!v2Initialized, "1");
        require(_router != address(0), "2");
        require(_slippageBps <= 300, "3");
        uniswapRouter = IUniswapV2Router02(_router);
        address pair = IUniswapV2Factory(uniswapRouter.factory()).getPair(address(this), uniswapRouter.WETH());
        require(pair != address(0), "4");
        uniswapPair = pair;
        _isLpPair[pair] = true;
        _lpPairsList.push(pair);
        autoSwapThreshold = _swapThreshold;
        autoSwapSlippageBps = _slippageBps;
        autoSwapEnabled = true;
        v2Initialized = true;
        _setExempt(address(this), true, true);
        _setExempt(_router, true, true);
        emit V2Initialized(_router);
    }

    function reinitV21(uint256 _maxAutoSwapChunk, address _ethFallbackRecipient)
        external
        reinitializer(2)
        onlyRole(UPGRADER_ROLE)
    {
        require(_maxAutoSwapChunk > 0, "k");
        require(_ethFallbackRecipient != address(0), "fb");

        maxAutoSwapChunk = _maxAutoSwapChunk;
        ethFallbackRecipient = _ethFallbackRecipient;

        address p = uniswapPair;
        if (p != address(0) && !limitsExempt[p]) {
            limitsExempt[p] = true;
            emit ExemptionsUpdated(p, feeExempt[p], true);
        }

        emit MaxAutoSwapChunkUpdated(_maxAutoSwapChunk);
        emit EthFallbackRecipientUpdated(_ethFallbackRecipient);
        emit AutoSwapConfigUpdated(autoSwapThreshold, autoSwapSlippageBps, autoSwapEnabled);
        emit V2_1Initialized(_maxAutoSwapChunk, _ethFallbackRecipient);
    }

    function setAutoSwapConfig(uint256 _threshold, uint16 _slippageBps, bool _enabled)
        external
        onlyRole(GOVERNOR_ROLE)
    {
        require(v2Initialized, "5");
        require(_slippageBps <= 300, "3");
        autoSwapThreshold = _threshold;
        autoSwapSlippageBps = _slippageBps;
        autoSwapEnabled = _enabled;
        emit AutoSwapConfigUpdated(_threshold, _slippageBps, _enabled);
    }

    function setMaxAutoSwapChunk(uint256 _max) external onlyRole(GOVERNOR_ROLE) {
        require(_max > 0, "k");
        maxAutoSwapChunk = _max;
        emit MaxAutoSwapChunkUpdated(_max);
    }

    function triggerAutoSwap() external onlyRole(GOVERNOR_ROLE) {
        _swapAndLiquify(balanceOf(address(this)));
    }

    function _swapAndLiquify(uint256 tokenAmount) private lockTheSwap {
        if (tokenAmount == 0) return;
        uint256 cap = maxAutoSwapChunk;
        if (cap > 0 && tokenAmount > cap) tokenAmount = cap;
        uint256 half = tokenAmount / 2;
        uint256 otherHalf = tokenAmount - half;
        if (half == 0 || otherHalf == 0) return;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapRouter.WETH();
        uint256 amountOutMin = _quoteAmountOutMin(half);
        uint256 ethBefore = address(this).balance;

        _approve(address(this), address(uniswapRouter), half);
        try uniswapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            half, amountOutMin, path, address(this), block.timestamp
        ) {
            uint256 ethGained = address(this).balance - ethBefore;
            if (ethGained == 0) {
                emit AutoSwapFailed(half, amountOutMin);
                return;
            }
            _approve(address(this), address(uniswapRouter), otherHalf);
            try uniswapRouter.addLiquidityETH{value: ethGained}(
                address(this), otherHalf, 0, 0, DEAD, block.timestamp
            ) returns (uint256 usedToken, uint256 usedEth, uint256) {
                emit AutoLiquify(usedToken, usedEth);
            } catch {
                _approve(address(this), address(uniswapRouter), 0);
                emit AutoSwapFailed(otherHalf, ethGained);
            }
        } catch {
            _approve(address(this), address(uniswapRouter), 0);
            emit AutoSwapFailed(half, amountOutMin);
        }
    }

    function _quoteAmountOutMin(uint256 tokenAmount) private view returns (uint256) {
        if (uniswapPair == address(0)) return 0;
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(uniswapPair).getReserves();
        if (r0 == 0 || r1 == 0) return 0;
        address t0 = IUniswapV2Pair(uniswapPair).token0();
        (uint256 rIn, uint256 rOut) = t0 == address(this) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 amountInWithFee = tokenAmount * 997;
        uint256 quoted = (amountInWithFee * rOut) / (rIn * 1000 + amountInWithFee);
        return (quoted * (BPS - autoSwapSlippageBps)) / BPS;
    }




    function claimFailedEth() external {
        uint256 owed = failedEth[msg.sender];
        require(owed > 0, "0");
        failedEth[msg.sender] = 0;
        totalFailedEth -= owed;
        (bool ok,) = payable(msg.sender).call{value: owed}("");
        require(ok, "x");
        emit FailedEthClaimed(msg.sender, owed);
    }

    function setEthFallbackRecipient(address fb) external onlyRole(GOVERNOR_ROLE) {
        require(fb != address(0), "0");
        ethFallbackRecipient = fb;
        emit EthFallbackRecipientUpdated(fb);
    }

    function rescueETH(address to, uint256 amount) external onlyRole(GOVERNOR_ROLE) {
        require(to != address(0), "0");
        uint256 balance = address(this).balance;
        require(balance >= totalFailedEth && amount <= balance - totalFailedEth, "reserved");
        (bool ok,) = payable(to).call{value: amount}("");
        require(ok, "eth");
        emit RescueETH(to, amount);
    }

    function _takeFeesAndDeflation(address from, address to, uint256 amount) internal returns (uint256 receiveAmount) {
        if (from == address(this) || to == address(this)) return amount;
        uint16 feeBps = _computeFeeBps(from, to);
        uint256 feeAmt = (amount * feeBps) / BPS;
        require(feeAmt < amount, "8");
        if (feeAmt > 0) {
            uint256 toBurn = (feeAmt * fees.burnShareBps) / BPS;
            uint256 toLiq = feeAmt - toBurn;
            if (toBurn > 0) _burn(from, toBurn);
            if (toLiq > 0) super._transfer(from, address(this), toLiq);
        }
        receiveAmount = amount - feeAmt;
    }

    function _update(address from, address to, uint256 amount)
        internal
        virtual
        override(ERC20Upgradeable, ERC20PausableUpgradeable)
    {
        if (to == address(0)) totalBurned += amount;
        if (from != address(0) && to != address(0)) {
            require(!blacklisted[from] && !blacklisted[to], "g");
            uint256 receiveAmount = amount;
            if (!feeExempt[from] && !feeExempt[to]) {
                receiveAmount = _takeFeesAndDeflation(from, to, amount);
            }
            if (
                v2Initialized && autoSwapEnabled && !_inSwap && _isSell(from, to)
                    && balanceOf(address(this)) >= autoSwapThreshold
            ) {
                _swapAndLiquify(balanceOf(address(this)));
            }
            amount = receiveAmount;
        }
        super._update(from, to, amount);
    }


    function setRecipients(address _dev, address _staking, address _dao, address _liq)
        external
        onlyRole(GOVERNOR_ROLE)
    {
        require(_dev != address(0) && _staking != address(0) && _dao != address(0) && _liq != address(0), "0");
        devWallet = _dev;
        stakingVault = _staking;
        daoWallet = _dao;
        liquidityCollector = _liq;
        treasury = _dao;
        _setExempt(_dev, true, true);
        _setExempt(_staking, true, true);
        _setExempt(_dao, true, true);
        _setExempt(_liq, true, true);
        emit RecipientsUpdated(_dev, _staking, _dao, _liq);
    }

    function setAuxRecipients(address _cex, address _contributors, address _nfts, address _mkt)
        external
        onlyRole(GOVERNOR_ROLE)
    {
        require(_cex != address(0) && _contributors != address(0) && _nfts != address(0) && _mkt != address(0), "0");
        cexListingsWallet = _cex;
        contributorsWallet = _contributors;
        nftsWallet = _nfts;
        marketingWallet = _mkt;
        _setExempt(_cex, true, true);
        _setExempt(_contributors, true, true);
        _setExempt(_nfts, true, true);
        _setExempt(_mkt, true, true);
        emit AuxRecipientsUpdated(_cex, _contributors, _nfts, _mkt);
    }

    function setFees(
        uint16 buyBps,
        uint16 sellBps,
        uint16 transferBps,
        uint16 burnShareBps,
        uint16 liqShareBps,
        uint16 treShareBps,
        uint16 devShareBps
    ) external onlyRole(GOVERNOR_ROLE) {
        _validateFeeBounds(buyBps, sellBps, transferBps);
        _validateShareSum(burnShareBps, liqShareBps, treShareBps, devShareBps);
        FeeConfig storage f = fees;
        f.buyBps = buyBps;
        f.sellBps = sellBps;
        f.transferBps = transferBps;
        f.burnShareBps = burnShareBps;
        f.liquidityShareBps = liqShareBps;
        f.treasuryShareBps = treShareBps;
        f.devShareBps = devShareBps;
        emit FeesUpdated(f);
    }

    function _validateFeeBounds(uint16 buyBps, uint16 sellBps, uint16 transferBps) private pure {
        require(buyBps <= MAX_FEE_BPS && sellBps <= MAX_FEE_BPS && transferBps <= MAX_FEE_BPS, "a");
    }

    function _validateShareSum(uint16 burnShareBps, uint16 liqShareBps, uint16 treShareBps, uint16 devShareBps)
        private
        pure
    {
        require(uint256(burnShareBps) + liqShareBps + treShareBps + devShareBps == BPS, "b");
    }




    function setExemptions(address account, bool _feeExempt, bool _limitsExempt) external onlyRole(GOVERNOR_ROLE) {
        if (account == address(this)) require(_feeExempt, "self-fee");
        _setExempt(account, _feeExempt, _limitsExempt);
        emit ExemptionsUpdated(account, _feeExempt, _limitsExempt);
    }

    function setPair(address pair, bool status) external onlyRole(GOVERNOR_ROLE) {
        require(pair != address(0), "0");
        require(status || pair != uniswapPair, "main-pair");
        if (status) {
            if (!_isLpPair[pair]) {
                _isLpPair[pair] = true;
                _lpPairsList.push(pair);
            }
            if (!limitsExempt[pair]) {
                limitsExempt[pair] = true;
                emit ExemptionsUpdated(pair, feeExempt[pair], true);
            }
        } else if (_isLpPair[pair]) {
            _isLpPair[pair] = false;
            uint256 n = _lpPairsList.length;
            for (uint256 i; i < n; ++i) {
                if (_lpPairsList[i] == pair) {
                    _lpPairsList[i] = _lpPairsList[n - 1];
                    _lpPairsList.pop();
                    break;
                }
            }
        }
        emit PairStatusUpdated(pair, status);
    }


    function setBlacklist(address account, bool _blacklisted) external onlyRole(GOVERNOR_ROLE) {
        require(!blacklistRenounced, "renounced");
        blacklisted[account] = _blacklisted;
        emit BlacklistUpdated(account, _blacklisted);
    }

    function renounceBlacklist() external onlyRole(GOVERNOR_ROLE) {
        blacklistRenounced = true;
        emit BlacklistRenounced();
    }




    function isPair(address a) public view returns (bool) {
        return _isLpPair[a];
    }

    function lpPairs() external view returns (address[] memory) {
        return _lpPairsList;
    }

    function isBlacklisted(address account) external view returns (bool) {
        return blacklisted[account];
    }

    function _setExempt(address account, bool fee, bool limits) internal {
        feeExempt[account] = fee;
        limitsExempt[account] = limits;
    }

    function _isBuy(address from, address) internal view returns (bool) {
        return isPair(from);
    }

    function _isSell(address, address to) internal view returns (bool) {
        return isPair(to);
    }


    function _computeFeeBps(address from, address to) internal view returns (uint16) {
        if (_isBuy(from, to)) return fees.buyBps;
        if (_isSell(from, to)) return fees.sellBps;
        return fees.transferBps;
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    function supportsInterface(bytes4 interfaceId) public view override(AccessControlUpgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function noxVersion() external pure returns (string memory) {
        return "NONOS_NOX_MAINNET_V3";
    }

    receive() external payable {}
}
