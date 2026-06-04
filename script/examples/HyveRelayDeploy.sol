// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {console2} from "forge-std/Script.sol";
import {Token} from "@symbioticfi/core/test/mocks/Token.sol";
import {SigVerifierBlsBn254Simple} from "../../src/modules/settlement/sig-verifiers/SigVerifierBlsBn254Simple.sol";
import {SymbioticCoreConstants} from "@symbioticfi/core/test/integration/SymbioticCoreConstants.sol";
import {RelayDeploy} from "../RelayDeploy.sol";
import {IVotingPowerProvider} from "../../src/interfaces/modules/voting-power/IVotingPowerProvider.sol";
import {INetworkManager} from "../../src/interfaces/modules/base/INetworkManager.sol";
import {IOzEIP712} from "../../src/interfaces/modules/base/IOzEIP712.sol";
import {IOzOwnable} from "../../src/interfaces/modules/common/permissions/IOzOwnable.sol";
import {MyVotingPowerProvider} from "../../examples/MyVotingPowerProvider.sol";
import {MyKeyRegistry} from "../../examples/MyKeyRegistry.sol";
import {IKeyRegistry} from "../../src/interfaces/modules/key-registry/IKeyRegistry.sol";
import {KeyRegistry} from "../../src/modules/key-registry/KeyRegistry.sol";
import {MyValSetDriver} from "../../examples/MyValSetDriver.sol";
import {IValSetDriver} from "../../src/interfaces/modules/valset-driver/IValSetDriver.sol";
import {IEpochManager} from "../../src/interfaces/modules/valset-driver/IEpochManager.sol";
import {MySettlement} from "../../examples/MySettlement.sol";
import {ISettlement} from "../../src/interfaces/modules/settlement/ISettlement.sol";
import "@symbioticfi/core/test/integration/SymbioticCoreImports.sol";

// ./script/relay-deploy-populate.sh ./script/examples/HyveRelayDeploy.sol ./script/examples/my-relay-deploy.toml --broadcast

