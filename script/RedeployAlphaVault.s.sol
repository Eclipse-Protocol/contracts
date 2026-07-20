// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PerformanceLedger} from "../src/core/PerformanceLedger.sol";
import {AlphaVault} from "../src/core/AlphaVault.sol";
import {IEnclaveRegistry} from "../src/interfaces/IEnclaveRegistry.sol";
import {IDexRouter} from "../src/interfaces/IDexRouter.sol";
import {IFtsoV2} from "../src/interfaces/IFtsoV2.sol";

/// @notice Redeploys AlphaVault + PerformanceLedger after the _refreshPositionValue() decimals fix.
/// EnclaveRegistry, the DEX router, and FTSOv2 are NOT redeployed: EnclaveRegistry is keyed by vault
/// address (the old vault's corrupted state is simply orphaned, not reused), and the router/FTSOv2 are
/// shared infrastructure unaffected by the bug. The new vault starts fully empty — no deposits, no
/// registered enclave signer, no feed IDs — each must be (re)done against the new address.
///
/// Usage:
///   forge script script/RedeployAlphaVault.s.sol:RedeployAlphaVault --rpc-url coston2 --broadcast
contract RedeployAlphaVault is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address strategist = vm.envAddress("STRATEGIST_ADDRESS");
        IERC20 vaultAsset = IERC20(vm.envAddress("VAULT_ASSET_ADDRESS"));
        IEnclaveRegistry enclaveRegistry = IEnclaveRegistry(vm.envAddress("ENCLAVE_REGISTRY_ADDRESS"));
        IDexRouter dexRouter = IDexRouter(vm.envAddress("DEX_ROUTER_ADDRESS"));
        IFtsoV2 ftsoV2 = IFtsoV2(vm.envAddress("FTSO_V2_ADDRESS"));

        uint256 maxPositionSizeBps = vm.envUint("MAX_POSITION_SIZE_BPS");
        uint256 maxDrawdownBps = vm.envUint("MAX_DRAWDOWN_BPS");

        vm.startBroadcast(deployerKey);

        PerformanceLedger ledger = new PerformanceLedger(deployer);

        AlphaVault vault = new AlphaVault(
            vaultAsset,
            "Eclipse Alpha Vault Shares",
            "eaVLT",
            deployer,
            treasury,
            strategist,
            enclaveRegistry,
            dexRouter,
            ftsoV2,
            ledger,
            maxPositionSizeBps,
            maxDrawdownBps
        );

        ledger.setVault(address(vault));

        vm.stopBroadcast();

        console.log("New PerformanceLedger deployed at:", address(ledger));
        console.log("New AlphaVault deployed at:       ", address(vault));
        console.log("Owner:                             ", deployer);
    }
}
