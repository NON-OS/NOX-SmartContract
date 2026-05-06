// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Initializable}                from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable}             from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuardUpgradeable}   from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable}          from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AccessControlUpgradeable}     from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {IAppBondingToken} from "../interfaces/IAppBondingToken.sol";
import {IFeeRouter}       from "../interfaces/IFeeRouter.sol";
import {BondingCurveLib}  from "../libraries/BondingCurveLib.sol";

contract AppBondingToken is
    IAppBondingToken,
    Initializable,
    ERC20Upgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    AccessControlUpgradeable
{
    bytes32 public constant PAUSER_ROLE   = keccak256("PAUSER_ROLE");
    bytes32 public constant FACTORY_ROLE  = keccak256("FACTORY_ROLE");

    AppLink   private _link;
    address   public  feeRouter;
    string    public  metadataURI;
    uint256   public  graduationSupply;
    uint16    public  feeBps;
    bool      public  graduated;
    uint256   private _reserve;

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
        uint256 graduationSupply_,
        uint16  feeBps_
    ) external initializer {
        _validateInit(link_.publisher, feeRouter_, graduationSupply_, feeBps_);
        __ERC20_init(name_, symbol_);
        __ReentrancyGuard_init();
        __Pausable_init();
        __AccessControl_init();
        _setLinkAndConfig(link_, feeRouter_, metadataURI_, graduationSupply_, feeBps_);
        _grantRoles(link_.publisher);
    }

    function _validateInit(
        address publisher_,
        address feeRouter_,
        uint256 graduationSupply_,
        uint16  feeBps_
    ) private pure {
        if (publisher_ == address(0)) revert InvalidAddress();
        if (feeRouter_ == address(0)) revert InvalidAddress();
        if (graduationSupply_ == 0) revert BondingCurveLib.InvalidGraduationSupply();
        if (feeBps_ >= 10_000) revert BondingCurveLib.InvalidFee();
    }

    function _setLinkAndConfig(
        AppLink calldata link_,
        address feeRouter_,
        string calldata metadataURI_,
        uint256 graduationSupply_,
        uint16  feeBps_
    ) private {
        _link = link_;
        feeRouter = feeRouter_;
        metadataURI = metadataURI_;
        graduationSupply = graduationSupply_;
        feeBps = feeBps_;
    }

    function _grantRoles(address publisher_) private {
        _grantRole(DEFAULT_ADMIN_ROLE, publisher_);
        _grantRole(PAUSER_ROLE, publisher_);
        _grantRole(FACTORY_ROLE, msg.sender);
    }

    function buy(uint256 minTokensOut)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 tokensOut)
    {
        if (graduated) revert AlreadyGraduated();
        if (msg.value == 0) revert ZeroEthIn();

        (uint256 tokens, uint256 fee) = BondingCurveLib.quoteBuy(
            totalSupply(),
            graduationSupply,
            msg.value,
            feeBps
        );
        if (tokens < minTokensOut) revert SlippageExceeded();
        if (tokens == 0) revert ZeroTokensIn();

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
        if (graduated) revert AlreadyGraduated();
        if (tokensIn == 0) revert ZeroTokensIn();
        if (balanceOf(msg.sender) < tokensIn) revert InsufficientReserveBalance();

        (uint256 outAmt, uint256 fee) = BondingCurveLib.quoteSell(
            totalSupply(),
            tokensIn,
            feeBps
        );
        if (outAmt < minEthOut) revert SlippageExceeded();

        _burn(msg.sender, tokensIn);
        uint256 totalDelta = outAmt + fee;
        if (_reserve < totalDelta) revert InsufficientReserveBalance();
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

    function graduate() external nonReentrant {
        if (graduated) revert AlreadyGraduated();
        if (totalSupply() < graduationSupply) revert NotGraduatedYet();

        graduated = true;
        uint256 reserveSnapshot = _reserve;
        _reserve = 0;

        if (reserveSnapshot > 0) {
            IFeeRouter(feeRouter).routeETH{value: reserveSnapshot}(
                IFeeRouter.RevenueSource.GraduationFee,
                _link.capsuleId,
                _link.publisher
            );
        }
        emit Graduated(totalSupply(), reserveSnapshot, block.timestamp);
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
    function bondingSupply() external view returns (uint256) { return totalSupply(); }

    function graduationProgress() external view returns (uint256) {
        return BondingCurveLib.graduationProgressBps(totalSupply(), graduationSupply);
    }

    function isGraduated() external view returns (bool) { return graduated; }
    function appLink() external view returns (AppLink memory) { return _link; }

    function pauseTrading() external onlyRole(PAUSER_ROLE) {
        _pause();
        emit TradingPaused(msg.sender, block.timestamp);
    }
    function resumeTrading() external onlyRole(PAUSER_ROLE) {
        _unpause();
        emit TradingResumed(msg.sender, block.timestamp);
    }

    function declareEmergency(string calldata reason) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
        emit EmergencyState(msg.sender, reason);
    }

    receive() external payable {
        revert("Direct ETH not accepted; use buy()");
    }
}
