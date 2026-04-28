// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {MyRelayDeploy} from "./MyRelayDeploy.sol";
import {console2} from "forge-std/Script.sol";
import {IValSetDriver} from "../../src/interfaces/modules/valset-driver/IValSetDriver.sol";
import {IEpochManager} from "../../src/interfaces/modules/valset-driver/IEpochManager.sol";
import {ISettlement} from "../../src/interfaces/modules/settlement/ISettlement.sol";
import {MyVotingPowerProvider} from "../../examples/MyVotingPowerProvider.sol";
import {Token} from "@symbioticfi/core/test/mocks/Token.sol";
import {Vm} from "forge-std/Vm.sol";
import "@symbioticfi/core/test/integration/SymbioticCoreImports.sol";

contract MyRelayDeployWithPopulate is MyRelayDeploy {
    using SymbioticSubnetwork for address;

    constructor() MyRelayDeploy() {}

    function runDeploymentWithPopulate() public loadConfig {
        console2.log("=== Starting Full Deployment & Population ===");

        _initCore();

        address token = _deployToken();

        address vault = _deployVault(token);

        _setupNetwork(vault);

        runDeployKeyRegistry();

        console2.log("KeyRegistry deployed");

        _setupOperators(vault);

        _addStake(vault, token);

        _setupVotingPowerProvider(vault, token);

        runDeploySettlement();

        runDeployValSetDriver();

        console2.log("=== Deployment Complete ===");
    }

    function _initCore() internal loadConfig {
        symbioticCore = _initCore_SymbioticCore(false);
        config.set("vault_factory", address(symbioticCore.vaultFactory));
        config.set("delegator_factory", address(symbioticCore.delegatorFactory));
        config.set("slasher_factory", address(symbioticCore.slasherFactory));
        config.set("network_registry", address(symbioticCore.networkRegistry));
        config.set("operator_registry", address(symbioticCore.operatorRegistry));
        config.set("operator_metadata_service", address(symbioticCore.operatorMetadataService));
        config.set("network_metadata_service", address(symbioticCore.networkMetadataService));
        config.set("network_middleware_service", address(symbioticCore.networkMiddlewareService));
        config.set("operator_vault_opt_in_service", address(symbioticCore.operatorVaultOptInService));
        config.set("operator_network_opt_in_service", address(symbioticCore.operatorNetworkOptInService));
        config.set("vault_configurator", address(symbioticCore.vaultConfigurator));
        console2.log("Core deployed");
    }

    function _deployToken() internal returns (address) {
        console2.log("Deploying token...");

        vm.startBroadcast(deployer.privateKey);
        Token token = new Token("Test Token");
        vm.stopBroadcast();

        console2.log("Token deployed:", address(token));
        return address(token);
    }

    function _deployVault(address token) internal returns (address) {
        // Deploy vault
        address vault = _getVault_SymbioticCore(
            VaultParams({
                owner: deployer.addr,
                collateral: token,
                burner: 0x000000000000000000000000000000000000dEaD,
                epochDuration: uint48(EPOCH_DURATION),
                whitelistedDepositors: new address[](0),
                depositLimit: 0,
                delegatorIndex: 0,
                hook: address(0),
                network: address(0),
                withSlasher: false,
                slasherIndex: 0,
                vetoDuration: uint48(2 hours)
            })
        );
        console2.log("Vault deployed:", vault);
        return vault;
    }

    function _setupNetwork(address vault) internal {
        if (!symbioticCore.networkRegistry.isEntity(network)) {
            _networkRegister_SymbioticCore(network);
            console2.log("Network registered in symbiotic core", network);
        }

        _setMaxNetworkLimit_SymbioticCore(network, vault, SUBNETWORK_ID, type(uint256).max);
        _setNetworkLimit_SymbioticCore(deployer.addr, vault, network.subnetwork(SUBNETWORK_ID), type(uint256).max);
        console2.log("Network limits set", network);
    }

    function _setupOperators(address vault) internal {
        address keyRegistry = config.get("key_registry").toAddress();
        for (uint256 i = 0; i < NUM_OPERATORS; i++) {
            Vm.Wallet memory operator = getOperator(i);

            // Fund operator with ETH
            vm.startBroadcast(deployer.privateKey);
            (bool success, ) = operator.addr.call{value: 1 ether}("");
            require(success, "ETH transfer failed");
            vm.stopBroadcast();

            // Register in Symbiotic Core
            _operatorRegister_SymbioticCore(operator.addr);
            _operatorOptInWeak_SymbioticCore(operator.addr, network);
            _operatorOptInWeak_SymbioticCore(operator.addr, vault);

            // Set operator network shares
            _setOperatorNetworkShares_SymbioticCore(
                deployer.addr,
                vault,
                network.subnetwork(SUBNETWORK_ID),
                operator.addr,
                1e18
            );

            // Register keys
            _registerBlsBn254Key(operator, keyRegistry);
            _registerBls12381Key(operator, keyRegistry);

            console2.log("Operator", i, "registered:", operator.addr);
        }
    }

    function _addStake(address vault, address token) internal {
        Vm.Wallet memory staker = getStaker(0);

        // Fund the staker
        vm.startBroadcast(deployer.privateKey);
        (bool success, ) = staker.addr.call{value: 0.5 ether}("");
        require(success, "ETH transfer to staker failed");
        vm.stopBroadcast();
        console2.log("Funded staker with 0.5 ETH:", staker.addr);

        _deal_Symbiotic(token, staker.addr, _normalizeForToken_Symbiotic((0.03 * 1e18), token));
        uint256 amount = (0.000_01 * 1e18) * NUM_OPERATORS * 2;
        _stakerDeposit_SymbioticCore(staker.addr, vault, _normalizeForToken_Symbiotic(amount, token));

        console2.log("Staker ", staker.addr, " deposited to vault ", vault);
    }

    function _setupVotingPowerProvider(address vault, address token) internal {
        runDeployVotingPowerProvider();
        console2.log("VotingPowerProvider deployed");

        address votingPowerProvider = config.get("voting_power_provider").toAddress();
        MyVotingPowerProvider myVotingPowerProvider = MyVotingPowerProvider(votingPowerProvider);

        vm.startBroadcast(deployer.privateKey);
        myVotingPowerProvider.registerToken(token);
        vm.stopBroadcast();
        console2.log("Token registered in voting power provider", token);

        _networkSetMiddleware_SymbioticCore(network, votingPowerProvider);
        console2.log("Network middleware set in voting power provider", network);

        vm.startBroadcast(deployer.privateKey);
        myVotingPowerProvider.registerSharedVault(vault);
        vm.stopBroadcast();

        for (uint256 i = 0; i < NUM_OPERATORS; i++) {
            Vm.Wallet memory operator = getOperator(i);
            vm.startBroadcast(operator.privateKey);
            myVotingPowerProvider.registerOperator();
            vm.stopBroadcast();
            console2.log("Operator ", operator.addr, " registered in voting power provider");
        }
    }

    function runSetGenesis() public loadConfig {
        IValSetDriver valSetDriver = IValSetDriver(config.get("val_set_driver").toAddress());
        ISettlement settlement = ISettlement(config.get("settlement").toAddress());
        ISettlement.ValSetHeader memory valSetHeader = ISettlement.ValSetHeader({
            version: settlement.VALIDATOR_SET_VERSION(),
            requiredKeyTag: valSetDriver.getRequiredHeaderKeyTag(),
            epoch: valSetDriver.getCurrentEpoch(),
            captureTimestamp: valSetDriver.getCurrentEpochStart(),
            quorumThreshold: 213333333333334,
            totalVotingPower: 320000000000000,
            validatorsSszMRoot: bytes32(uint256(0x8980fbb6d05d0fe9432549fa850608c839d410c278233b0f247d9a192d1a7ae1))
        });

        // Commit to settlement
        ISettlement.ExtraData[] memory extraData = new ISettlement.ExtraData[](0);
        vm.startBroadcast(deployer.privateKey);
        settlement.setGenesis(valSetHeader, extraData);
        vm.stopBroadcast();

        console2.log("captureTimestamp: ", valSetHeader.captureTimestamp);
        console2.log("epoch: ", valSetHeader.epoch);
        console2.log("quorum: ", valSetHeader.quorumThreshold);
        console2.log("keyTag: ", valSetHeader.requiredKeyTag);
        console2.log("votingPower: ", valSetHeader.totalVotingPower);
        // console2.log("sszRoot: ", valSetHeader.validatorsSszMRoot);
        console2.log("version: ", valSetHeader.version);
        console2.log("Genesis set");
    }
}
