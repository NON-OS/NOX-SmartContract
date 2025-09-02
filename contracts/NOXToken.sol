// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
 *  ███╗   ██╗ ██████╗ ███╗   ██╗ ██████╗ ███████╗
 *  ████╗  ██║██╔═══██╗████╗  ██║██╔═══██╗██╔════╝
 *  ██╔██╗ ██║██║   ██║██╔██╗ ██║██║   ██║███████╗  NONOS // NOX
 *  ██║╚██╗██║██║   ██║██║╚██╗██║██║   ██║╚════██║ 
 *  ██║ ╚████║╚██████╔╝██║ ╚████║╚██████╔╝███████║  static 2/2 tax, 0.5% max trade, 4% max wallet
 *  ╚═╝  ╚═══╝ ╚═════╝ ╚═╝  ╚═══╝ ╚═════╝ ╚══════╝  deployer-only admin/upgrader, manual LP + setPair()
 *
 *  OVERVIEW
 *  ─────────────────────────────────────────────────────────────────────────────
 *  - ERC20 (OZ upgradeable) + Burnable + Permit + Votes + Pausable + AccessControl.
 *  - Static taxes: 2% buy / 2% sell / 0% transfer. No holding-time adders.
 *  - Fee split (of the fee): 10% burn, 40% liquidityCollector, 20% DAO (treasury), 30% dev.
 *  - Limits: max buy/sell = 0.5% of current supply; max wallet = 4%. (Exempts our wallets & role holders.)
 *  - Manual LP: Our team creates LP on DEX, then we call setPair(pair, true). No auto-LP or swaps here.
 *  - Guards: same-block guard (anti-sandwich), sell cooldown, blacklist, emergency stop toggle.
 *  - Price impact hook: optional external controller for pre-sell checks.
 *  - Upgradeability: UUPS; _authorizeUpgrade requires UPGRADER_ROLE (held by deployer). No timelock.
 *
 */

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { ERC20BurnableUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import { ERC20PermitUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { ERC20VotesUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import { ERC20PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";

import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { NoncesUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev External controller can veto sells that exceed some off-chain/on-chain price-impact rule.
interface IPriceImpactController {
    function onBeforeSell(address from, uint256 amount) external view;
}

contract NONOS_NOX_MAINNET is
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ERC20PermitUpgradeable,
    ERC20VotesUpgradeable,
    ERC20PausableUpgradeable,
    AccessControlEnumerableUpgradeable
{
    using EnumerableSet for EnumerableSet.AddressSet;

    // ───────────────────────── constants / roles
    bytes32 public constant GOVERNOR_ROLE  = keccak256("GOVERNOR_ROLE");   // param changes / ops
    bytes32 public constant UPGRADER_ROLE  = keccak256("UPGRADER_ROLE");   // UUPS upgrades
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");  // emergency stop

    uint256 public constant MAX_SUPPLY  = 800_000_000e18;
    uint16  public constant BPS         = 10_000; // 100.00%
    uint16  public constant MAX_FEE_BPS = 1_000;  // safety: max 10% per side
    uint16  public constant MAX_DEF_BPS = 200;    // safety: max 2% deflation
    uint16  public constant MAX_SUM_BPS = 2_000;  // safety: fee + deflation <= 20%

    // ───────────────────────── fee / deflation config
    struct FeeConfig {
        uint16 buyBps;            // 200 (2%)
        uint16 sellBps;           // 200 (2%)
        uint16 transferBps;       // 0% for P2P
        uint16 burnShareBps;      // 10% of fee
        uint16 liquidityShareBps; // 40% of fee
        uint16 treasuryShareBps;  // 20% of fee (DAO)
        uint16 devShareBps;       // 30% of fee (dev)
    }
    FeeConfig public fees;

    // Deflation (optional, off by default). Kept for future flexibility.
    uint16 public deflationBps; // burns extra % of transfer, capped by MAX_DEF_BPS
    uint16 public alphaBps;     // EMA tuning (for future auto-deflation schemes)
    uint16 public emaDecayBps;  // EMA tuning
    uint256 public vEmaBps;     // EMA of (amount / totalSupply) * BPS
    uint256 public totalBurned; // tracks total burned via fee/deflation

    // ───────────────────────── project wallets (initial allocations & fee sinks)
    address public devWallet;            // gets 30% of fees
    address public stakingVault;         // optional staking vault (init allocation only)
    address public daoWallet;            // gets 20% of fees (treasury)
    address public liquidityCollector;   // gets 40% of fees (ops collects; not auto-LPing here)

    // additional initial allocation wallets
    address public cexListingsWallet;    // CEX listings
    address public contributorsWallet;   // contributors/node ops
    address public nftsWallet;           // NFTs
    address public marketingWallet;      // marketing

    // "treasury" alias for back-compat in distribution code (routes to daoWallet)
    address public treasury;

    // ───────────────────────── guards / pairs / policy
    EnumerableSet.AddressSet private _lpPairs; // recognized AMM pairs
    mapping(address => bool) public feeExempt;     // exempt from fees
    mapping(address => bool) public limitsExempt;  // exempt from limits
    mapping(address => bool) public blacklisted;   // can hard-block malicious addresses

    mapping(address => uint256) public lastTxBlock; // same-block guard
    mapping(address => uint64)  public lastSellTime; // sell cooldown

    bool   public sameBlockGuardEnabled; // anti-sandwich (default: true)
    bool   public txLimitEnabled;        // tx limit toggle
    bool   public walletLimitEnabled;    // wallet limit toggle

    uint16 public maxTxBps;       // **0.5%** per BUY/SELL (by current supply)
    uint16 public maxWalletBps;   // **4%** per wallet (by current supply)
    uint64 public sellCooldown;   // seconds between sells

    bool   public emergencyStop;  // global halt toggle

    IPriceImpactController public priceImpactController; // optional sell veto

    // ───────────────────────── events
    event FeesUpdated(FeeConfig fees);
    event DeflationUpdated(uint16 deflationBps, uint16 alphaBps, uint16 emaDecayBps);
    event RecipientsUpdated(address devWallet, address stakingVault, address daoWallet, address liquidityCollector);
    event AuxRecipientsUpdated(address cexListingsWallet, address contributorsWallet, address nftsWallet, address marketingWallet);
    event PairStatusUpdated(address indexed pair, bool isPair);
    event ExemptionsUpdated(address indexed account, bool feeExempt, bool limitsExempt);
    event GuardsUpdated(bool sameBlock, bool txLimit, bool walletLimit, uint16 maxTxBps, uint16 maxWalletBps, uint64 sellCooldown);
    event PriceImpactControllerSet(address controller);
    event BlacklistUpdated(address indexed account, bool isBlacklisted);
    event EmergencyStopChanged(bool stopped);
    event SellCooldownEnforced(address indexed seller, uint64 timestamp);
    event RoleExemptionsSynced(bytes32 indexed role, uint256 membersProcessed);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    // ───────────────────────── initializer (UUPS proxy)
    /// @notice Initialize token, mint supply per split, set defaults. Deployer becomes admin/governor/upgrader.
    function initialize(
        address mainReceiver,        // receives remainder of supply
        address _devWallet,          // 3%
        address _stakingVault,       // 4%
        address _daoWallet,          // 3%
        address _liquidityCollector, // 4%
        address _cexListingsWallet,  // 4%
        address _contributorsWallet, // 3%
        address _nftsWallet,         // 1.5%
        address _marketingWallet     // 2.5%
    ) public initializer {
        _validateAddresses(mainReceiver, _devWallet, _stakingVault, _daoWallet, _liquidityCollector, _cexListingsWallet, _contributorsWallet, _nftsWallet, _marketingWallet);
        _initializeContracts();
        _setupRoles();
        _mintInitialSupply(mainReceiver, _devWallet, _stakingVault, _daoWallet, _liquidityCollector, _cexListingsWallet, _contributorsWallet, _nftsWallet, _marketingWallet);
        _storeRecipients(_devWallet, _stakingVault, _daoWallet, _liquidityCollector, _cexListingsWallet, _contributorsWallet, _nftsWallet, _marketingWallet);
        _configureFees();
        _configureGuards();
        _setupExemptions(mainReceiver, _devWallet, _stakingVault, _daoWallet, _liquidityCollector, _cexListingsWallet, _contributorsWallet, _nftsWallet, _marketingWallet);
    }

    function _validateAddresses(
        address mainReceiver, address _devWallet, address _stakingVault, address _daoWallet, 
        address _liquidityCollector, address _cexListingsWallet, address _contributorsWallet, 
        address _nftsWallet, address _marketingWallet
    ) private pure {
        require(
            mainReceiver!=address(0) && _devWallet!=address(0) && _stakingVault!=address(0) && 
            _daoWallet!=address(0) && _liquidityCollector!=address(0) && _cexListingsWallet!=address(0) &&
            _contributorsWallet!=address(0) && _nftsWallet!=address(0) && _marketingWallet!=address(0),
            "NOX: zero addr"
        );
    }

    function _initializeContracts() private {
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __ERC20_init("NONOS", "NOX");
        __ERC20Burnable_init();
        __ERC20Permit_init("NONOS");
        __ERC20Votes_init();
        __ERC20Pausable_init();
        __AccessControlEnumerable_init();
    }

    function _setupRoles() private {
        address deployer = _msgSender();
        _grantRole(DEFAULT_ADMIN_ROLE, deployer);
        _grantRole(GOVERNOR_ROLE, deployer);
        _grantRole(UPGRADER_ROLE, deployer);
        _grantRole(EMERGENCY_ROLE, deployer);
    }

    function _mintInitialSupply(
        address mainReceiver, address _devWallet, address _stakingVault, address _daoWallet,
        address _liquidityCollector, address _cexListingsWallet, address _contributorsWallet,
        address _nftsWallet, address _marketingWallet
    ) private {
        _mint(_devWallet, (MAX_SUPPLY * 300) / BPS);          // 3%
        _mint(_stakingVault, (MAX_SUPPLY * 400) / BPS);       // 4%
        _mint(_daoWallet, (MAX_SUPPLY * 300) / BPS);          // 3%
        _mint(_liquidityCollector, (MAX_SUPPLY * 400) / BPS); // 4%
        _mint(_cexListingsWallet, (MAX_SUPPLY * 400) / BPS);  // 4%
        _mint(_contributorsWallet, (MAX_SUPPLY * 300) / BPS); // 3%
        _mint(_nftsWallet, (MAX_SUPPLY * 150) / BPS);         // 1.5%
        _mint(_marketingWallet, (MAX_SUPPLY * 250) / BPS);    // 2.5%
        
        // Main receiver gets remainder (75%)
        uint256 allocated = (MAX_SUPPLY * 2500) / BPS; // 25% allocated above
        _mint(mainReceiver, MAX_SUPPLY - allocated);
    }

    function _storeRecipients(
        address _devWallet, address _stakingVault, address _daoWallet, address _liquidityCollector,
        address _cexListingsWallet, address _contributorsWallet, address _nftsWallet, address _marketingWallet
    ) private {
        devWallet = _devWallet;
        stakingVault = _stakingVault;
        daoWallet = _daoWallet;
        liquidityCollector = _liquidityCollector;
        cexListingsWallet = _cexListingsWallet;
        contributorsWallet = _contributorsWallet;
        nftsWallet = _nftsWallet;
        marketingWallet = _marketingWallet;
        treasury = _daoWallet;
        
        emit RecipientsUpdated(devWallet, stakingVault, daoWallet, liquidityCollector);
        emit AuxRecipientsUpdated(cexListingsWallet, contributorsWallet, nftsWallet, marketingWallet);
    }

    function _configureFees() private {
        fees.buyBps = 200;
        fees.sellBps = 200;
        fees.transferBps = 0;
        fees.burnShareBps = 1000;
        fees.liquidityShareBps = 4000;
        fees.treasuryShareBps = 2000;
        fees.devShareBps = 3000;
        
        deflationBps = 0;
        alphaBps = 40;
        emaDecayBps = 9800;
        vEmaBps = 0;
    }

    function _configureGuards() private {
        sameBlockGuardEnabled = true;
        txLimitEnabled = true;
        walletLimitEnabled = true;
        maxTxBps = 50;    // 0.5%
        maxWalletBps = 400; // 4%
        sellCooldown = 20;
        emergencyStop = false;
    }

    function _setupExemptions(
        address mainReceiver, address _devWallet, address _stakingVault, address _daoWallet,
        address _liquidityCollector, address _cexListingsWallet, address _contributorsWallet,
        address _nftsWallet, address _marketingWallet
    ) private {
        address deployer = _msgSender();
        _setExempt(deployer, true, true);
        _setExempt(address(this), true, true);
        _setExempt(mainReceiver, true, true);
        _setExempt(_devWallet, true, true);
        _setExempt(_stakingVault, true, true);
        _setExempt(_daoWallet, true, true);
        _setExempt(_liquidityCollector, true, true);
        _setExempt(_cexListingsWallet, true, true);
        _setExempt(_contributorsWallet, true, true);
        _setExempt(_nftsWallet, true, true);
        _setExempt(_marketingWallet, true, true);
    }

    // ───────────────────────── admin (governor) — recipients / fees / guards / pairs
    function setRecipients(address _dev, address _staking, address _dao, address _liq)
        external onlyRole(GOVERNOR_ROLE)
    {
        require(_dev!=address(0)&&_staking!=address(0)&&_dao!=address(0)&&_liq!=address(0),"NOX: zero addr");
        devWallet=_dev; stakingVault=_staking; daoWallet=_dao; liquidityCollector=_liq;
        treasury = _dao; // keep alias in sync
        // keep them exempt by default (won't de-exempt old addresses automatically)
        _setExempt(_dev, true, true);
        _setExempt(_staking, true, true);
        _setExempt(_dao, true, true);
        _setExempt(_liq, true, true);
        emit RecipientsUpdated(_dev, _staking, _dao, _liq);
    }

    function setAuxRecipients(address _cex, address _contributors, address _nfts, address _mkt)
        external onlyRole(GOVERNOR_ROLE)
    {
        require(_cex!=address(0)&&_contributors!=address(0)&&_nfts!=address(0)&&_mkt!=address(0),"NOX: zero addr");
        cexListingsWallet=_cex; contributorsWallet=_contributors; nftsWallet=_nfts; marketingWallet=_mkt;
        _setExempt(_cex, true, true);
        _setExempt(_contributors, true, true);
        _setExempt(_nfts, true, true);
        _setExempt(_mkt, true, true);
        emit AuxRecipientsUpdated(_cex, _contributors, _nfts, _mkt);
    }

    function setFees(
        uint16 buyBps, uint16 sellBps, uint16 transferBps,
        uint16 burnShareBps, uint16 liqShareBps, uint16 treShareBps, uint16 devShareBps
    ) external onlyRole(GOVERNOR_ROLE) {
        require(buyBps<=MAX_FEE_BPS && sellBps<=MAX_FEE_BPS && transferBps<=MAX_FEE_BPS, "NOX: fee high");
        require(uint256(burnShareBps)+liqShareBps+treShareBps+devShareBps==BPS, "NOX: split!=100%");
        fees = FeeConfig(buyBps, sellBps, transferBps, burnShareBps, liqShareBps, treShareBps, devShareBps);
        emit FeesUpdated(fees);
    }

    function setDeflationParams(uint16 _deflationBps, uint16 _alphaBps, uint16 _emaDecayBps)
        external onlyRole(GOVERNOR_ROLE)
    {
        require(_deflationBps<=MAX_DEF_BPS, "NOX: defl high");
        require(_emaDecayBps<=BPS && _alphaBps<=500, "NOX: params"); // α<=0.05 sanity
        deflationBps=_deflationBps; alphaBps=_alphaBps; emaDecayBps=_emaDecayBps;
        emit DeflationUpdated(deflationBps, alphaBps, emaDecayBps);
    }

    function setGuards(
        bool sameBlock, bool txLimit, bool walletLimit,
        uint16 _maxTxBps, uint16 _maxWalletBps, uint64 _sellCooldown
    ) external onlyRole(GOVERNOR_ROLE) {
        require(_maxTxBps<=BPS && _maxWalletBps<=BPS, "NOX: bps bad");
        sameBlockGuardEnabled=sameBlock; txLimitEnabled=txLimit; walletLimitEnabled=walletLimit;
        maxTxBps=_maxTxBps; maxWalletBps=_maxWalletBps; sellCooldown=_sellCooldown;
        emit GuardsUpdated(sameBlock, txLimit, walletLimit, _maxTxBps, _maxWalletBps, _sellCooldown);
    }

    function setExemptions(address account, bool _feeExempt, bool _limitsExempt)
        external onlyRole(GOVERNOR_ROLE)
    {
        _setExempt(account, _feeExempt, _limitsExempt);
        emit ExemptionsUpdated(account,_feeExempt,_limitsExempt);
    }

    /// @notice Mark/unmark an AMM pair. After LP on a DEX is created.
    function setPair(address pair, bool _isPair) external onlyRole(GOVERNOR_ROLE) {
        require(pair!=address(0),"NOX: zero");
        if(_isPair) _lpPairs.add(pair); else _lpPairs.remove(pair);
        emit PairStatusUpdated(pair,_isPair);
    }

    function setPriceImpactController(address controller) external onlyRole(GOVERNOR_ROLE){
        priceImpactController = IPriceImpactController(controller);
        emit PriceImpactControllerSet(controller);
    }

    // ───────────────────────── blacklist / emergency / pause
    function setBlacklist(address account, bool _blacklisted) external onlyRole(GOVERNOR_ROLE) {
        blacklisted[account] = _blacklisted;
        emit BlacklistUpdated(account, _blacklisted);
    }

    function batchSetBlacklist(address[] calldata accounts, bool _blacklisted) external onlyRole(GOVERNOR_ROLE) {
        for (uint256 i = 0; i < accounts.length; i++) {
            blacklisted[accounts[i]] = _blacklisted;
            emit BlacklistUpdated(accounts[i], _blacklisted);
        }
    }

    function setEmergencyStop(bool stopped) external onlyRole(EMERGENCY_ROLE) {
        emergencyStop = stopped;
        emit EmergencyStopChanged(stopped);
    }

    function pause()   external onlyRole(GOVERNOR_ROLE){ _pause(); }
    function unpause() external onlyRole(GOVERNOR_ROLE){ _unpause(); }

    // ───────────────────────── role-based exemption sync helper
    /// @notice Mark all current members of a role as exempt (fees & limits). Useful when re-assign roles post-deploy.
    function syncRoleExemptions(bytes32 role, bool fee, bool limits) external onlyRole(GOVERNOR_ROLE) {
        uint256 n = getRoleMemberCount(role);
        for (uint256 i=0;i<n;i++){
            address a = getRoleMember(role, i);
            _setExempt(a, fee, limits);
            emit ExemptionsUpdated(a, fee, limits);
        }
        emit RoleExemptionsSynced(role, n);
    }

    // ───────────────────────── views
    function isPair(address a) public view returns(bool){ return _lpPairs.contains(a); }
    function lpPairs() external view returns(address[] memory){ return _lpPairs.values(); }
    function quadraticVotesOf(address who) external view returns(uint256){ return Math.sqrt(getVotes(who)); }
    function isBlacklisted(address account) external view returns(bool) { return blacklisted[account]; }

    // ───────────────────────── internal helpers
    function _setExempt(address account, bool fee, bool limits) internal {
        feeExempt[account]    = fee;
        limitsExempt[account] = limits;
    }

    function _isBuy(address from, address /*to*/) internal view returns(bool){ return isPair(from); }
    function _isSell(address /*from*/, address to) internal view returns(bool){ return isPair(to); }

    function _updateEma(uint256 amount) internal {
        uint256 sup = totalSupply();
        if (sup==0) return;
        uint256 vNow = (amount * BPS) / sup;
        vEmaBps = (vEmaBps * emaDecayBps + vNow * (BPS - emaDecayBps)) / BPS;
    }

    function _computeFeeBps(address from, address to) internal view returns(uint16){
        if (_isBuy(from,to))  return fees.buyBps;
        if (_isSell(from,to)) return fees.sellBps;
        return fees.transferBps; // 0%
    }

    // ───────────────────────── guard checks 
    function _enforceGuards(address from, address to, uint256 amount) internal view {
        // Global kill-switch
        require(!emergencyStop, "NOX: emergency stop");
        // Blacklist protection
        require(!blacklisted[from] && !blacklisted[to], "NOX: blacklisted");

        // Same-block guard: prevent multiple tx by same sender in one block unless exempt
        if (sameBlockGuardEnabled && !limitsExempt[from]) {
            require(lastTxBlock[from] != block.number, "NOX: same-block");
        }

        // Max TX size (0.5%) — apply ONLY on buys/sells 
        if (txLimitEnabled && !limitsExempt[from]) {
            bool isTrade = _isBuy(from,to) || _isSell(from,to);
            if (isTrade) {
                uint256 maxTx = (totalSupply() * maxTxBps) / BPS;
                require(amount <= maxTx, "NOX: >max trade");
            }
        }

        // Sell cooldown
        if (_isSell(from,to) && sellCooldown>0 && !limitsExempt[from]) {
            require(block.timestamp >= lastSellTime[from] + sellCooldown, "NOX: sell cooldown");
        }
    }

    function _takeFeesAndDeflation(address from, address to, uint256 amount)
        internal returns(uint256 receiveAmount)
    {
        uint16 feeBps = _computeFeeBps(from,to);
        require(uint256(feeBps)+deflationBps <= MAX_SUM_BPS, "NOX: fee+defl cap");

        uint256 feeAmt = (amount * feeBps) / BPS;
        uint256 defAmt = (amount * deflationBps) / BPS;
        uint256 totalDeduct = feeAmt + defAmt;
        require(totalDeduct < amount, "NOX: deductions>=amount");

        if (feeAmt>0){
            // split per fee shares (10/40/20/30)
            uint256 toBurn = (feeAmt * fees.burnShareBps) / BPS;
            uint256 toLiq  = (feeAmt * fees.liquidityShareBps) / BPS;
            uint256 toTre  = (feeAmt * fees.treasuryShareBps) / BPS;
            uint256 toDev  = feeAmt - toBurn - toLiq - toTre;

            if (toBurn>0) _burn(from, toBurn);
            if (toLiq>0)  super._transfer(from, liquidityCollector, toLiq);
            if (toTre>0)  super._transfer(from, treasury, toTre);
            if (toDev>0)  super._transfer(from, devWallet, toDev);
        }
        if (defAmt>0){ _burn(from, defAmt); }

        receiveAmount = amount - totalDeduct;
    }

    // ───────────────────────── ERC20 override (v5 uses _update instead of _transfer)
    function _update(address from, address to, uint256 amount) internal override(ERC20Upgradeable, ERC20PausableUpgradeable, ERC20VotesUpgradeable) {
        // Track burns for totalBurned
        if (to == address(0)) {
            totalBurned += amount;
        }
        
        // Skip guards for minting/burning
        if (from != address(0) && to != address(0)) {
            _enforceGuards(from,to,amount);

            // Optional price impact veto (pre-sell)
            if (_isSell(from,to) && address(priceImpactController)!=address(0)) {
                priceImpactController.onBeforeSell(from, amount); // revert if impact too high
            }

            // compute fees (unless either side is fee-exempt)
            uint256 receiveAmount = amount;
            if (!feeExempt[from] && !feeExempt[to]) {
                receiveAmount = _takeFeesAndDeflation(from,to,amount);
            }

            // Max wallet (4%) — apply on incoming (except sells), unless exempt
            if (walletLimitEnabled && !_isSell(from,to) && !limitsExempt[to]) {
                uint256 maxWallet = (totalSupply()*maxWalletBps)/BPS;
                require(balanceOf(to)+receiveAmount <= maxWallet, "NOX: >max wallet");
            }

            // book-keeping
            lastTxBlock[from] = block.number;
            _updateEma(amount);

            if (_isSell(from,to)) {
                lastSellTime[from] = uint64(block.timestamp);
                emit SellCooldownEnforced(from, uint64(block.timestamp));
            }

            // Update amount for actual transfer
            amount = receiveAmount;
        }

        super._update(from, to, amount);
    }

    // ───────────────────────── UUPS auth
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    // ───────────────────────── OZ multiple inheritance hooks
    // _update is implemented above with custom logic

    // _burn tracking moved to _update hook above

    // Resolve nonces conflict between ERC20Permit and Nonces
    function nonces(address owner)
        public view override(ERC20PermitUpgradeable, NoncesUpgradeable) returns (uint256)
    {
        return super.nonces(owner);
    }

    // ERC165 support passthrough
    function supportsInterface(bytes4 interfaceId)
        public view override(AccessControlEnumerableUpgradeable)
        returns (bool)
    { return super.supportsInterface(interfaceId); }

    // storage gap for future upgrades (reserve space)
    uint256[36] private __noxGap;
}
