// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Initializable}              from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable}           from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable}        from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AccessControlUpgradeable}   from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20}                     from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAppBondingTokenV2}                                from "../interfaces/IAppBondingTokenV2.sol";
import {IFeeRouter}                                        from "../interfaces/IFeeRouter.sol";
import {BondingCurveLib}                                   from "../libraries/BondingCurveLib.sol";
import {IUniswapV2Factory, IUniswapV2Pair, IUniswapV2Router02} from "../interfaces/IUniswapV2.sol";

contract AppBondingTokenV2 is
    IAppBondingTokenV2,
    Initializable,
    ERC20Upgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    AccessControlUpgradeable
{
    bytes32 public constant PAUSER_ROLE  = keccak256("PAUSER_ROLE");
    bytes32 public constant FACTORY_ROLE = keccak256("FACTORY_ROLE");

    uint16  public constant MAX_GRADUATION_FEE_BPS = 100;
    uint256 internal constant ONE = 1e18;
    uint256 internal constant BPS = 10_000;

    AppLink                  private _link;
    address                  public  feeRouter;
    string                   public  metadataURI;
    uint256                  public  graduationSupply;
    uint16                   public  feeBps;
    bool                     public  graduated;
    uint256                  private _reserve;

    address                  public  pair;
    address                  public  lpBurnTo;
    uint256                  public  lpReserveCap;
    uint16                   public  graduationFeeBps;
    address                  public  weth;
    IUniswapV2Factory        public  uniV2Factory;
    IUniswapV2Router02       public  uniV2Router;

    error AlreadyGraduated();
    error NotGraduatedYet();
    error InsufficientReserveBalance();
    error SlippageExceeded();
    error ZeroEthIn();
    error ZeroTokensIn();
    error TransferFailed();
    error InvalidAddress();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        AppLink calldata link_,
        address feeRouter_,
        string calldata name_,
        string calldata symbol_,
        string calldata metadataURI_,
        GraduationConfig calldata cfg
    ) external initializer {
        _validateInit(link_.publisher, feeRouter_, cfg);
        __ERC20_init(name_, symbol_);
        __ReentrancyGuard_init();
        __Pausable_init();
        __AccessControl_init();

        _link             = link_;
        feeRouter         = feeRouter_;
        metadataURI       = metadataURI_;
        graduationSupply  = cfg.graduationSupply;
        feeBps            = cfg.tradingFeeBps;
        graduationFeeBps  = cfg.graduationFeeBps;
        weth              = cfg.weth;
        uniV2Factory      = IUniswapV2Factory(cfg.uniV2Factory);
        uniV2Router       = IUniswapV2Router02(cfg.uniV2Router);
        lpBurnTo          = cfg.lpBurnTo;
        lpReserveCap      = cfg.lpReserveCap;

        _grantRole(DEFAULT_ADMIN_ROLE, link_.publisher);
        _grantRole(PAUSER_ROLE,        link_.publisher);
        _grantRole(FACTORY_ROLE,       msg.sender);
    }

    function _validateInit(address publisher_, address feeRouter_, GraduationConfig calldata cfg) private pure {
        if (publisher_ == address(0))         revert InvalidAddress();
        if (feeRouter_ == address(0))         revert InvalidAddress();
        if (cfg.weth == address(0))           revert InvalidUniswapAddresses();
        if (cfg.uniV2Factory == address(0))   revert InvalidUniswapAddresses();
        if (cfg.uniV2Router == address(0))    revert InvalidUniswapAddresses();
        if (cfg.lpBurnTo == address(0))       revert InvalidAddress();
        if (cfg.graduationSupply == 0)        revert BondingCurveLib.InvalidGraduationSupply();
        if (cfg.tradingFeeBps >= BPS)         revert BondingCurveLib.InvalidFee();
        if (cfg.graduationFeeBps > MAX_GRADUATION_FEE_BPS) {
            revert GraduationFeeTooHigh(MAX_GRADUATION_FEE_BPS, cfg.graduationFeeBps);
        }
        if (cfg.lpReserveCap == 0)            revert LpReserveCapZero();

        uint256 terminalReserveMax = BondingCurveLib.reserveAtSupply(cfg.graduationSupply);
        uint256 terminalPrice      = BondingCurveLib.priceAtSupply(cfg.graduationSupply);
        if (terminalPrice == 0)               revert BondingCurveLib.InvalidGraduationSupply();
        uint256 numer = terminalReserveMax * (BPS - cfg.graduationFeeBps) * ONE;
        uint256 denom = BPS * terminalPrice;
        uint256 maxNeeded = (numer + denom - 1) / denom;
        if (cfg.lpReserveCap < maxNeeded) {
            revert LpReserveCapTooLow(maxNeeded, cfg.lpReserveCap);
        }
    }

    function buy(uint256 minTokensOut)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 tokensOut)
    {
        if (graduated)            revert AlreadyGraduated();
        if (msg.value == 0)       revert ZeroEthIn();

        (uint256 tokens, uint256 fee) = BondingCurveLib.quoteBuy(
            totalSupply(), graduationSupply, msg.value, feeBps
        );
        if (tokens < minTokensOut) revert SlippageExceeded();
        if (tokens == 0)           revert ZeroTokensIn();

        _reserve += (msg.value - fee);

        if (fee > 0) {
            IFeeRouter(feeRouter).routeETH{value: fee}(
                IFeeRouter.RevenueSource.TradingFee,
                _link.capsuleId,
                _link.publisher
            );
        }

        _mint(msg.sender, tokens);
        emit Buy(msg.sender, msg.value, tokens, fee, totalSupply());
        return tokens;
    }

    function sell(uint256 tokensIn, uint256 minEthOut)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 ethOut)
    {
        if (graduated)                          revert AlreadyGraduated();
        if (tokensIn == 0)                      revert ZeroTokensIn();
        if (balanceOf(msg.sender) < tokensIn)   revert InsufficientReserveBalance();

        (uint256 outAmt, uint256 fee) = BondingCurveLib.quoteSell(totalSupply(), tokensIn, feeBps);
        if (outAmt < minEthOut)                 revert SlippageExceeded();

        _burn(msg.sender, tokensIn);
        uint256 totalDelta = outAmt + fee;
        if (_reserve < totalDelta)              revert InsufficientReserveBalance();
        _reserve -= totalDelta;

        if (fee > 0) {
            IFeeRouter(feeRouter).routeETH{value: fee}(
                IFeeRouter.RevenueSource.TradingFee,
                _link.capsuleId,
                _link.publisher
            );
        }
        (bool ok, ) = msg.sender.call{value: outAmt}("");
        if (!ok) revert TransferFailed();

        emit Sell(msg.sender, tokensIn, outAmt, fee, totalSupply());
        return outAmt;
    }

    function graduate() external nonReentrant whenNotPaused {
        if (graduated)                              revert AlreadyGraduated();
        if (totalSupply() < graduationSupply)       revert NotGraduatedYet();

        graduated = true;
        uint256 reserveSnapshot = _reserve;
        _reserve = 0;

        uint256 feeAmt = reserveSnapshot * graduationFeeBps / BPS;
        uint256 reserveAfterFee = reserveSnapshot - feeAmt;
        if (feeAmt > 0) {
            IFeeRouter(feeRouter).routeETH{value: feeAmt}(
                IFeeRouter.RevenueSource.GraduationFee,
                _link.capsuleId,
                _link.publisher
            );
        }

        uint256 terminalPrice = BondingCurveLib.priceAtSupply(graduationSupply);
        uint256 tokensToLp = reserveAfterFee * ONE / terminalPrice;
        if (tokensToLp > lpReserveCap) {
            revert LpReserveCapTooLow(tokensToLp, lpReserveCap);
        }

        address _pair = _ensureCleanPair();
        pair = _pair;

        _mint(address(this), tokensToLp);

        _approve(address(this), address(uniV2Router), tokensToLp);

        (uint256 amountToken, uint256 amountETH, uint256 liquidity) =
            uniV2Router.addLiquidityETH{value: reserveAfterFee}(
                address(this),
                tokensToLp,
                tokensToLp,
                reserveAfterFee,
                lpBurnTo,
                block.timestamp
            );

        if (amountToken != tokensToLp || amountETH != reserveAfterFee) {
            revert LiquidityCreationFailed(tokensToLp, reserveAfterFee, amountToken, amountETH);
        }

        _approve(address(this), address(uniV2Router), 0);

        uint256 stuckTokens = balanceOf(address(this));
        if (stuckTokens != 0) revert PostGraduationStuckTokens(stuckTokens);
        uint256 stuckEth = address(this).balance;
        if (stuckEth != 0)    revert PostGraduationStuckEth(stuckEth);

        emit GraduatedToUniswap(
            _pair, lpBurnTo, reserveAfterFee, tokensToLp, liquidity, feeAmt, terminalPrice
        );
        emit Graduated(totalSupply(), reserveAfterFee, block.timestamp);
    }

    function quoteBuy(uint256 ethIn) external view returns (uint256 tokensOut, uint256 fee) {
        return BondingCurveLib.quoteBuy(totalSupply(), graduationSupply, ethIn, feeBps);
    }
    function quoteSell(uint256 tokensIn) external view returns (uint256 ethOut, uint256 fee) {
        return BondingCurveLib.quoteSell(totalSupply(), tokensIn, feeBps);
    }
    function currentPrice() external view returns (uint256) {
        return BondingCurveLib.priceAtSupply(totalSupply());
    }
    function reserveBalance() external view returns (uint256) { return _reserve; }
    function bondingSupply() external view returns (uint256)  { return totalSupply(); }
    function graduationProgress() external view returns (uint256) {
        return BondingCurveLib.graduationProgressBps(totalSupply(), graduationSupply);
    }
    function isGraduated() external view returns (bool)         { return graduated; }
    function appLink() external view returns (AppLink memory)   { return _link; }

    function terminalPriceWeiPerToken() external view returns (uint256) {
        return BondingCurveLib.priceAtSupply(graduationSupply);
    }
    function maxTokensToLp() external view returns (uint256) {
        uint256 terminalReserveMax = BondingCurveLib.reserveAtSupply(graduationSupply);
        uint256 terminalPrice      = BondingCurveLib.priceAtSupply(graduationSupply);
        if (terminalPrice == 0) return 0;
        uint256 numer = terminalReserveMax * (BPS - graduationFeeBps) * ONE;
        uint256 denom = BPS * terminalPrice;
        return (numer + denom - 1) / denom;
    }
    function expectedTokensToLp() external view returns (uint256) {
        uint256 terminalPrice = BondingCurveLib.priceAtSupply(graduationSupply);
        if (terminalPrice == 0) return 0;
        return _reserve * (BPS - graduationFeeBps) * ONE / (BPS * terminalPrice);
    }

    function _ensureCleanPair() private returns (address _pair) {
        _pair = uniV2Factory.getPair(address(this), weth);
        if (_pair == address(0)) {
            _pair = uniV2Factory.createPair(address(this), weth);
            emit UniswapPairCreated(_pair, address(this), weth);
        } else {
            (uint112 r0, uint112 r1, ) = IUniswapV2Pair(_pair).getReserves();
            if (r0 != 0 || r1 != 0) revert PairAlreadySeeded(r0, r1);
        }
        uint256 tokBal  = balanceOf(_pair);
        uint256 wethBal = IERC20(weth).balanceOf(_pair);
        if (tokBal != 0 || wethBal != 0) {
            revert PairAlreadySeeded(uint112(tokBal), uint112(wethBal));
        }
    }

    function pauseTrading()  external onlyRole(PAUSER_ROLE) { _pause();    emit TradingPaused(msg.sender, block.timestamp); }
    function resumeTrading() external onlyRole(PAUSER_ROLE) { _unpause();  emit TradingResumed(msg.sender, block.timestamp); }
    function declareEmergency(string calldata reason) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
        emit EmergencyState(msg.sender, reason);
    }

    receive() external payable {
        if (msg.sender != address(uniV2Router)) {
            revert("Direct ETH not accepted; use buy()");
        }
    }
}
