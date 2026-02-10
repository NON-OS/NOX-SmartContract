// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
 *  ███╗   ██╗ ██████╗ ███╗   ██╗ ██████╗ ███████╗
 *  ████╗  ██║██╔═══██╗████╗  ██║██╔═══██╗██╔════╝
 *  ██╔██╗ ██║██║   ██║██╔██╗ ██║██║   ██║███████╗  NONOS // NOX
 *  ██║╚██╗██║██║   ██║██║╚██╗██║██║   ██║╚════██║ 
 *  ██║ ╚████║╚██████╔╝██║ ╚████║╚██████╔╝███████║  static 2/2 tax
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
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { ERC20BurnableUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import { ERC20PermitUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { ERC20VotesUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import { ERC20PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { NoncesUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";

interface IPriceImpactController {
    function onBeforeSell(address from, uint256 amount) external view;
}

interface IUniswapV2Router02 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external;
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

contract NONOS_NOX_MAINNET_V2 is
    Initializable,
    UUPSUpgradeable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ERC20PermitUpgradeable,
    ERC20VotesUpgradeable,
    ERC20PausableUpgradeable,
    AccessControlUpgradeable
{

    bytes32 public constant GOVERNOR_ROLE  = keccak256("GOVERNOR_ROLE");
    bytes32 public constant UPGRADER_ROLE  = keccak256("UPGRADER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    uint256 public constant MAX_SUPPLY  = 800_000_000e18;
    uint16  public constant BPS         = 10_000;
    uint16  public constant MAX_FEE_BPS = 1_000;
    uint16  public constant MAX_DEF_BPS = 200;
    uint16  public constant MAX_SUM_BPS = 2_000;

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
    mapping(address => uint64)  public lastSellTime;

    bool   public sameBlockGuardEnabled;
    bool   public txLimitEnabled;
    bool   public walletLimitEnabled;
    uint16 public maxTxBps;
    uint16 public maxWalletBps;
    uint64 public sellCooldown;
    bool   public emergencyStop;

    IPriceImpactController public priceImpactController;

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

    event AutoSwapExecuted(uint256 tokensSwapped, uint256 ethReceived);
    event V2Initialized(address router);

    IUniswapV2Router02 public uniswapRouter;
    address public uniswapPair;
    uint256 public autoSwapThreshold;
    uint16 public autoSwapSlippageBps;
    bool public autoSwapEnabled;
    bool private _inSwap;
    bool public v2Initialized;

    uint256[32] private __noxGapV2;

    modifier lockTheSwap() { _inSwap = true; _; _inSwap = false; }

    constructor() { _disableInitializers(); }

    function initialize(
        address mainReceiver, address _devWallet, address _stakingVault, address _daoWallet,
        address _liquidityCollector, address _cexListingsWallet, address _contributorsWallet,
        address _nftsWallet, address _marketingWallet
    ) public initializer {
        require(mainReceiver!=address(0) && _devWallet!=address(0) && _stakingVault!=address(0) && _daoWallet!=address(0) && _liquidityCollector!=address(0) && _cexListingsWallet!=address(0) && _contributorsWallet!=address(0) && _nftsWallet!=address(0) && _marketingWallet!=address(0), "0");
        __UUPSUpgradeable_init(); __ERC20_init("NONOS", "NOX"); __ERC20Burnable_init(); __ERC20Permit_init("NONOS"); __ERC20Votes_init(); __ERC20Pausable_init(); __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender()); _grantRole(GOVERNOR_ROLE, _msgSender()); _grantRole(UPGRADER_ROLE, _msgSender()); _grantRole(EMERGENCY_ROLE, _msgSender());
        _mint(_devWallet, (MAX_SUPPLY * 300) / BPS); _mint(_stakingVault, (MAX_SUPPLY * 400) / BPS); _mint(_daoWallet, (MAX_SUPPLY * 300) / BPS); _mint(_liquidityCollector, (MAX_SUPPLY * 400) / BPS); _mint(_cexListingsWallet, (MAX_SUPPLY * 400) / BPS); _mint(_contributorsWallet, (MAX_SUPPLY * 300) / BPS); _mint(_nftsWallet, (MAX_SUPPLY * 150) / BPS); _mint(_marketingWallet, (MAX_SUPPLY * 250) / BPS); _mint(mainReceiver, MAX_SUPPLY - (MAX_SUPPLY * 2500) / BPS);
        devWallet = _devWallet; stakingVault = _stakingVault; daoWallet = _daoWallet; liquidityCollector = _liquidityCollector; cexListingsWallet = _cexListingsWallet; contributorsWallet = _contributorsWallet; nftsWallet = _nftsWallet; marketingWallet = _marketingWallet; treasury = _daoWallet;
        fees = FeeConfig(200, 200, 0, 1000, 4000, 2000, 3000);
        sameBlockGuardEnabled = true; txLimitEnabled = true; walletLimitEnabled = true; maxTxBps = 50; maxWalletBps = 400; sellCooldown = 20;
        _setExempt(_msgSender(), true, true); _setExempt(address(this), true, true); _setExempt(mainReceiver, true, true); _setExempt(_devWallet, true, true); _setExempt(_stakingVault, true, true); _setExempt(_daoWallet, true, true); _setExempt(_liquidityCollector, true, true); _setExempt(_cexListingsWallet, true, true); _setExempt(_contributorsWallet, true, true); _setExempt(_nftsWallet, true, true); _setExempt(_marketingWallet, true, true);
    }

    function initializeV2(address _router, uint256 _swapThreshold, uint16 _slippageBps) external onlyRole(GOVERNOR_ROLE) {
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

    function setAutoSwapConfig(uint256 _threshold, uint16 _slippageBps, bool _enabled) external onlyRole(GOVERNOR_ROLE) {
        require(v2Initialized, "5");
        require(_slippageBps <= 300, "3");
        autoSwapThreshold = _threshold;
        autoSwapSlippageBps = _slippageBps;
        autoSwapEnabled = _enabled;
    }

    function triggerAutoSwap() external onlyRole(GOVERNOR_ROLE) {
        _swapTokensForEth(balanceOf(address(this)));
    }

    function _swapTokensForEth(uint256 tokenAmount) private lockTheSwap {
        if (tokenAmount == 0) return;
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapRouter.WETH();
        _approve(address(this), address(uniswapRouter), tokenAmount);
        uint256 ethBefore = address(this).balance;
        try uniswapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(tokenAmount, 0, path, address(this), block.timestamp) {
            uint256 ethReceived = address(this).balance - ethBefore;
            if (ethReceived > 0) {
                uint256 totalShares = uint256(fees.liquidityShareBps) + fees.treasuryShareBps + fees.devShareBps;
                uint256 toLiq = (ethReceived * fees.liquidityShareBps) / totalShares;
                uint256 toTre = (ethReceived * fees.treasuryShareBps) / totalShares;
                payable(liquidityCollector).call{value: toLiq}("");
                payable(treasury).call{value: toTre}("");
                payable(devWallet).call{value: ethReceived - toLiq - toTre}("");
            }
            emit AutoSwapExecuted(tokenAmount, ethReceived);
        } catch {}
    }

    function _takeFeesAndDeflation(address from, address to, uint256 amount) internal returns(uint256 receiveAmount) {
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

    function _update(address from, address to, uint256 amount) internal override(ERC20Upgradeable, ERC20PausableUpgradeable, ERC20VotesUpgradeable) {
        if (to == address(0)) totalBurned += amount;
        if (from != address(0) && to != address(0)) {
            _enforceGuards(from, to, amount);
            if (_isSell(from, to) && address(priceImpactController) != address(0)) priceImpactController.onBeforeSell(from, amount);
            uint256 receiveAmount = amount;
            if (!feeExempt[from] && !feeExempt[to]) receiveAmount = _takeFeesAndDeflation(from, to, amount);
            if (v2Initialized && autoSwapEnabled && !_inSwap && _isSell(from, to) && balanceOf(address(this)) >= autoSwapThreshold) _swapTokensForEth(balanceOf(address(this)));
            if (walletLimitEnabled && !_isSell(from, to) && !limitsExempt[to]) require(balanceOf(to) + receiveAmount <= (totalSupply() * maxWalletBps) / BPS, "9");
            lastTxBlock[from] = block.number;
            _updateEma(amount);
            if (_isSell(from, to)) { lastSellTime[from] = uint64(block.timestamp); emit SellCooldownEnforced(from, uint64(block.timestamp)); }
            amount = receiveAmount;
        }
        super._update(from, to, amount);
    }

    function setRecipients(address _dev, address _staking, address _dao, address _liq) external onlyRole(GOVERNOR_ROLE) {
        require(_dev!=address(0)&&_staking!=address(0)&&_dao!=address(0)&&_liq!=address(0),"0");
        devWallet=_dev; stakingVault=_staking; daoWallet=_dao; liquidityCollector=_liq; treasury=_dao;
        _setExempt(_dev, true, true); _setExempt(_staking, true, true); _setExempt(_dao, true, true); _setExempt(_liq, true, true);
        emit RecipientsUpdated(_dev, _staking, _dao, _liq);
    }

    function setAuxRecipients(address _cex, address _contributors, address _nfts, address _mkt) external onlyRole(GOVERNOR_ROLE) {
        require(_cex!=address(0)&&_contributors!=address(0)&&_nfts!=address(0)&&_mkt!=address(0),"0");
        cexListingsWallet=_cex; contributorsWallet=_contributors; nftsWallet=_nfts; marketingWallet=_mkt;
        _setExempt(_cex, true, true); _setExempt(_contributors, true, true); _setExempt(_nfts, true, true); _setExempt(_mkt, true, true);
        emit AuxRecipientsUpdated(_cex, _contributors, _nfts, _mkt);
    }

    function setFees(uint16 buyBps, uint16 sellBps, uint16 transferBps, uint16 burnShareBps, uint16 liqShareBps, uint16 treShareBps, uint16 devShareBps) external onlyRole(GOVERNOR_ROLE) {
        require(buyBps<=MAX_FEE_BPS && sellBps<=MAX_FEE_BPS && transferBps<=MAX_FEE_BPS, "a");
        require(uint256(burnShareBps)+liqShareBps+treShareBps+devShareBps==BPS, "b");
        fees = FeeConfig(buyBps, sellBps, transferBps, burnShareBps, liqShareBps, treShareBps, devShareBps);
        emit FeesUpdated(fees);
    }

    function setDeflationParams(uint16 _deflationBps, uint16 _alphaBps, uint16 _emaDecayBps) external onlyRole(GOVERNOR_ROLE) {
        require(_deflationBps<=MAX_DEF_BPS, "c");
        require(_emaDecayBps<=BPS && _alphaBps<=500, "d");
        deflationBps=_deflationBps; alphaBps=_alphaBps; emaDecayBps=_emaDecayBps;
        emit DeflationUpdated(deflationBps, alphaBps, emaDecayBps);
    }

    function setGuards(bool sameBlock, bool txLimit, bool walletLimit, uint16 _maxTxBps, uint16 _maxWalletBps, uint64 _sellCooldown) external onlyRole(GOVERNOR_ROLE) {
        require(_maxTxBps<=BPS && _maxWalletBps<=BPS, "e");
        sameBlockGuardEnabled=sameBlock; txLimitEnabled=txLimit; walletLimitEnabled=walletLimit;
        maxTxBps=_maxTxBps; maxWalletBps=_maxWalletBps; sellCooldown=_sellCooldown;
        emit GuardsUpdated(sameBlock, txLimit, walletLimit, _maxTxBps, _maxWalletBps, _sellCooldown);
    }

    function setExemptions(address account, bool _feeExempt, bool _limitsExempt) external onlyRole(GOVERNOR_ROLE) {
        _setExempt(account, _feeExempt, _limitsExempt);
        emit ExemptionsUpdated(account, _feeExempt, _limitsExempt);
    }

    function setPair(address pair, bool status) external onlyRole(GOVERNOR_ROLE) {
        require(pair!=address(0),"0");
        if(status && !_isLpPair[pair]) { _isLpPair[pair]=true; _lpPairsList.push(pair); }
        else if(!status) _isLpPair[pair]=false;
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

    function setEmergencyStop(bool stopped) external onlyRole(EMERGENCY_ROLE) { emergencyStop = stopped; emit EmergencyStopChanged(stopped); }

    function pause() external onlyRole(GOVERNOR_ROLE) { _pause(); }
    function unpause() external onlyRole(GOVERNOR_ROLE) { _unpause(); }

    function isPair(address a) public view returns(bool) { return _isLpPair[a]; }
    function lpPairs() external view returns(address[] memory) { return _lpPairsList; }
    function isBlacklisted(address account) external view returns(bool) { return blacklisted[account]; }

    function _setExempt(address account, bool fee, bool limits) internal { feeExempt[account] = fee; limitsExempt[account] = limits; }
    function _isBuy(address from, address) internal view returns(bool) { return isPair(from); }
    function _isSell(address, address to) internal view returns(bool) { return isPair(to); }

    function _updateEma(uint256 amount) internal {
        uint256 sup = totalSupply();
        if (sup == 0) return;
        uint256 vNow = (amount * BPS) / sup;
        vEmaBps = (vEmaBps * emaDecayBps + vNow * (BPS - emaDecayBps)) / BPS;
    }

    function _computeFeeBps(address from, address to) internal view returns(uint16) {
        if (_isBuy(from, to)) return fees.buyBps;
        if (_isSell(from, to)) return fees.sellBps;
        return fees.transferBps;
    }

    function _enforceGuards(address from, address to, uint256 amount) internal view {
        require(!emergencyStop, "f");
        require(!blacklisted[from] && !blacklisted[to], "g");
        if (sameBlockGuardEnabled && !limitsExempt[from]) require(lastTxBlock[from] != block.number, "h");
        if (txLimitEnabled && !limitsExempt[from] && (_isBuy(from, to) || _isSell(from, to))) require(amount <= (totalSupply() * maxTxBps) / BPS, "i");
        if (_isSell(from, to) && sellCooldown > 0 && !limitsExempt[from]) require(block.timestamp >= lastSellTime[from] + sellCooldown, "j");
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}
    function nonces(address owner) public view override(ERC20PermitUpgradeable, NoncesUpgradeable) returns (uint256) { return super.nonces(owner); }
    function supportsInterface(bytes4 interfaceId) public view override(AccessControlUpgradeable) returns (bool) { return super.supportsInterface(interfaceId); }

    receive() external payable {}
}
