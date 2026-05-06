// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {FeeSwapErrors} from "./FeeSwapErrors.sol";
import {FeeSwapEvents} from "./FeeSwapEvents.sol";
import {IFeeSwapRouter, IAppTokenFactoryLite, SwapParams} from "./IFeeSwapRouter.sol";

contract FeeSwapRouter is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    FeeSwapErrors,
    FeeSwapEvents,
    IFeeSwapRouter
{
    using SafeERC20 for IERC20;

    bytes32 public constant CONFIG_ROLE   = keccak256("CONFIG_ROLE");
    bytes32 public constant PAUSER_ROLE   = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint16 public constant MAX_FEE_BPS = 100;
    uint16 public constant BPS_DENOM   = 10000;

    uint16  public feeBps;
    address public feeRecipient;
    bool    public paused;
    mapping(address => bool) public approvedTarget;
    address public appTokenFactory;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(
        address admin,
        address configRole,
        address pauserRole,
        address upgraderRole,
        address feeRecipient_,
        uint16  feeBps_
    ) external initializer {
        if (feeBps_ > MAX_FEE_BPS) revert FeeExceedsCap();
        if (feeRecipient_ == address(0)) revert ZeroFeeRecipient();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CONFIG_ROLE, configRole);
        _grantRole(PAUSER_ROLE, pauserRole);
        _grantRole(UPGRADER_ROLE, upgraderRole);
        feeBps = feeBps_;
        feeRecipient = feeRecipient_;
    }

    function setFeeBps(uint16 newBps) external onlyRole(CONFIG_ROLE) {
        if (newBps > MAX_FEE_BPS) revert FeeExceedsCap();
        emit FeeBpsUpdated(feeBps, newBps);
        feeBps = newBps;
    }

    function setFeeRecipient(address newRecipient) external onlyRole(CONFIG_ROLE) {
        if (newRecipient == address(0)) revert ZeroFeeRecipient();
        emit FeeRecipientUpdated(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    function setTargetApproved(address target, bool ok) external onlyRole(CONFIG_ROLE) {
        if (target == address(0)) revert ZeroAddress();
        approvedTarget[target] = ok;
        emit TargetApprovalSet(target, ok);
    }

    function setAppTokenFactory(address factory) external onlyRole(CONFIG_ROLE) {
        emit AppTokenFactorySet(appTokenFactory, factory);
        appTokenFactory = factory;
    }

    function setPaused(bool p) external onlyRole(PAUSER_ROLE) {
        paused = p;
        emit PausedSet(p);
    }

    function rescueETH(address to, uint256 amount) external onlyRole(CONFIG_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        emit Rescued(address(0), to, amount);
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert SwapFailed("");
    }

    function rescueERC20(address token, address to, uint256 amount) external onlyRole(CONFIG_ROLE) nonReentrant {
        if (to == address(0) || token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        emit Rescued(token, to, amount);
        IERC20(token).safeTransfer(to, amount);
    }

    function _authorizeUpgrade(address) internal view override onlyRole(UPGRADER_ROLE) {}

    function isApprovedTarget(address target) public view returns (bool) {
        if (approvedTarget[target]) return true;
        address factory = appTokenFactory;
        if (factory == address(0) || factory.code.length == 0) return false;
        try IAppTokenFactoryLite(factory).isAppToken(target) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }

    function swap(SwapParams calldata p) external payable nonReentrant {
        if (paused) revert PausedError();
        if (!isApprovedTarget(p.target)) revert TargetNotApproved(p.target);
        if (p.amountIn == 0) revert ZeroAmount();
        if (p.inputToken == address(0)) {
            if (msg.value != p.amountIn) revert NotPayable();
        } else {
            if (msg.value != 0) revert NotPayable();
        }

        uint256 net = _collectFee(p.inputToken, p.amountIn);
        uint256 received = _doSwap(p, net);
        if (received < p.minOut) revert InsufficientOutput(received, p.minOut);

        emit SwapExecuted(
            p.routeId, msg.sender, p.receiver,
            p.inputToken, p.outputToken,
            p.amountIn, net, received
        );
    }

    function _collectFee(address asset, uint256 amountIn) internal returns (uint256) {
        if (asset == address(0)) return _takeFeeNative(amountIn);
        return _takeFeeERC20(asset, amountIn, msg.sender);
    }

    function _takeFeeNative(uint256 amountIn) internal returns (uint256 net) {
        uint256 fee = (amountIn * feeBps) / BPS_DENOM;
        if (fee > 0) {
            (bool ok, ) = feeRecipient.call{value: fee}("");
            if (!ok) revert SwapFailed("");
            emit ProtocolFeeCollected(address(0), msg.sender, feeRecipient, fee);
        }
        net = amountIn - fee;
    }

    function _takeFeeERC20(address token, uint256 amountIn, address payer) internal returns (uint256 net) {
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(payer, address(this), amountIn);
        uint256 actual = IERC20(token).balanceOf(address(this)) - balBefore;
        uint256 fee = (actual * feeBps) / BPS_DENOM;
        if (fee > 0) {
            IERC20(token).safeTransfer(feeRecipient, fee);
            emit ProtocolFeeCollected(token, payer, feeRecipient, fee);
        }
        net = actual - fee;
    }

    function _doSwap(SwapParams calldata p, uint256 net) internal returns (uint256) {
        uint256 outBefore = _readBalance(p.outputToken, p.receiver);
        if (p.inputToken == address(0)) {
            uint256 selfEthExpected = address(this).balance - net;
            (bool ok, bytes memory ret) = p.target.call{value: net}(p.data);
            if (!ok) revert SwapFailed(ret);
            uint256 leftover = address(this).balance > selfEthExpected
                ? address(this).balance - selfEthExpected
                : 0;
            if (leftover > 0) {
                (bool r, ) = msg.sender.call{value: leftover}("");
                if (!r) revert SwapFailed("");
                emit LeftoverRefunded(address(0), msg.sender, leftover);
            }
        } else {
            uint256 selfInBefore = IERC20(p.inputToken).balanceOf(address(this));
            IERC20(p.inputToken).forceApprove(p.target, 0);
            IERC20(p.inputToken).forceApprove(p.target, net);
            (bool ok, bytes memory ret) = p.target.call(p.data);
            if (!ok) revert SwapFailed(ret);
            IERC20(p.inputToken).forceApprove(p.target, 0);
            uint256 selfInAfter = IERC20(p.inputToken).balanceOf(address(this));
            uint256 expectedAfter = selfInBefore - net;
            if (selfInAfter > expectedAfter) {
                uint256 leftover = selfInAfter - expectedAfter;
                IERC20(p.inputToken).safeTransfer(msg.sender, leftover);
                emit LeftoverRefunded(p.inputToken, msg.sender, leftover);
            }
        }
        return _readBalance(p.outputToken, p.receiver) - outBefore;
    }

    function _readBalance(address asset, address who) internal view returns (uint256) {
        if (asset == address(0)) return who.balance;
        return IERC20(asset).balanceOf(who);
    }

    receive() external payable {}
}
