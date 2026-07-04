// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20, ERC4626, IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAlphaVault} from "../interfaces/IAlphaVault.sol";
import {IEnclaveRegistry} from "../interfaces/IEnclaveRegistry.sol";
import {IDexRouter} from "../interfaces/IDexRouter.sol";
import {IFtsoV2} from "../interfaces/IFtsoV2.sol";
import {PerformanceLedger} from "./PerformanceLedger.sol";
import {FeeMath} from "../libraries/FeeMath.sol";

/// @title AlphaVault
/// @notice ERC-4626 vault that verifies enclave-signed trade instructions, executes them against a
/// DEX router, records NAV into an independent PerformanceLedger, and charges a single performance
/// fee — 10% of new profit above a global high-water mark, split 3% treasury / 7% strategist, minted
/// as vault shares — with zero management, listing, or withdrawal fees.
/// @dev Assumes the underlying asset and vault shares both use 18 decimals (see {FeeMath}). No
/// upgradeability proxy is used for this MVP: contracts are immutable-by-default; a security audit
/// and migration plan is explicit post-hackathon roadmap, not solved in-contract.
contract AlphaVault is IAlphaVault, ERC4626, Ownable2Step, EIP712, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice EIP-712 typehash for {TradeInstruction}.
    bytes32 public constant TRADE_INSTRUCTION_TYPEHASH = keccak256(
        "TradeInstruction(address asset,uint8 direction,uint256 size,uint256 minAmountOut,uint256 nonce,uint256 deadline)"
    );

    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Genesis high-water mark: 1.20x the genesis price-per-share (1e18) — the entire
    /// implementation of the protocol's 20% hurdle. No fee can trigger until PPS organically clears this.
    uint256 public constant GENESIS_HIGH_WATER_MARK = 1.2e18;

    /// @notice Receives 3% of gross harvested profit as newly minted shares.
    address public treasury;

    /// @notice Receives 7% of gross harvested profit as newly minted shares.
    address public strategist;

    /// @notice Registry AlphaVault consults to verify the signer of incoming trade instructions.
    IEnclaveRegistry public enclaveRegistry;

    /// @notice DEX router used to execute trade instructions.
    IDexRouter public dexRouter;

    /// @notice FTSOv2 price feed reader used to value any non-underlying position for NAV purposes.
    IFtsoV2 public ftsoV2;

    /// @notice Independent, append-only performance ledger this vault commits epoch NAV into.
    PerformanceLedger public performanceLedger;

    /// @notice Highest price-per-share (1e18 fixed point) a performance fee has ever been charged against.
    uint256 public highWaterMark;

    /// @notice Max size of a single trade instruction, as a fraction of vault TVL (basis points).
    uint256 public maxPositionSizeBps;

    /// @notice Drawdown from {highWaterMark}, in basis points, at which new trades are auto-paused.
    uint256 public maxDrawdownBps;

    /// @notice The non-underlying asset currently held by the vault, if any (address(0) if fully in underlying).
    address public currentPosition;

    /// @notice Cached USD-cross-rate value of {currentPosition}'s balance, denominated in the underlying
    /// asset, refreshed from FTSOv2 on every trade and on every {harvest} call.
    /// @dev Cached rather than read live inside {totalAssets} because {totalAssets} must remain `view`
    /// while FTSOv2's real `getFeedByIdInWei` is `payable`/state-changing and cannot be called from a
    /// view context — see README/DEPLOY notes for this documented MVP design choice.
    uint256 public cachedPositionValue;

    /// @notice FTSOv2 feed id configured for a given token, required before it can be traded or valued.
    mapping(address token => bytes21 feedId) public feedIdOf;

    /// @notice Nonces already consumed by a submitted trade instruction (replay protection).
    mapping(uint256 nonce => bool used) public usedNonces;

    event TreasuryUpdated(address indexed treasury);
    event StrategistUpdated(address indexed strategist);
    event EnclaveRegistryUpdated(address indexed enclaveRegistry);
    event DexRouterUpdated(address indexed dexRouter);
    event FtsoV2Updated(address indexed ftsoV2);
    event PerformanceLedgerUpdated(address indexed performanceLedger);
    event FeedIdUpdated(address indexed token, bytes21 feedId);
    event MaxPositionSizeUpdated(uint256 bps);
    event MaxDrawdownUpdated(uint256 bps);
    event CircuitBreakerTripped(uint256 currentPPS, uint256 highWaterMark, uint256 drawdownBps);
    event CircuitBreakerReset();
    event TradeExecuted(
        address indexed asset, TradeDirection direction, uint256 amountIn, uint256 amountOut, uint256 nonce
    );
    event Harvested(uint256 currentPPS, uint256 treasuryShares, uint256 strategistShares);

    error InstructionExpired(uint256 deadline, uint256 blockTimestamp);
    error NonceAlreadyUsed(uint256 nonce);
    error InvalidSigner(address recovered);
    error PositionTooLarge(uint256 size, uint256 max);
    error FeedNotConfigured(address token);
    error ZeroAddress();

    constructor(
        IERC20 asset_,
        string memory shareName_,
        string memory shareSymbol_,
        address initialOwner_,
        address treasury_,
        address strategist_,
        IEnclaveRegistry enclaveRegistry_,
        IDexRouter dexRouter_,
        IFtsoV2 ftsoV2_,
        PerformanceLedger performanceLedger_,
        uint256 maxPositionSizeBps_,
        uint256 maxDrawdownBps_
    )
        ERC20(shareName_, shareSymbol_)
        ERC4626(asset_)
        Ownable(initialOwner_)
        EIP712("EclipseAlphaVault", "1")
    {
        if (
            treasury_ == address(0) || strategist_ == address(0) || address(enclaveRegistry_) == address(0)
                || address(dexRouter_) == address(0) || address(ftsoV2_) == address(0)
                || address(performanceLedger_) == address(0)
        ) revert ZeroAddress();

        treasury = treasury_;
        strategist = strategist_;
        enclaveRegistry = enclaveRegistry_;
        dexRouter = dexRouter_;
        ftsoV2 = ftsoV2_;
        performanceLedger = performanceLedger_;
        maxPositionSizeBps = maxPositionSizeBps_;
        maxDrawdownBps = maxDrawdownBps_;
        highWaterMark = GENESIS_HIGH_WATER_MARK;
    }

    // ---------------------------------------------------------------------
    // Trade execution
    // ---------------------------------------------------------------------

    /// @inheritdoc IAlphaVault
    function submitInstruction(TradeInstruction calldata instruction, bytes calldata signature)
        external
        nonReentrant
        whenNotPaused
    {
        if (block.timestamp > instruction.deadline) revert InstructionExpired(instruction.deadline, block.timestamp);
        if (usedNonces[instruction.nonce]) revert NonceAlreadyUsed(instruction.nonce);

        address signer = ECDSA.recoverCalldata(hashTradeInstruction(instruction), signature);
        if (!enclaveRegistry.isValidSigner(address(this), signer)) revert InvalidSigner(signer);

        uint256 maxSize = (totalAssets() * maxPositionSizeBps) / BPS_DENOMINATOR;
        if (instruction.size > maxSize) revert PositionTooLarge(instruction.size, maxSize);

        // Effects: consume the nonce before any external interaction.
        usedNonces[instruction.nonce] = true;

        uint256 amountOut = _executeSwap(instruction);
        emit TradeExecuted(instruction.asset, instruction.direction, instruction.size, amountOut, instruction.nonce);

        _refreshPositionValue();
        _commitEpoch();
        _checkDrawdown();
        _harvest();
    }

    /// @notice Computes the EIP-712 digest a valid enclave signature must be produced over.
    function hashTradeInstruction(TradeInstruction calldata instruction) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                TRADE_INSTRUCTION_TYPEHASH,
                instruction.asset,
                uint8(instruction.direction),
                instruction.size,
                instruction.minAmountOut,
                instruction.nonce,
                instruction.deadline
            )
        );
        return _hashTypedDataV4(structHash);
    }

    function _executeSwap(TradeInstruction calldata instruction) private returns (uint256 amountOut) {
        address underlying = asset();
        if (feedIdOf[instruction.asset] == bytes21(0)) revert FeedNotConfigured(instruction.asset);
        if (feedIdOf[underlying] == bytes21(0)) revert FeedNotConfigured(underlying);

        address[] memory path = new address[](2);
        if (instruction.direction == TradeDirection.Buy) {
            path[0] = underlying;
            path[1] = instruction.asset;
        } else {
            path[0] = instruction.asset;
            path[1] = underlying;
        }

        IERC20(path[0]).forceApprove(address(dexRouter), instruction.size);
        uint256[] memory amounts = dexRouter.swapExactTokensForTokens(
            instruction.size, instruction.minAmountOut, path, address(this), instruction.deadline
        );
        amountOut = amounts[amounts.length - 1];

        currentPosition = instruction.direction == TradeDirection.Buy ? instruction.asset : address(0);
    }

    // ---------------------------------------------------------------------
    // NAV valuation
    // ---------------------------------------------------------------------

    /// @notice Total vault NAV denominated in the underlying asset: on-hand underlying balance plus
    /// the last-refreshed cross-rate value of any held satellite position.
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + cachedPositionValue;
    }

    /// @notice Refreshes {cachedPositionValue} from live FTSOv2 feeds. Permissionless so keepers can
    /// keep NAV current between trades (this is what lets standalone {harvest} capture passive price drift).
    function refreshPositionValue() public {
        _refreshPositionValue();
    }

    function _refreshPositionValue() private {
        if (currentPosition == address(0)) {
            cachedPositionValue = 0;
            return;
        }

        uint256 posBalance = IERC20(currentPosition).balanceOf(address(this));
        if (posBalance == 0) {
            cachedPositionValue = 0;
            return;
        }

        bytes21 posFeed = feedIdOf[currentPosition];
        bytes21 baseFeed = feedIdOf[asset()];
        if (posFeed == bytes21(0)) revert FeedNotConfigured(currentPosition);
        if (baseFeed == bytes21(0)) revert FeedNotConfigured(asset());

        (uint256 posPrice,) = ftsoV2.getFeedByIdInWei(posFeed);
        (uint256 basePrice,) = ftsoV2.getFeedByIdInWei(baseFeed);
        if (basePrice == 0) {
            cachedPositionValue = 0;
            return;
        }

        cachedPositionValue = (posBalance * posPrice) / basePrice;
    }

    function _commitEpoch() private {
        performanceLedger.commitEpoch(totalAssets(), block.timestamp);
    }

    // ---------------------------------------------------------------------
    // Risk limits / circuit breaker
    // ---------------------------------------------------------------------

    /// @notice Permissionless check that pauses new trades if NAV has drawn down past {maxDrawdownBps}
    /// from {highWaterMark}. A no-op if the vault is already paused or within tolerance.
    function checkDrawdown() external {
        _checkDrawdown();
    }

    function _checkDrawdown() private {
        if (paused()) return;

        uint256 supply = totalSupply();
        if (supply == 0) return;

        uint256 currentPPS = FeeMath.pricePerShare(totalAssets(), supply);
        if (currentPPS >= highWaterMark) return;

        uint256 drawdownBps = ((highWaterMark - currentPPS) * BPS_DENOMINATOR) / highWaterMark;
        if (drawdownBps >= maxDrawdownBps) {
            _pause();
            emit CircuitBreakerTripped(currentPPS, highWaterMark, drawdownBps);
        }
    }

    /// @notice Owner override to resume trading after a circuit-breaker pause has been investigated.
    function resetCircuitBreaker() external onlyOwner {
        _unpause();
        emit CircuitBreakerReset();
    }

    // ---------------------------------------------------------------------
    // Fee harvest
    // ---------------------------------------------------------------------

    /// @inheritdoc IAlphaVault
    function harvest() external nonReentrant {
        _refreshPositionValue();
        _harvest();
    }

    function _harvest() private {
        uint256 assets = totalAssets();
        uint256 supply = totalSupply();
        uint256 currentPPS = FeeMath.pricePerShare(assets, supply);

        (uint256 treasuryShares, uint256 strategistShares) =
            FeeMath.computeFeeShares(currentPPS, highWaterMark, assets, supply);

        if (treasuryShares == 0 && strategistShares == 0) {
            return;
        }

        highWaterMark = currentPPS;

        if (treasuryShares > 0) _mint(treasury, treasuryShares);
        if (strategistShares > 0) _mint(strategist, strategistShares);

        emit Harvested(currentPPS, treasuryShares, strategistShares);
    }

    // ---------------------------------------------------------------------
    // ERC-4626 reentrancy hardening (deposit/mint are also guarded; no fee logic added to any path)
    // ---------------------------------------------------------------------

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        nonReentrant
        returns (uint256)
    {
        return super.withdraw(assets, receiver, owner_);
    }

    function redeem(uint256 shares, address receiver, address owner_) public override nonReentrant returns (uint256) {
        return super.redeem(shares, receiver, owner_);
    }

    // ---------------------------------------------------------------------
    // Owner configuration
    // ---------------------------------------------------------------------

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    function setStrategist(address strategist_) external onlyOwner {
        if (strategist_ == address(0)) revert ZeroAddress();
        strategist = strategist_;
        emit StrategistUpdated(strategist_);
    }

    function setEnclaveRegistry(IEnclaveRegistry enclaveRegistry_) external onlyOwner {
        if (address(enclaveRegistry_) == address(0)) revert ZeroAddress();
        enclaveRegistry = enclaveRegistry_;
        emit EnclaveRegistryUpdated(address(enclaveRegistry_));
    }

    function setDexRouter(IDexRouter dexRouter_) external onlyOwner {
        if (address(dexRouter_) == address(0)) revert ZeroAddress();
        dexRouter = dexRouter_;
        emit DexRouterUpdated(address(dexRouter_));
    }

    function setFtsoV2(IFtsoV2 ftsoV2_) external onlyOwner {
        if (address(ftsoV2_) == address(0)) revert ZeroAddress();
        ftsoV2 = ftsoV2_;
        emit FtsoV2Updated(address(ftsoV2_));
    }

    function setPerformanceLedger(PerformanceLedger performanceLedger_) external onlyOwner {
        if (address(performanceLedger_) == address(0)) revert ZeroAddress();
        performanceLedger = performanceLedger_;
        emit PerformanceLedgerUpdated(address(performanceLedger_));
    }

    function setFeedId(address token, bytes21 feedId) external onlyOwner {
        feedIdOf[token] = feedId;
        emit FeedIdUpdated(token, feedId);
    }

    function setMaxPositionSizeBps(uint256 bps) external onlyOwner {
        maxPositionSizeBps = bps;
        emit MaxPositionSizeUpdated(bps);
    }

    function setMaxDrawdownBps(uint256 bps) external onlyOwner {
        maxDrawdownBps = bps;
        emit MaxDrawdownUpdated(bps);
    }
}
