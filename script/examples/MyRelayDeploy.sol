// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
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
import {MyValSetDriver} from "../../examples/MyValSetDriver.sol";
import {IValSetDriver} from "../../src/interfaces/modules/valset-driver/IValSetDriver.sol";
import {IEpochManager} from "../../src/interfaces/modules/valset-driver/IEpochManager.sol";
import {MySettlement} from "../../examples/MySettlement.sol";
import {ISettlement} from "../../src/interfaces/modules/settlement/ISettlement.sol";
import {KeyTags} from "../../src/libraries/utils/KeyTags.sol";
import {KeyBlsBn254, BN254} from "../../src/libraries/keys/KeyBlsBn254.sol";
import {KeyBlsBls12381} from "../../src/libraries/keys/KeyBlsBls12381.sol";
import {BLS12381} from "../../src/libraries/utils/BLS12381.sol";
import {KEY_TYPE_BLS_BN254, KEY_TYPE_BLS_BLS12381} from "../../src/interfaces/modules/key-registry/IKeyRegistry.sol";
import {BN254G2} from "../../test/helpers/BN254G2.sol";

// ./script/relay-deploy.sh ./script/examples/MyRelayDeploy.sol ./script/examples/my-relay-deploy.toml --broadcast

contract MyRelayDeploy is RelayDeploy {
    // address public constant OWNER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    // address public constant NETWORK_ADDRESS = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    using Math for uint256;
    // Key registry parameters
    string public constant KEY_REGISTRY_NAME = "MyKeyRegistry";
    string public constant KEY_REGISTRY_VERSION = "1";
    bytes11 public constant KEY_REGISTRY_SALT = "KeyRegistry";

    // Voting power parameters
    string public constant VOTING_POWER_PROVIDER_NAME = "MyVotingPowerProvider";
    string public constant VOTING_POWER_PROVIDER_VERSION = "1";
    bool public constant REQUIRE_SLASHER = false;
    uint48 public constant MIN_VAULT_EPOCH_DURATION = 60;
    uint256 public constant DEPLOYMENT_BUFFER = 600;
    address public constant TOKEN_ADDRESS = address(0);
    bytes11 public constant VOTING_POWER_PROVIDER_SALT = "VPProvider";

    // Settlement parameters
    string public constant SETTLEMENT_NAME = "MySettlement";
    string public constant SETTLEMENT_VERSION = "1";
    address public constant SIG_VERIFIER_ADDRESS = address(0);
    bytes11 public constant SETTLEMENT_SALT = "Settlement";

    // ValSet driver parameters
    string public constant VALSET_DRIVER_NAME = "MyValSetDriver";
    string public constant VALSET_DRIVER_VERSION = "1";
    uint48 public constant EPOCH_DURATION = 86_400;
    uint48 public constant COMMITTER_SLOT_DURATION = 21_600;
    uint208 public constant NUM_AGGREGATORS = 1;
    uint208 public constant NUM_COMMITTERS = 1;
    uint256 public constant MAX_VOTING_POWER = 1_000_000 * 10 ** 18;
    uint256 public constant MIN_INCLUSION_VOTING_POWER = 1000 * 10 ** 18;
    uint208 public constant MAX_VALIDATORS_COUNT = 1000;
    // uint8 public constant REQUIRED_HEADER_KEY_TAG = 15;
    uint32 public constant VERIFICATION_TYPE = 1;
    // uint248 public constant QUORUM_THRESHOLD = 6667;
    bytes11 public constant VALSET_DRIVER_SALT = "VSDriver";

    constructor() RelayDeploy("./script/examples/my-relay-deploy.toml") {}

    function _keyRegistryParams() internal override returns (address implementation, bytes memory initData) {
        vm.broadcast();
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
        vm.startBroadcast();
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
                    token: TOKEN_ADDRESS
                }),
                IOzOwnable.OzOwnableInitParams({owner: network})
            )
        );
    }

    function _settlementParams() internal override returns (address implementation, bytes memory initData) {
        vm.broadcast();
        implementation = address(new MySettlement());

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
                    sigVerifier: address(new SigVerifierBlsBn254Simple())
                }),
                deployer.addr
            )
        );
    }

    function _valSetDriverParams() internal override returns (address implementation, bytes memory initData) {
        vm.broadcast();
        implementation = address(new MyValSetDriver());

        uint8[] memory requiredKeyTags = new uint8[](1);
        requiredKeyTags[0] = REQUIRED_HEADER_KEY_TAG;

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
                        epochDurationTimestamp: uint48(vm.getBlockTimestamp() + DEPLOYMENT_BUFFER)
                    }),
                    numAggregators: NUM_AGGREGATORS,
                    numCommitters: NUM_COMMITTERS,
                    committerSlotDuration: EPOCH_DURATION,
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

    function runDeployKeyRegistry() public override {
        deployKeyRegistry({proxyOwner: network, isDeployerGuarded: true, salt: KEY_REGISTRY_SALT});
    }

    function runDeployVotingPowerProvider() public override {
        deployVotingPowerProvider({proxyOwner: network, isDeployerGuarded: true, salt: VOTING_POWER_PROVIDER_SALT});
    }

    function runDeploySettlement() public override {
        deploySettlement({proxyOwner: network, isDeployerGuarded: true, salt: SETTLEMENT_SALT});
    }

    function runDeployValSetDriver() public override {
        deployValSetDriver({proxyOwner: network, isDeployerGuarded: true, salt: VALSET_DRIVER_SALT});
    }

    function runPopulateDeployment() public override {
        populateDeployment();
    }
}
