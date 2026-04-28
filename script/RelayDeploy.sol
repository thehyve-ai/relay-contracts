// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {Script, console2} from "forge-std/Script.sol";
import {Config} from "forge-std/Config.sol";
import {Variable} from "forge-std/LibVariable.sol";

import {CreateXWrapper} from "@symbioticfi/core/script/utils/CreateXWrapper.sol";
import {Logs} from "@symbioticfi/core/script/utils/Logs.sol";
import {SymbioticCoreConstants} from "@symbioticfi/core/test/integration/SymbioticCoreConstants.sol";
import {SymbioticCoreInit} from "@symbioticfi/core/script/integration/SymbioticCoreInit.sol";
import {Token} from "@symbioticfi/core/test/mocks/Token.sol";
import "@symbioticfi/core/test/integration/SymbioticCoreImports.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IOpNetVaultAutoDeploy} from "../src/interfaces/modules/voting-power/extensions/IOpNetVaultAutoDeploy.sol";
import {VotingPowerProvider} from "../src/modules/voting-power/VotingPowerProvider.sol";
import {IValSetDriver} from "../src/interfaces/modules/valset-driver/IValSetDriver.sol";
import {ISettlement} from "../src/interfaces/modules/settlement/ISettlement.sol";

// Relay imports
import {MyKeyRegistry} from "../examples/MyKeyRegistry.sol";
import {MyVotingPowerProvider} from "../examples/MyVotingPowerProvider.sol";
import {IKeyRegistry} from "../src/interfaces/modules/key-registry/IKeyRegistry.sol";
import {IVotingPowerProvider} from "../src/interfaces/modules/voting-power/IVotingPowerProvider.sol";
import {KeyBlsBn254, BN254} from "../src/libraries/keys/KeyBlsBn254.sol";
import {KeyBlsBls12381} from "../src/libraries/keys/KeyBlsBls12381.sol";
import {BLS12381} from "../src/libraries/utils/BLS12381.sol";
import {KeyTags} from "../src/libraries/utils/KeyTags.sol";
import {BN254G2} from "../test/helpers/BN254G2.sol";
import {KEY_TYPE_BLS_BN254, KEY_TYPE_BLS_BLS12381} from "../src/interfaces/modules/key-registry/IKeyRegistry.sol";

/**
 * @title RelayDeploy
 * @notice Abstract base contract for deploying relay contracts using CREATE3
 * @dev This contract provides a standardized deployment pattern for relay contracts
 *
 * The contract supports both guarded and non-guarded salt deployments.
 * See https://github.com/pcaversaccio/createx?tab=readme-ov-file#security-considerations
 *
 * This script requires a deployed CreateX instance.
 */
