// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {CapsuleRegistry} from "../../contracts/marketplace/core/CapsuleRegistry.sol";
import {AppTokenFactory} from "../../contracts/marketplace/core/AppTokenFactory.sol";
import {AppBondingToken} from "../../contracts/marketplace/core/AppBondingToken.sol";
import {FeeRouter}       from "../../contracts/marketplace/revenue/FeeRouter.sol";

contract DeployFinalizeTest is Test {
    address deployer    = address(0xB33);
    address finalAdmin  = address(0xA1);
    address upgrader    = address(0xA2);
    address pauser      = address(0xA3);
    address validator   = address(0xA4);
    address config      = address(0xA5);
    address treasuryR   = address(0xA6);

    address nftSink     = address(0xE1);
    address stakersSink = address(0xE2);
    address treasury    = address(0xE3);

    CapsuleRegistry registry;
    AppTokenFactory factory;
    AppBondingToken bondingImpl;
    FeeRouter      router;

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    function setUp() public {
        vm.startPrank(deployer);

        CapsuleRegistry regImpl = new CapsuleRegistry();
        registry = CapsuleRegistry(address(new ERC1967Proxy(
            address(regImpl),
            abi.encodeCall(CapsuleRegistry.initialize, (deployer))
        )));

        FeeRouter routerImpl = new FeeRouter();
        router = FeeRouter(payable(address(new ERC1967Proxy(
            address(routerImpl),
            abi.encodeCall(FeeRouter.initialize, (deployer, nftSink, stakersSink, treasury))
        ))));

        bondingImpl = new AppBondingToken();

        AppTokenFactory factoryImpl = new AppTokenFactory();
        factory = AppTokenFactory(address(new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(
                AppTokenFactory.initialize,
                (deployer, address(bondingImpl), address(registry), address(router), 0)
            )
        )));

        vm.stopPrank();
    }

    function test_deployer_initiallyHoldsAllPrivilegedRoles() public view {
        assertTrue(registry.hasRole(DEFAULT_ADMIN_ROLE, deployer));
        assertTrue(registry.hasRole(registry.UPGRADER_ROLE(), deployer));
        assertTrue(registry.hasRole(registry.PAUSER_ROLE(), deployer));
        assertTrue(registry.hasRole(registry.VALIDATOR_ROLE(), deployer));

        assertTrue(factory.hasRole(DEFAULT_ADMIN_ROLE, deployer));
        assertTrue(factory.hasRole(factory.UPGRADER_ROLE(), deployer));
        assertTrue(factory.hasRole(factory.PAUSER_ROLE(), deployer));
        assertTrue(factory.hasRole(factory.CONFIG_ROLE(), deployer));

        assertTrue(router.hasRole(DEFAULT_ADMIN_ROLE, deployer));
        assertTrue(router.hasRole(router.UPGRADER_ROLE(), deployer));
        assertTrue(router.hasRole(router.PAUSER_ROLE(), deployer));
        assertTrue(router.hasRole(router.CONFIG_ROLE(), deployer));
        assertTrue(router.hasRole(router.TREASURY_ROLE(), deployer));
    }

    function _grantFinalRoles() internal {
        vm.startPrank(deployer);
        registry.grantRole(DEFAULT_ADMIN_ROLE,         finalAdmin);
        registry.grantRole(registry.UPGRADER_ROLE(),   upgrader);
        registry.grantRole(registry.PAUSER_ROLE(),     pauser);
        registry.grantRole(registry.VALIDATOR_ROLE(),  validator);

        factory.grantRole(DEFAULT_ADMIN_ROLE,         finalAdmin);
        factory.grantRole(factory.UPGRADER_ROLE(),    upgrader);
        factory.grantRole(factory.PAUSER_ROLE(),      pauser);
        factory.grantRole(factory.CONFIG_ROLE(),      config);

        router.grantRole(DEFAULT_ADMIN_ROLE,         finalAdmin);
        router.grantRole(router.UPGRADER_ROLE(),     upgrader);
        router.grantRole(router.PAUSER_ROLE(),       pauser);
        router.grantRole(router.CONFIG_ROLE(),       config);
        router.grantRole(router.TREASURY_ROLE(),     treasuryR);
        vm.stopPrank();
    }

    function _revokeFromDeployer() internal {
        vm.startPrank(deployer);
        registry.revokeRole(registry.UPGRADER_ROLE(),  deployer);
        registry.revokeRole(registry.PAUSER_ROLE(),    deployer);
        registry.revokeRole(registry.VALIDATOR_ROLE(), deployer);
        registry.revokeRole(DEFAULT_ADMIN_ROLE,        deployer);

        factory.revokeRole(factory.UPGRADER_ROLE(), deployer);
        factory.revokeRole(factory.PAUSER_ROLE(),   deployer);
        factory.revokeRole(factory.CONFIG_ROLE(),   deployer);
        factory.revokeRole(DEFAULT_ADMIN_ROLE,      deployer);

        router.revokeRole(router.UPGRADER_ROLE(), deployer);
        router.revokeRole(router.PAUSER_ROLE(),   deployer);
        router.revokeRole(router.CONFIG_ROLE(),   deployer);
        router.revokeRole(router.TREASURY_ROLE(), deployer);
        router.revokeRole(DEFAULT_ADMIN_ROLE,     deployer);
        vm.stopPrank();
    }

    function test_finalize_grantsAllRolesToFinalAddresses() public {
        _grantFinalRoles();

        assertTrue(registry.hasRole(DEFAULT_ADMIN_ROLE,         finalAdmin));
        assertTrue(registry.hasRole(registry.UPGRADER_ROLE(),   upgrader));
        assertTrue(registry.hasRole(registry.PAUSER_ROLE(),     pauser));
        assertTrue(registry.hasRole(registry.VALIDATOR_ROLE(),  validator));

        assertTrue(factory.hasRole(DEFAULT_ADMIN_ROLE,        finalAdmin));
        assertTrue(factory.hasRole(factory.UPGRADER_ROLE(),   upgrader));
        assertTrue(factory.hasRole(factory.PAUSER_ROLE(),     pauser));
        assertTrue(factory.hasRole(factory.CONFIG_ROLE(),     config));

        assertTrue(router.hasRole(DEFAULT_ADMIN_ROLE,        finalAdmin));
        assertTrue(router.hasRole(router.UPGRADER_ROLE(),    upgrader));
        assertTrue(router.hasRole(router.PAUSER_ROLE(),      pauser));
        assertTrue(router.hasRole(router.CONFIG_ROLE(),      config));
        assertTrue(router.hasRole(router.TREASURY_ROLE(),    treasuryR));
    }

    function test_finalize_revokesDeployerFromAllRoles() public {
        _grantFinalRoles();
        _revokeFromDeployer();

        assertFalse(registry.hasRole(DEFAULT_ADMIN_ROLE, deployer));
        assertFalse(registry.hasRole(registry.UPGRADER_ROLE(), deployer));
        assertFalse(registry.hasRole(registry.PAUSER_ROLE(), deployer));
        assertFalse(registry.hasRole(registry.VALIDATOR_ROLE(), deployer));

        assertFalse(factory.hasRole(DEFAULT_ADMIN_ROLE, deployer));
        assertFalse(factory.hasRole(factory.UPGRADER_ROLE(), deployer));
        assertFalse(factory.hasRole(factory.PAUSER_ROLE(), deployer));
        assertFalse(factory.hasRole(factory.CONFIG_ROLE(), deployer));

        assertFalse(router.hasRole(DEFAULT_ADMIN_ROLE, deployer));
        assertFalse(router.hasRole(router.UPGRADER_ROLE(), deployer));
        assertFalse(router.hasRole(router.PAUSER_ROLE(), deployer));
        assertFalse(router.hasRole(router.CONFIG_ROLE(), deployer));
        assertFalse(router.hasRole(router.TREASURY_ROLE(), deployer));
    }

    function test_deployerCannotUpgradeAfterFinalize() public {
        _grantFinalRoles();
        _revokeFromDeployer();

        CapsuleRegistry newImpl = new CapsuleRegistry();
        vm.prank(deployer);
        vm.expectRevert();
        registry.upgradeToAndCall(address(newImpl), "");

        AppTokenFactory newFactoryImpl = new AppTokenFactory();
        vm.prank(deployer);
        vm.expectRevert();
        factory.upgradeToAndCall(address(newFactoryImpl), "");

        FeeRouter newRouterImpl = new FeeRouter();
        vm.prank(deployer);
        vm.expectRevert();
        router.upgradeToAndCall(address(newRouterImpl), "");
    }

    function test_finalUpgraderCanUpgradeAfterFinalize() public {
        _grantFinalRoles();
        _revokeFromDeployer();

        CapsuleRegistry newImpl = new CapsuleRegistry();
        vm.prank(upgrader);
        registry.upgradeToAndCall(address(newImpl), "");

        AppTokenFactory newFactoryImpl = new AppTokenFactory();
        vm.prank(upgrader);
        factory.upgradeToAndCall(address(newFactoryImpl), "");

        FeeRouter newRouterImpl = new FeeRouter();
        vm.prank(upgrader);
        router.upgradeToAndCall(address(newRouterImpl), "");
    }
}
