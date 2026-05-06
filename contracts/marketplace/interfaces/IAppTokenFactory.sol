// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

interface IAppTokenFactory {
    struct LaunchParams {
        bytes32 capsuleId;
        bytes32 releaseId;
        string  name;
        string  symbol;
        string  metadataURI;
        uint256 graduationSupply;
        uint16  feeBps;
    }

    struct TokenInfo {
        address token;
        bytes32 capsuleId;
        bytes32 releaseId;
        bytes32 manifestHash;
        bytes32 packageHash;
        address publisher;
        uint256 launchedAt;
    }

    event AppTokenCreated(
        bytes32 indexed capsuleId,
        bytes32 indexed releaseId,
        address indexed publisher,
        address token,
        string name,
        string symbol
    );
    event ImplementationUpdated(address indexed oldImpl, address indexed newImpl);
    event RegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event FeeRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event LaunchFeeUpdated(uint256 oldFee, uint256 newFee);

    function createAppToken(LaunchParams calldata p) external payable returns (address token);

    function tokenForCapsule(bytes32 capsuleId) external view returns (address);
    function capsuleForToken(address token) external view returns (bytes32);
    function getTokenInfo(address token) external view returns (TokenInfo memory);
    function tokensByPublisher(address publisher) external view returns (address[] memory);
    function tokenCount() external view returns (uint256);
}
