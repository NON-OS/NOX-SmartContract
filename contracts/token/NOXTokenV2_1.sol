// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*
 *  NONOS_NOX_MAINNET_V2_1
 *  -----------------------------------------------------------------------
 *  Storage-safe UUPS upgrade of NONOS_NOX_MAINNET_V2.
 *
 *  Live token (proxy) address is unchanged:
 *      0x0a26c80Be4E060e688d7C23aDdB92cBb5D2C9eCA
 *  Balances, allowances, the Uniswap V2 LP pair, and every existing
 *  holder relationship are preserved. No re-deployment, no migration.
 *  The upgrade is performed exclusively through the proxy's UUPS path:
 *      upgradeToAndCall(newImpl, abi.encodeCall(reinitV21, (maxChunk, ethFb)))
 *
 *  Hardening relative to V2
 *
 *  Auto-swap
 *      The router call now uses a reserve-quoted amountOutMin discounted
 *      by autoSwapSlippageBps. The "amountOutMin = 0" sandwich path is
 *      gone. A maxAutoSwapChunk ceiling bounds both the auto-trigger
 *      inside _update and the manual GOVERNOR-only triggerAutoSwap, so
 *      a single transaction can never dump the contract's full balance.
 *      Router allowance is reset to zero on swap failure to prevent a
 *      stale approval from being reused.
 *
 *  ETH distribution and recovery
 *      Forwarding to liquidityCollector, treasury, and devWallet now
 *      checks the call return value. Any slice that fails to deliver is
 *      parked under failedEth[recipient] and counted in totalFailedEth.
 *      The recipient can pull at any time with claimFailedEth(); they
 *      cannot lose funds because of a temporary receive-revert. The
 *      governance rescueETH(to, amount) function explicitly excludes the
 *      reserved totalFailedEth balance, so it cannot drain ETH backing
 *      pending claims.
 *
 *  LP pair safety
 *      setPair(true) auto-grants limitsExempt to the new pair without
 *      changing feeExempt: multi-buy blocks never collide with the
 *      same-block guard, and the pair keeps paying buy/sell tax.
 *      setPair(false) is forbidden against the canonical uniswapPair to
 *      prevent operator footguns, and removes any other pair from the
 *      iteration list so toggle cycles cannot grow duplicates. The
 *      same-block guard and tx-limit checks short-circuit whenever
 *      `from` is a recognised LP pair, regardless of exemption state.
 *
 *  Fee policy
 *      setFees and setDeflationParams validate the buy/sell/transfer +
 *      deflation sum at admin-set time, not only at transfer time, so
 *      a misconfigured policy cannot brick subsequent transfers.
 *
 *  Self-fee guard
 *      setExemptions cannot remove the contract itself from feeExempt;
 *      _takeFeesAndDeflation short-circuits when either side equals
 *      address(this). The internal swap path is therefore never able
 *      to recurse into double-fee accounting.
 *
 *  Reinitialisation
 *      reinitV21 is reinitializer(2) AND onlyRole(UPGRADER_ROLE). It
 *      cannot be replayed and cannot be invoked by anyone other than
 *      the upgrade authority even if upgradeToAndCall is ever executed
 *      with empty calldata. It does not modify fees: the 2.5% / 2.5%
 *      tax policy is applied post-upgrade through the existing
 *      setFees(GOVERNOR_ROLE) selector, keeping fee policy decoupled
 *      from the implementation switch.
 *
 *  Storage layout (preserved from V2)
 *      V2 declared a uint256[32] tail gap. V2.1 consumes the first
 *      four slots of that gap and shrinks the gap to uint256[28]:
 *
 *          slot 26  maxAutoSwapChunk        uint256
 *          slot 27  ethFallbackRecipient    address
 *          slot 28  failedEth               mapping(address => uint256)
 *          slot 29  totalFailedEth          uint256
 *          slot 30  __noxGapV2              uint256[28]
 *
 *      Every storage variable that existed in V2 occupies the same
 *      slot and offset in V2.1. No reorder, no rename, no type change.
 *
 *  External ABI delta
 *      Preserved: every V2 admin function, every V2 view, ERC20,
 *      ERC20Permit, ERC20Burnable, ERC20Pausable, AccessControl, UUPS.
 *      Added (V2.1-new): reinitV21, setMaxAutoSwapChunk,
 *      setEthFallbackRecipient, claimFailedEth, rescueETH, plus the
 *      public getters maxAutoSwapChunk, ethFallbackRecipient,
 *      failedEth, totalFailedEth.
 *      Removed (intentional, per upgrade brief): the ERC20Votes
 *      surface — delegate, delegateBySig, delegates, getVotes,
 *      getPastVotes, getPastTotalSupply, numCheckpoints, checkpoints,
 *      clock, CLOCK_MODE. On-chain audit confirms zero historical
 *      delegations and zero past-supply queries on the live proxy
 *      before the upgrade, so this surface had no users.
 *
 *  Compiler / verification
 *      solc 0.8.24, evmVersion = paris.
 *      Deploy artifact: optimizer = true, runs = 1, via_ir = true,
 *      bytecode_hash = "none". Etherscan verification must match
 *      these settings exactly. The validation profile (V2 + V2.1
 *      replay tests, storage layout proofs) uses runs = 1 without
 *      via_ir; that profile is for tests only and is not the artifact
 *      that ships to chain.
 */

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
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
}

