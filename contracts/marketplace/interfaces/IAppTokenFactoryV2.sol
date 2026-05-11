// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

interface IAppTokenFactoryV2 {
    struct LaunchParamsV2 {
        bytes32 capsuleId;
        bytes32 releaseId;
        string  name;
        string  symbol;
        string  metadataURI;
        uint256 graduationSupply;
        uint256 lpReserveCap;
        uint16  tradingFeeBps;
        uint16  graduationFeeBps;
    }

    struct TokenInfoV2 {
        address token;
        bytes32 capsuleId;
        bytes32 releaseId;
        bytes32 manifestHash;
        bytes32 packageHash;
        address publisher;
        uint256 launchedAt;
    }

    event AppTokenCreatedV2(
        bytes32 indexed capsuleId,
        bytes32 indexed releaseId,
        address indexed publisher,
        address token,
        string  name,
        string  symbol,
        uint256 graduationSupply,
        uint256 lpReserveCap
    );
    event LaunchEnabledChanged(bool oldValue, bool newValue, address indexed by);
    event UniswapInfraUpdated(address weth, address uniV2Factory, address uniV2Router, address lpBurnTo);
    event BondingTokenImplV2Updated(address indexed oldImpl, address indexed newImpl);

    error LaunchDisabled();
    error InvalidName();
    error InvalidSymbol();
    error CapsuleMissing();
    error NotPublisher();
    error ReleaseMismatch();
    error ReleaseNotPublished();
    error AlreadyLaunched();
    error LaunchFeeRequired();
    error InvalidAddress();
    error InvalidGraduationFee(uint16 cap, uint16 supplied);
    error UniswapInfraUnset();
    error InvalidImplementation();

    function createAppTokenV2(LaunchParamsV2 calldata p) external payable returns (address token);
    function setBondingTokenImplV2(address newImpl) external;
    function setLaunchEnabled(bool enabled) external;
    function setUniswapInfra(address weth, address uniV2Factory, address uniV2Router, address lpBurnTo) external;

    function launchEnabled() external view returns (bool);
    function bondingTokenImplV2() external view returns (address);
    function tokenForCapsule(bytes32 capsuleId) external view returns (address);
    function capsuleForToken(address token) external view returns (bytes32);
}
