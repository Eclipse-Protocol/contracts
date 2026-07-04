// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PerformanceLedger} from "../src/core/PerformanceLedger.sol";
import {EnclaveRegistry} from "../src/core/EnclaveRegistry.sol";
import {StrategyRegistry} from "../src/core/StrategyRegistry.sol";
import {AlphaVault} from "../src/core/AlphaVault.sol";
import {IFdcVerification} from "../src/interfaces/IFdcVerification.sol";
import {IDexRouter} from "../src/interfaces/IDexRouter.sol";
import {IFtsoV2} from "../src/interfaces/IFtsoV2.sol";
import {IEnclaveRegistry} from "../src/interfaces/IEnclaveRegistry.sol";

/// @notice Deploys the full Eclipse Protocol contract set to Coston2, in dependency order:
/// PerformanceLedger -> EnclaveRegistry -> StrategyRegistry -> AlphaVault, then binds the ledger to
/// the vault. All external addresses are read from the environment — nothing is hardcoded, since
/// real Coston2 addresses for the DEX router / FTSOv2 / FDC verification are deployment-specific.
///
/// Usage:
///   forge script script/DeployCoston2.s.sol:DeployCoston2 \
///     --rpc-url coston2 --broadcast --verify --verifier blockscout \
///     --verifier-url https://coston2-explorer.flare.network/api
contract DeployCoston2 is Script {
    /// @dev Default risk limits, owner-adjustable post-deploy via AlphaVault's setters.
    uint256 internal constant DEFAULT_MAX_POSITION_SIZE_BPS = 2_000; // 20% of TVL per instruction
    uint256 internal constant DEFAULT_MAX_DRAWDOWN_BPS = 1_500; // 15% drawdown trips the breaker

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address strategist = vm.envAddress("STRATEGIST_ADDRESS");
        IERC20 vaultAsset = IERC20(vm.envAddress("VAULT_ASSET_ADDRESS"));
        IDexRouter dexRouter = IDexRouter(vm.envAddress("DEX_ROUTER_ADDRESS"));
        IFtsoV2 ftsoV2 = IFtsoV2(vm.envAddress("FTSO_V2_ADDRESS"));
        IFdcVerification fdcVerification = IFdcVerification(vm.envAddress("FDC_VERIFICATION_ADDRESS"));
        IERC20 bondToken = IERC20(vm.envAddress("BOND_TOKEN_ADDRESS"));

        uint256 maxPositionSizeBps = vm.envOr("MAX_POSITION_SIZE_BPS", DEFAULT_MAX_POSITION_SIZE_BPS);
        uint256 maxDrawdownBps = vm.envOr("MAX_DRAWDOWN_BPS", DEFAULT_MAX_DRAWDOWN_BPS);

        vm.startBroadcast(deployerKey);

        PerformanceLedger ledger = new PerformanceLedger(deployer);
        EnclaveRegistry registry = new EnclaveRegistry(deployer, fdcVerification);
        StrategyRegistry strategyRegistry = new StrategyRegistry(deployer, bondToken);

        AlphaVault vault = new AlphaVault(
            vaultAsset,
            "Eclipse Alpha Vault Shares",
            "eaVLT",
            deployer,
            treasury,
            strategist,
            IEnclaveRegistry(address(registry)),
            dexRouter,
            ftsoV2,
            ledger,
            maxPositionSizeBps,
            maxDrawdownBps
        );

        ledger.setVault(address(vault));

        vm.stopBroadcast();

        console.log("PerformanceLedger deployed at:", address(ledger));
        console.log("EnclaveRegistry deployed at:  ", address(registry));
        console.log("StrategyRegistry deployed at: ", address(strategyRegistry));
        console.log("AlphaVault deployed at:       ", address(vault));
        console.log("Deployer / initial owner:     ", deployer);
    }
}