contract NONOS_NOX_MAINNET_V2_1 is
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
    uint16 public constant MAX_FEE_BPS = 1_000;
    uint16 public constant MAX_DEF_BPS = 200;
    uint16 public constant MAX_SUM_BPS = 2_000;

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
        _swapTokensForEth(balanceOf(address(this)));
    }

    function _swapTokensForEth(uint256 tokenAmount) private lockTheSwap {
        if (tokenAmount == 0) return;
        uint256 cap = maxAutoSwapChunk;
        if (cap > 0 && tokenAmount > cap) tokenAmount = cap;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapRouter.WETH();

        uint256 amountOutMin = _quoteAmountOutMin(tokenAmount);

        _approve(address(this), address(uniswapRouter), tokenAmount);
        uint256 ethBefore = address(this).balance;

        try uniswapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount, amountOutMin, path, address(this), block.timestamp
        ) {
            uint256 ethReceived = address(this).balance - ethBefore;
            if (ethReceived > 0) _distributeEth(ethReceived);
            emit AutoSwapExecuted(tokenAmount, ethReceived);
        } catch {
            _approve(address(this), address(uniswapRouter), 0);
            emit AutoSwapFailed(tokenAmount, amountOutMin);
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

    function _distributeEth(uint256 ethReceived) private {
        uint256 totalShares = uint256(fees.liquidityShareBps) + fees.treasuryShareBps + fees.devShareBps;
        if (totalShares == 0) {
            _payOrAccrue(ethFallbackRecipient, ethReceived);
            return;
        }
        uint256 toLiq = (ethReceived * fees.liquidityShareBps) / totalShares;
        uint256 toTre = (ethReceived * fees.treasuryShareBps) / totalShares;
        uint256 toDev = ethReceived - toLiq - toTre;

        _payOrAccrue(liquidityCollector, toLiq);
        _payOrAccrue(treasury, toTre);
        _payOrAccrue(devWallet, toDev);
    }

    function _payOrAccrue(address recipient, uint256 amount) private {
        if (amount == 0) return;
        if (recipient == address(0)) {
            address fb = ethFallbackRecipient;
            address credited = fb == address(0) ? address(this) : fb;
            _accrueFailedEth(credited, amount);
            emit AutoSwapForwardFailed(credited, amount);
            return;
        }
        (bool ok,) = payable(recipient).call{value: amount}("");
        if (!ok) {
            _accrueFailedEth(recipient, amount);
            emit AutoSwapForwardFailed(recipient, amount);
        }
    }

    function _accrueFailedEth(address recipient, uint256 amount) private {
        failedEth[recipient] += amount;
        totalFailedEth += amount;
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
        require(uint256(feeBps) + deflationBps <= MAX_SUM_BPS, "7");
        uint256 feeAmt = (amount * feeBps) / BPS;
        uint256 defAmt = (amount * deflationBps) / BPS;
        uint256 totalDeduct = feeAmt + defAmt;
        require(totalDeduct < amount, "8");
        if (feeAmt > 0) {
            uint256 toBurn = (feeAmt * fees.burnShareBps) / BPS;
            uint256 toSwap = feeAmt - toBurn;
            if (toBurn > 0) _burn(from, toBurn);
            if (toSwap > 0) super._transfer(from, address(this), toSwap);
        }
        if (defAmt > 0) _burn(from, defAmt);
        receiveAmount = amount - totalDeduct;
    }

    function _update(address from, address to, uint256 amount)
        internal
        override(ERC20Upgradeable, ERC20PausableUpgradeable)
    {
        if (to == address(0)) totalBurned += amount;
        if (from != address(0) && to != address(0)) {
            _enforceGuards(from, to, amount);
            if (_isSell(from, to) && address(priceImpactController) != address(0)) {
                priceImpactController.onBeforeSell(from, amount);
            }
            uint256 receiveAmount = amount;
            if (!feeExempt[from] && !feeExempt[to]) {
                receiveAmount = _takeFeesAndDeflation(from, to, amount);
            }
            if (
                v2Initialized && autoSwapEnabled && !_inSwap && _isSell(from, to)
                    && balanceOf(address(this)) >= autoSwapThreshold
            ) {
                _swapTokensForEth(balanceOf(address(this)));
            }
            if (walletLimitEnabled && !_isSell(from, to) && !limitsExempt[to]) {
                require(balanceOf(to) + receiveAmount <= (totalSupply() * maxWalletBps) / BPS, "9");
            }
            if (!_inSwap) lastTxBlock[from] = block.number;
            _updateEma(amount);
            if (_isSell(from, to)) {
                lastSellTime[from] = uint64(block.timestamp);
                emit SellCooldownEnforced(from, uint64(block.timestamp));
            }
            amount = receiveAmount;
        }
        super._update(from, to, amount);
    }

    function _enforceGuards(address from, address to, uint256 amount) internal view {
        require(!emergencyStop, "f");
        require(!blacklisted[from] && !blacklisted[to], "g");
        bool fromIsPair = _isLpPair[from];
        if (sameBlockGuardEnabled && !limitsExempt[from] && !fromIsPair) {
            require(lastTxBlock[from] != block.number, "h");
        }
        if (txLimitEnabled && !limitsExempt[from] && !fromIsPair && (_isBuy(from, to) || _isSell(from, to))) {
            require(amount <= (totalSupply() * maxTxBps) / BPS, "i");
        }
        if (_isSell(from, to) && sellCooldown > 0 && !limitsExempt[from]) {
            require(block.timestamp >= lastSellTime[from] + sellCooldown, "j");
        }
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
        _validateFeesVsDeflation(buyBps, sellBps, transferBps);
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

    function _validateFeesVsDeflation(uint16 buyBps, uint16 sellBps, uint16 transferBps) private view {
        uint256 d = deflationBps;
        require(
            uint256(buyBps) + d <= MAX_SUM_BPS && uint256(sellBps) + d <= MAX_SUM_BPS
                && uint256(transferBps) + d <= MAX_SUM_BPS,
            "sum"
        );
    }

    function setDeflationParams(uint16 _deflationBps, uint16 _alphaBps, uint16 _emaDecayBps)
        external
        onlyRole(GOVERNOR_ROLE)
    {
        require(_deflationBps <= MAX_DEF_BPS, "c");
        require(_emaDecayBps <= BPS && _alphaBps <= 500, "d");
        require(
            uint256(fees.buyBps) + _deflationBps <= MAX_SUM_BPS && uint256(fees.sellBps) + _deflationBps <= MAX_SUM_BPS
                && uint256(fees.transferBps) + _deflationBps <= MAX_SUM_BPS,
            "sum"
        );
        deflationBps = _deflationBps;
        alphaBps = _alphaBps;
        emaDecayBps = _emaDecayBps;
        emit DeflationUpdated(deflationBps, alphaBps, emaDecayBps);
    }

    function setGuards(
        bool sameBlock,
        bool txLimit,
        bool walletLimit,
        uint16 _maxTxBps,
        uint16 _maxWalletBps,
        uint64 _sellCooldown
    ) external onlyRole(GOVERNOR_ROLE) {
        require(_maxTxBps <= BPS && _maxWalletBps <= BPS, "e");
        sameBlockGuardEnabled = sameBlock;
        txLimitEnabled = txLimit;
        walletLimitEnabled = walletLimit;
        maxTxBps = _maxTxBps;
        maxWalletBps = _maxWalletBps;
        sellCooldown = _sellCooldown;
        emit GuardsUpdated(sameBlock, txLimit, walletLimit, _maxTxBps, _maxWalletBps, _sellCooldown);
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

    function setPriceImpactController(address controller) external onlyRole(GOVERNOR_ROLE) {
        priceImpactController = IPriceImpactController(controller);
        emit PriceImpactControllerSet(controller);
    }

    function setBlacklist(address account, bool _blacklisted) external onlyRole(GOVERNOR_ROLE) {
        blacklisted[account] = _blacklisted;
        emit BlacklistUpdated(account, _blacklisted);
    }

    function setEmergencyStop(bool stopped) external onlyRole(EMERGENCY_ROLE) {
        emergencyStop = stopped;
        emit EmergencyStopChanged(stopped);
    }

    function pause() external onlyRole(GOVERNOR_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GOVERNOR_ROLE) {
        _unpause();
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

    function _updateEma(uint256 amount) internal {
        uint256 sup = totalSupply();
        if (sup == 0) return;
        uint256 vNow = (amount * BPS) / sup;
        vEmaBps = (vEmaBps * emaDecayBps + vNow * (BPS - emaDecayBps)) / BPS;
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

    receive() external payable {}
}