contract HyveRelayDeploy is RelayDeploy {
    using Math for uint256;
    using SymbioticSubnetwork for address;

    // Key registry
    string public constant KEY_REGISTRY_NAME = "MyKeyRegistry";
    string public constant KEY_REGISTRY_VERSION = "1";
    bytes11 public constant KEY_REGISTRY_SALT = "KeyRegistry";

    // Voting power provider
    string public constant VOTING_POWER_PROVIDER_NAME = "MyVotingPowerProvider";
    string public constant VOTING_POWER_PROVIDER_VERSION = "1";
    bool public constant REQUIRE_SLASHER = false;
    bytes11 public constant VOTING_POWER_PROVIDER_SALT = "VPProvider";

    // Settlement
    string public constant SETTLEMENT_NAME = "MySettlement";
    string public constant SETTLEMENT_VERSION = "1";
    bytes11 public constant SETTLEMENT_SALT = "Settlement";

    // ValSet driver
    string public constant VALSET_DRIVER_NAME = "MyValSetDriver";
    string public constant VALSET_DRIVER_VERSION = "1";
    uint48 public constant EPOCH_DURATION = 300;
    // Supersum uses a separate shorter value (default 10s) → 6 committer slots per epoch.
    uint48 public constant COMMITTER_SLOT_DURATION = 30;
    uint208 public constant NUM_AGGREGATORS = 4;
    uint208 public constant NUM_COMMITTERS = 4;
    uint208 public constant MAX_VALIDATORS_COUNT = 1000;
    uint32 public constant VERIFICATION_TYPE = 1;
    bytes11 public constant VALSET_DRIVER_SALT = "VSDriver";

    constructor() RelayDeploy("./script/examples/my-relay-deploy.toml") {}

    // ─── Abstract param implementations ──────────────────────────────────────────

    function _keyRegistryParams() internal override returns (address implementation, bytes memory initData) {
        vm.broadcast(deployer.privateKey);
        implementation = address(new MyKeyRegistry());
        initData = abi.encodeCall(
            MyKeyRegistry.initialize,
            (
                IKeyRegistry.KeyRegistryInitParams({
                    ozEip712InitParams: IOzEIP712.OzEIP712InitParams({
                        name: KEY_REGISTRY_NAME,
                        version: KEY_REGISTRY_VERSION
                    })
                })
            )
        );
    }

    function _votingPowerProviderParams() internal override returns (address implementation, bytes memory initData) {
        vm.startBroadcast(deployer.privateKey);
        implementation = address(
            new MyVotingPowerProvider(address(getCore().operatorRegistry), address(getCore().vaultFactory))
        );
        vm.stopBroadcast();
        initData = abi.encodeCall(
            MyVotingPowerProvider.initialize,
            (
                IVotingPowerProvider.VotingPowerProviderInitParams({
                    networkManagerInitParams: INetworkManager.NetworkManagerInitParams({
                        network: network,
                        subnetworkId: SUBNETWORK_ID
                    }),
                    ozEip712InitParams: IOzEIP712.OzEIP712InitParams({
                        name: VOTING_POWER_PROVIDER_NAME,
                        version: VOTING_POWER_PROVIDER_VERSION
                    }),
                    requireSlasher: REQUIRE_SLASHER,
                    minVaultEpochDuration: EPOCH_DURATION,
                    token: address(0)
                }),
                IOzOwnable.OzOwnableInitParams({owner: network})
            )
        );
    }

    function _settlementParams() internal override returns (address implementation, bytes memory initData) {
        vm.startBroadcast(deployer.privateKey);
        implementation = address(new MySettlement());
        address sigVerifier = address(new SigVerifierBlsBn254Simple());
        vm.stopBroadcast();
        initData = abi.encodeCall(
            MySettlement.initialize,
            (
                ISettlement.SettlementInitParams({
                    networkManagerInitParams: INetworkManager.NetworkManagerInitParams({
                        network: network,
                        subnetworkId: SUBNETWORK_ID
                    }),
                    ozEip712InitParams: IOzEIP712.OzEIP712InitParams({
                        name: SETTLEMENT_NAME,
                        version: SETTLEMENT_VERSION
                    }),
                    sigVerifier: sigVerifier
                }),
                deployer.addr
            )
        );
    }

    function _valSetDriverParams() internal override returns (address implementation, bytes memory initData) {
        vm.broadcast(deployer.privateKey);
        implementation = address(new MyValSetDriver());

        // Both BLS-BN254 (tag 15, on-chain settlement) and BLS12-381 (tag 32, off-chain network)
        // are required for an operator to be included in the validator set.
        uint8[] memory requiredKeyTags = new uint8[](2);
        requiredKeyTags[0] = REQUIRED_HEADER_KEY_TAG;
        requiredKeyTags[1] = 32;

        IValSetDriver.QuorumThreshold[] memory quorumThresholds = new IValSetDriver.QuorumThreshold[](1);
        quorumThresholds[0] = IValSetDriver.QuorumThreshold({
            keyTag: REQUIRED_HEADER_KEY_TAG,
            quorumThreshold: uint248(uint256(2).mulDiv(1e18, 3, Math.Rounding.Ceil))
        });

        initData = abi.encodeCall(
            MyValSetDriver.initialize,
            (
                IValSetDriver.ValSetDriverInitParams({
                    networkManagerInitParams: INetworkManager.NetworkManagerInitParams({
                        network: network,
                        subnetworkId: SUBNETWORK_ID
                    }),
                    epochManagerInitParams: IEpochManager.EpochManagerInitParams({
                        epochDuration: EPOCH_DURATION,
                        // epochDurationTimestamp: 0 anchors epochs to Unix time 0, so the current epoch
                        // is always immediately active at deploy time (no waiting for a future start).
                        // Using a future timestamp (vm.getBlockTimestamp() + buffer) means no epoch is
                        // active until that timestamp passes, which can delay genesis and sidecar startup.
                        epochDurationTimestamp: 0
                    }),
                    numAggregators: NUM_AGGREGATORS,
                    numCommitters: NUM_COMMITTERS,
                    committerSlotDuration: COMMITTER_SLOT_DURATION,
                    votingPowerProviders: getVotingPowerProviders(),
                    keysProvider: getKeyRegistry(),
                    settlements: getSettlements(),
                    maxVotingPower: 1e36,
                    minInclusionVotingPower: 0,
                    maxValidatorsCount: MAX_VALIDATORS_COUNT,
                    requiredKeyTags: requiredKeyTags,
                    quorumThresholds: quorumThresholds,
                    requiredHeaderKeyTag: REQUIRED_HEADER_KEY_TAG,
                    verificationType: VERIFICATION_TYPE
                }),
                deployer.addr
            )
        );
    }

    // ─── Run entrypoints ──────────────────────────────────────────────────────────

    // Deploys the key registry and registers BLS-BN254 and BLS12-381 keys for all operators.
    // _registerBlsBn254Key and _registerBls12381Key are inherited from RelayDeploy and each
    // broadcast as the operator so msg.sender == operator.addr satisfies the ownership check.
    function runDeployKeyRegistry() public override {
        deployKeyRegistry({proxyOwner: network, isDeployerGuarded: true, salt: KEY_REGISTRY_SALT});
        KeyRegistry keyRegistry = KeyRegistry(getKeyRegistry().addr);
        for (uint256 i = 0; i < NUM_OPERATORS; i++) {
            Vm.Wallet memory operator = getOperator(i);
            _registerBlsBn254Key(keyRegistry, operator, operator.privateKey, REQUIRED_HEADER_KEY_TAG);
            _registerBls12381Key(keyRegistry, operator, operator.privateKey + 10_000, 0);
            console2.log("Keys registered for operator", i, ":", operator.addr);
        }
    }

    // Deploys VotingPowerProvider and completes all VPP-level setup:
    // registers token, sets network middleware, registers the shared vault, registers operators.
    // Requires: "token" and "vault" saved to config before calling.
    function runDeployVotingPowerProvider() public override {
        deployVotingPowerProvider({proxyOwner: network, isDeployerGuarded: true, salt: VOTING_POWER_PROVIDER_SALT});

        address votingPowerProvider = config.get("voting_power_provider").toAddress();
        address token = config.get("token").toAddress();
        address vault = config.get("vault").toAddress();
        MyVotingPowerProvider myVpp = MyVotingPowerProvider(votingPowerProvider);

        vm.startBroadcast(deployer.privateKey);
        myVpp.registerToken(token);
        vm.stopBroadcast();
        console2.log("Token registered in VPP:", token);

        _networkSetMiddleware_SymbioticCore(network, votingPowerProvider);
        console2.log("Network middleware set:", network);

        vm.startBroadcast(deployer.privateKey);
        myVpp.registerSharedVault(vault);
        vm.stopBroadcast();
        console2.log("Shared vault registered in VPP:", vault);

        for (uint256 i = 0; i < NUM_OPERATORS; i++) {
            Vm.Wallet memory operator = getOperator(i);
            vm.startBroadcast(operator.privateKey);
            myVpp.registerOperator();
            vm.stopBroadcast();
            console2.log("Operator registered in VPP:", operator.addr);
        }
    }

    function runDeploySettlement() public override {
        deploySettlement({proxyOwner: network, isDeployerGuarded: true, salt: SETTLEMENT_SALT});
    }

    function runDeployValSetDriver() public override {
        deployValSetDriver({proxyOwner: network, isDeployerGuarded: true, salt: VALSET_DRIVER_SALT});
    }

    // ─── Full deploy + populate entrypoint ───────────────────────────────────────

    function runDeploymentWithPopulate() public loadConfig {
        console2.log("=== Starting Full Deployment & Population ===");

        _initCore();

        address token = _deployToken();
        address vault = _deployVault(token);
        config.set("token", token);
        config.set("vault", vault);

        _setupNetwork(vault);
        _fundOperators();
        _registerSymbioticOperators(vault);

        runDeployKeyRegistry();

        _addStake(vault, token);

        runDeployVotingPowerProvider();
        runDeploySettlement();
        runDeployValSetDriver();

        console2.log("=== Deployment Complete ===");
    }

    // ─── Infrastructure helpers ───────────────────────────────────────────────────

    function _initCore() internal {
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
        vm.startBroadcast(deployer.privateKey);
        Token token = new Token("Test Token");
        vm.stopBroadcast();
        console2.log("Token deployed:", address(token));
        return address(token);
    }

    function _deployVault(address token) internal returns (address) {
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
            console2.log("Network registered:", network);
        }
        _setMaxNetworkLimit_SymbioticCore(network, vault, SUBNETWORK_ID, type(uint256).max);
        _setNetworkLimit_SymbioticCore(deployer.addr, vault, network.subnetwork(SUBNETWORK_ID), type(uint256).max);
        console2.log("Network limits set");
    }

    function _fundOperators() internal {
        for (uint256 i = 0; i < NUM_OPERATORS; i++) {
            Vm.Wallet memory operator = getOperator(i);
            vm.startBroadcast(deployer.privateKey);
            (bool success, ) = operator.addr.call{value: 1 ether}("");
            require(success, "ETH transfer failed");
            vm.stopBroadcast();
        }
        console2.log("Operators funded");
    }

    function _registerSymbioticOperators(address vault) internal {
        for (uint256 i = 0; i < NUM_OPERATORS; i++) {
            Vm.Wallet memory operator = getOperator(i);
            _operatorRegister_SymbioticCore(operator.addr);
            _operatorOptInWeak_SymbioticCore(operator.addr, network);
            _operatorOptInWeak_SymbioticCore(operator.addr, vault);
            _setOperatorNetworkShares_SymbioticCore(
                deployer.addr,
                vault,
                network.subnetwork(SUBNETWORK_ID),
                operator.addr,
                1e18
            );
            console2.log("Operator registered in Symbiotic:", operator.addr);
        }
    }

    function _addStake(address vault, address token) internal {
        Vm.Wallet memory staker = getStaker(0);

        // Keep deployer broadcast active so _deal_Symbiotic transfers from deployer (token holder)
        vm.startBroadcast(deployer.privateKey);
        (bool success, ) = staker.addr.call{value: 0.5 ether}("");
        require(success, "ETH transfer to staker failed");
        _deal_Symbiotic(token, staker.addr, _normalizeForToken_Symbiotic(0.03 * 1e18, token));
        vm.stopBroadcast();
        uint256 amount = (0.000_01 * 1e18) * NUM_OPERATORS * 2;
        _stakerDeposit_SymbioticCore(staker.addr, vault, _normalizeForToken_Symbiotic(amount, token));
        console2.log("Staker deposited to vault:", vault);
    }
}