abstract contract RelayDeploy is SymbioticCoreInit, Config, CreateXWrapper {
    using KeyTags for uint8;
    using KeyBlsBn254 for BN254.G1Point;
    using BN254 for BN254.G1Point;
    using KeyBlsBn254 for KeyBlsBn254.KEY_BLS_BN254;
    using KeyBlsBls12381 for KeyBlsBls12381.KEY_BLS_BLS12381;
    using SymbioticSubnetwork for address;

    uint256 public constant NUM_OPERATORS = 16;
    uint256 public constant NUM_VAULTS = 1;
    uint256 public constant NUM_STAKERS = 1;
    uint96 public constant SUBNETWORK_ID = 0;
    uint256 public constant STAKER_PRIVATE_KEY_OFFSET = 2e18;
    uint8 public constant REQUIRED_HEADER_KEY_TAG = 15;
    uint248 public constant QUORUM_THRESHOLD = 6667;

    bytes32 internal constant KEY_OWNERSHIP_TYPEHASH = keccak256("KeyOwnership(address operator,bytes key)");
    address internal constant BLS12_G2MSM = 0x000000000000000000000000000000000000000E;

    string public CONFIG_FILE;

    Vm.Wallet public deployer;
    address public network;

    constructor(string memory configFile) {
        CONFIG_FILE = configFile;
        deployer = vm.createWallet(vm.envUint("PRIVATE_KEY"));
        network = deployer.addr;
        // network = 0x895aDC2EfB58534dECeE4B2d5603855CF201Dd83; // Use same for simplicity
    }

    modifier loadConfig() {
        _loadConfig(CONFIG_FILE, true);
        _;
    }

    modifier withBroadcast() {
        (Vm.CallerMode callerMode, , address deployer) = vm.readCallers();
        _stopBroadcastWhenCallerModeIsSingle(callerMode);
        _startBroadcastWhenCallerModeIsNotRecurrent(callerMode, deployer);
        _;
        _stopBroadcastWhenCallerModeIsNotRecurrent(callerMode);
    }

    modifier withoutBroadcast() {
        (Vm.CallerMode callerMode, , address deployer) = vm.readCallers();
        _stopBroadcastWhenCallerModeIsSingleOrRecurrent(callerMode);
        _;
        _startBroadcastWhenCallerModeIsRecurrent(callerMode, deployer);
    }

    /**
     * @notice Returns deployment parameters for the KeyRegistry contract
     * @dev Must be implemented by concrete deployment contracts
     * @return implementation The implementation contract address
     * @return initData The initialization data for the proxy
     */
    function _keyRegistryParams() internal virtual returns (address implementation, bytes memory initData);

    /**
     * @notice Returns deployment parameters for the VotingPowerProvider contract
     * @dev Must be implemented by concrete deployment contracts
     * @return implementation The implementation contract address
     * @return initData The initialization data for the proxy
     */
    function _votingPowerProviderParams() internal virtual returns (address implementation, bytes memory initData);

    /**
     * @notice Returns deployment parameters for the Settlement contract
     * @dev Must be implemented by concrete deployment contracts
     * @return implementation The implementation contract address
     * @return initData The initialization data for the proxy
     */
    function _settlementParams() internal virtual returns (address implementation, bytes memory initData);

    /**
     * @notice Returns deployment parameters for the ValSetDriver contract
     * @dev Must be implemented by concrete deployment contracts
     * @return implementation The implementation contract address
     * @return initData The initialization data for the proxy
     */
    function _valSetDriverParams() internal virtual returns (address implementation, bytes memory initData);

    function runDeployKeyRegistry() public virtual;

    function runDeployVotingPowerProvider() public virtual;

    function runDeploySettlement() public virtual;

    function runDeployValSetDriver() public virtual;

    function getCore() public withoutBroadcast loadConfig returns (SymbioticCoreConstants.Core memory) {
        if (!SymbioticCoreConstants.coreSupported()) {
            if (config.get("vault_factory").data.length == 0) {
                SymbioticCoreConstants.Core memory core = _initCore_SymbioticCore(false);
                config.set("vault_factory", address(core.vaultFactory));
                config.set("delegator_factory", address(core.delegatorFactory));
                config.set("slasher_factory", address(core.slasherFactory));
                config.set("network_registry", address(core.networkRegistry));
                config.set("operator_registry", address(core.operatorRegistry));
                config.set("operator_metadata_service", address(core.operatorMetadataService));
                config.set("network_metadata_service", address(core.networkMetadataService));
                config.set("network_middleware_service", address(core.networkMiddlewareService));
                config.set("operator_vault_opt_in_service", address(core.operatorVaultOptInService));
                config.set("operator_network_opt_in_service", address(core.operatorNetworkOptInService));
                config.set("vault_configurator", address(core.vaultConfigurator));
            }
            return
                SymbioticCoreConstants.Core({
                    vaultFactory: ISymbioticVaultFactory(config.get("vault_factory").toAddress()),
                    delegatorFactory: ISymbioticDelegatorFactory(config.get("delegator_factory").toAddress()),
                    slasherFactory: ISymbioticSlasherFactory(config.get("slasher_factory").toAddress()),
                    networkRegistry: ISymbioticNetworkRegistry(config.get("network_registry").toAddress()),
                    networkMetadataService: ISymbioticMetadataService(
                        config.get("network_metadata_service").toAddress()
                    ),
                    networkMiddlewareService: ISymbioticNetworkMiddlewareService(
                        config.get("network_middleware_service").toAddress()
                    ),
                    operatorRegistry: ISymbioticOperatorRegistry(config.get("operator_registry").toAddress()),
                    operatorMetadataService: ISymbioticMetadataService(
                        config.get("operator_metadata_service").toAddress()
                    ),
                    operatorVaultOptInService: ISymbioticOptInService(
                        config.get("operator_vault_opt_in_service").toAddress()
                    ),
                    operatorNetworkOptInService: ISymbioticOptInService(
                        config.get("operator_network_opt_in_service").toAddress()
                    ),
                    vaultConfigurator: ISymbioticVaultConfigurator(config.get("vault_configurator").toAddress())
                });
        }
        return SymbioticCoreConstants.core();
    }

    function getKeyRegistry()
        public
        virtual
        withoutBroadcast
        loadConfig
        returns (IValSetDriver.CrossChainAddress memory)
    {
        uint256[] memory configChainIds = config.getChainIds();
        for (uint256 i; i < configChainIds.length; ++i) {
            Variable memory keyRegistry = config.get(configChainIds[i], "key_registry");
            if (keyRegistry.data.length > 0) {
                return
                    IValSetDriver.CrossChainAddress({
                        chainId: uint64(configChainIds[i]),
                        addr: keyRegistry.toAddress()
                    });
            }
        }
    }

    function getVotingPowerProvider() public virtual withoutBroadcast loadConfig returns (address) {
        return config.get("voting_power_provider").toAddress();
    }

    function getVotingPowerProviders()
        public
        virtual
        withoutBroadcast
        loadConfig
        returns (IValSetDriver.CrossChainAddress[] memory votingPowerProviders)
    {
        uint256[] memory configChainIds = config.getChainIds();
        votingPowerProviders = new IValSetDriver.CrossChainAddress[](configChainIds.length);
        uint256 length;
        for (uint256 i; i < configChainIds.length; ++i) {
            Variable memory votingPowerProvider = config.get(configChainIds[i], "voting_power_provider");
            if (votingPowerProvider.data.length > 0) {
                votingPowerProviders[length] = IValSetDriver.CrossChainAddress({
                    chainId: uint64(configChainIds[i]),
                    addr: votingPowerProvider.toAddress()
                });
                ++length;
            }
        }
        assembly ("memory-safe") {
            mstore(votingPowerProviders, length)
        }
    }

    function getSettlement() public virtual withoutBroadcast loadConfig returns (address) {
        return config.get("settlement").toAddress();
    }

    function getSettlements()
        public
        virtual
        withoutBroadcast
        loadConfig
        returns (IValSetDriver.CrossChainAddress[] memory settlements)
    {
        uint256[] memory configChainIds = config.getChainIds();
        settlements = new IValSetDriver.CrossChainAddress[](configChainIds.length);
        uint256 length;
        for (uint256 i; i < configChainIds.length; ++i) {
            Variable memory settlement = config.get(configChainIds[i], "settlement");
            if (settlement.data.length > 0) {
                settlements[length] = IValSetDriver.CrossChainAddress({
                    chainId: uint64(configChainIds[i]),
                    addr: settlement.toAddress()
                });
                ++length;
            }
        }
        assembly ("memory-safe") {
            mstore(settlements, length)
        }
    }

    function getValSetDriver()
        public
        virtual
        withoutBroadcast
        loadConfig
        returns (IValSetDriver.CrossChainAddress memory)
    {
        uint256[] memory configChainIds = config.getChainIds();
        for (uint256 i; i < configChainIds.length; ++i) {
            Variable memory valSetDriver = config.get(configChainIds[i], "val_set_driver");
            if (valSetDriver.data.length > 0) {
                return
                    IValSetDriver.CrossChainAddress({
                        chainId: uint64(configChainIds[i]),
                        addr: valSetDriver.toAddress()
                    });
            }
        }
    }

    /**
     * @notice Deploy the KeyRegistry contract using CREATE3
     * @dev Deploys a transparent upgradeable proxy for the KeyRegistry
     * @param proxyOwner The owner of the proxy contract
     * @param isDeployerGuarded Whether to deploy with guarded salt for enhanced security
     * @return The address of the deployed KeyRegistry contract
     */
    function deployKeyRegistry(
        address proxyOwner,
        bool isDeployerGuarded,
        bytes11 salt
    ) public virtual withoutBroadcast loadConfig returns (address) {
        (address implementation, bytes memory initData) = _keyRegistryParams();
        address newContract = _deployContract(salt, implementation, initData, proxyOwner, isDeployerGuarded);
        Logs.log(string.concat("KeyRegistry deployed at: ", vm.toString(newContract)));
        config.set("key_registry", newContract);
        return newContract;
    }

    /**
     * @notice Deploy the VotingPowerProvider contract using CREATE3
     * @dev Deploys a transparent upgradeable proxy for the VotingPowerProvider
     * @param proxyOwner The owner of the proxy contract
     * @param isDeployerGuarded Whether to deploy with guarded salt for enhanced security
     * @return The address of the deployed VotingPowerProvider contract
     */
    function deployVotingPowerProvider(
        address proxyOwner,
        bool isDeployerGuarded,
        bytes11 salt
    ) public virtual withoutBroadcast loadConfig returns (address) {
        (address implementation, bytes memory initData) = _votingPowerProviderParams();
        address newContract = _deployContract(salt, implementation, initData, proxyOwner, isDeployerGuarded);

        if (SymbioticCoreConstants.coreSupported()) {
            // Validate deployment
            SymbioticCoreConstants.Core memory core = SymbioticCoreConstants.core();
            require(
                VotingPowerProvider(newContract).OPERATOR_REGISTRY() == address(core.operatorRegistry),
                "VotingPowerProvider.OPERATOR_REGISTRY() has incorrect value"
            );
            require(
                VotingPowerProvider(newContract).VAULT_FACTORY() == address(core.vaultFactory),
                "VotingPowerProvider.VAULT_FACTORY() has incorrect value"
            );
            (bool success, bytes memory data) = newContract.call(
                abi.encodeWithSelector(IOpNetVaultAutoDeploy.VAULT_CONFIGURATOR.selector)
            );
            if (success) {
                require(
                    abi.decode(data, (address)) == address(core.vaultConfigurator),
                    "VotingPowerProvider.VAULT_CONFIGURATOR() has incorrect value"
                );
            }
        }
        Logs.log(string.concat("VotingPowerProvider deployed at: ", vm.toString(newContract)));
        config.set("voting_power_provider", newContract);
        return newContract;
    }

    /**
     * @notice Deploy the Settlement contract using CREATE3
     * @dev Deploys a transparent upgradeable proxy for the Settlement
     * @param proxyOwner The owner of the proxy contract
     * @param isDeployerGuarded Whether to deploy with guarded salt for enhanced security
     * @return The address of the deployed Settlement contract
     */
    function deploySettlement(
        address proxyOwner,
        bool isDeployerGuarded,
        bytes11 salt
    ) public virtual withoutBroadcast loadConfig returns (address) {
        (address implementation, bytes memory initData) = _settlementParams();
        address newContract = _deployContract(salt, implementation, initData, proxyOwner, isDeployerGuarded);
        Logs.log(string.concat("Settlement deployed at: ", vm.toString(newContract)));
        config.set("settlement", newContract);
        return newContract;
    }

    /**
     * @notice Deploy the ValSetDriver contract using CREATE3
     * @dev Deploys a transparent upgradeable proxy for the ValSetDriver
     * @param proxyOwner The owner of the proxy contract
     * @param isDeployerGuarded Whether to deploy with guarded salt for enhanced security
     * @return The address of the deployed ValSetDriver contract
     */
    function deployValSetDriver(
        address proxyOwner,
        bool isDeployerGuarded,
        bytes11 salt
    ) public virtual withoutBroadcast loadConfig returns (address) {
        (address implementation, bytes memory initData) = _valSetDriverParams();
        address newContract = _deployContract(salt, implementation, initData, proxyOwner, isDeployerGuarded);
        Logs.log(string.concat("ValSetDriver deployed at: ", vm.toString(newContract)));
        config.set("val_set_driver", newContract);
        return newContract;
    }

    /**
     * @notice Internal function to deploy a contract using CREATE3 with optional initialization
     * @dev Creates a transparent upgradeable proxy and optionally initializes it
     * @param salt The CREATE3 salt for deterministic deployment
     * @param implementation The implementation contract address
     * @param initData The initialization data for the proxy (empty bytes if no initialization)
     * @param owner The owner of the proxy contract
     * @param isDeployerGuarded Whether to use guarded salt deployment
     * @return The address of the deployed contract
     */
    function _deployContract(
        bytes11 salt,
        address implementation,
        bytes memory initData,
        address owner,
        bool isDeployerGuarded
    ) internal virtual withBroadcast returns (address) {
        bytes memory proxyInitCode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(implementation, owner, new bytes(0))
        );

        (, , address deployer) = vm.readCallers();

        return
            isDeployerGuarded
                ? deployCreate3AndInitWithGuardedSalt(deployer, salt, proxyInitCode, initData)
                : deployCreate3AndInit(bytes32(salt), proxyInitCode, initData);
    }

    function getOperator(uint256 index) public returns (Vm.Wallet memory operator) {
        // deterministic operator private key
        operator = vm.createWallet(1e18 + index);
        vm.rememberKey(operator.privateKey);
        return operator;
    }

    function getStaker(uint256 index) public returns (Vm.Wallet memory staker) {
        // deterministic staker private key
        staker = vm.createWallet(STAKER_PRIVATE_KEY_OFFSET + index);
        vm.rememberKey(staker.privateKey);
        return staker;
    }

    function _registerBlsBn254Key(Vm.Wallet memory operator, address keyRegistry) internal {
        // Generate key components (no prank needed - this is just math)
        BN254.G1Point memory keyG1 = BN254.generatorG1().scalar_mul(operator.privateKey);
        BN254.G2Point memory keyG2 = _getG2Key(operator.privateKey);
        bytes memory keyBytes = KeyBlsBn254.wrap(keyG1).toBytes();

        bytes32 structHash = keccak256(abi.encode(KEY_OWNERSHIP_TYPEHASH, operator.addr, keccak256(keyBytes)));
        bytes32 digest = MyKeyRegistry(keyRegistry).hashTypedDataV4(structHash);
        BN254.G1Point memory messageG1 = BN254.hashToG1(digest);
        BN254.G1Point memory signature = messageG1.scalar_mul(operator.privateKey);

        uint8 keyTag = KEY_TYPE_BLS_BN254.getKeyTag(15);

        // Broadcast with the OPERATOR's private key (not network's!)
        vm.startBroadcast(operator.privateKey);
        MyKeyRegistry(keyRegistry).setKey(keyTag, keyBytes, abi.encode(signature), abi.encode(keyG2));
        vm.stopBroadcast();
    }

    function _registerBls12381Key(Vm.Wallet memory operator, address keyRegistry) internal {
        // Generate key components
        BLS12381.G1Point memory generator = BLS12381.negate(BLS12381.negGeneratorG1());
        BLS12381.G1Point memory keyG1 = BLS12381.scalar_mul(generator, operator.privateKey);
        BLS12381.G2Point memory keyG2 = _g2Mul(BLS12381.generatorG2(), bytes32(operator.privateKey));
        bytes memory keyBytes = KeyBlsBls12381.wrap(keyG1).toBytes();

        bytes32 structHash = keccak256(abi.encode(KEY_OWNERSHIP_TYPEHASH, operator.addr, keccak256(keyBytes)));
        bytes32 digest = MyKeyRegistry(keyRegistry).hashTypedDataV4(structHash);
        BLS12381.G1Point memory messageG1 = BLS12381.hashToG1(abi.encodePacked(digest));
        BLS12381.G1Point memory signature = BLS12381.scalar_mul(messageG1, operator.privateKey);

        uint8 keyTag = KEY_TYPE_BLS_BLS12381.getKeyTag(0); // keyType: 2, keyID: 0

        // Broadcast with the OPERATOR's private key
        vm.startBroadcast(operator.privateKey);
        MyKeyRegistry(keyRegistry).setKey(keyTag, keyBytes, abi.encode(signature), abi.encode(keyG2));
        vm.stopBroadcast();
    }

    function _getG2Key(uint256 privateKey) internal view returns (BN254.G2Point memory) {
        BN254.G2Point memory G2 = BN254.generatorG2();
        (uint256 x1, uint256 x2, uint256 y1, uint256 y2) = BN254G2.ECTwistMul(
            privateKey,
            G2.X[1],
            G2.X[0],
            G2.Y[1],
            G2.Y[0]
        );
        return BN254.G2Point([x2, x1], [y2, y1]);
    }

    function _g2Mul(
        BLS12381.G2Point memory point,
        bytes32 scalar
    ) internal view returns (BLS12381.G2Point memory result) {
        BLS12381.G2Point[] memory points = new BLS12381.G2Point[](1);
        bytes32[] memory scalars = new bytes32[](1);
        points[0] = point;
        scalars[0] = scalar;

        assembly ("memory-safe") {
            let k := mload(points)
            let d := sub(scalars, points)
            for {
                let i := 0
            } iszero(eq(i, k)) {
                i := add(i, 1)
            } {
                points := add(points, 0x20)
                let o := add(result, mul(0x120, i))
                mcopy(o, mload(points), 0x100)
                mstore(add(o, 0x100), mload(add(d, points)))
            }
            if iszero(
                and(
                    and(eq(k, mload(scalars)), eq(returndatasize(), 0x100)),
                    staticcall(gas(), BLS12_G2MSM, result, mul(0x120, k), result, 0x100)
                )
            ) {
                mstore(0x00, 0xe3dc5425)
                revert(0x1c, 0x04)
            }
        }
    }
}
