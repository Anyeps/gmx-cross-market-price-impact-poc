// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// GMX lead G-P1-2 — price-impact / swap-path manipulation.
// Fork: Arbitrum, block 524054954 (fresh, 2026-11-14 ~11:10 WIB).
// DEEPENING (this file): re-run on fresh fork block 524060716 (2026-11-14,
// ETH $1,893.52). Live config at THAT block (test_ProbeDeepenConfig):
// M_WETH pool 6,502.13 WETH, OI long $545,188 / short $787,562,
// max OI $9.55M/side; M_USDC pool 11,626.63 WETH + $22.74M USDC,
// OI long $4,747,612 / short $5,965,700, max OI $86.34M/side;
// virtual inventory +257.36 WETH. See DEEPENING.md for the full numbers.
// Markets: ETH/USD [WETH-USDC] 0x70d95587... (index WETH, long WETH, short USDC),
//          ETH/USD [WETH-WETH] 0x450bb677... (index WETH, long WETH, short WETH),
//          ETH/USD [WSTETH-USDE] 0x0Cf1fb4d... (index WETH, long wstETH, short USDE).
//
// Live config at fork (verified by GP12Probe, not trusted from the recon snapshot):
// - USE_OPEN_INTEREST_IN_TOKENS_FOR_BALANCE = true (token-based OI path is live).
// - All WETH-index markets share virtualTokenId 0x3c48...; live virtual inventory
//   (tokens path) = 420.01 WETH (~$796k net short). The USD-path virtual inventory
//   ($9.74M) is STALE — never updated while the tokens flag is on.
// - [WETH-USDC]: impact factors +9.24e-8 / -1.11e-7, exponent 1.56, max +/- 40/50 bps,
//   pool 445.4 WETH (~$844k), lent 0, maxLendable 0/0, minCollateralFactor 0.5%,
//   max OI $86.3M/side, OI long $4.86M / short $6.41M (short-heavy, diff -$1.55M).
// - [WETH-WETH]: impact factors +1e-15 / -2e-15 (!!), exponent 1.0 (linear),
//   max +/- 40/50 bps, pool 15.85 WETH (~$30k), lent 0, maxLendable 0/0,
//   minCollateralFactor 0.5%, max OI $9.55M/side, OI long $563k / short $795k.
// - [WSTETH-USDE]: factors +6.66e-8 / -8.0e-8, exponent 1.58, pool 5.83 WETH (~$11k).
//
// Harness notes (same as G-P1-4):
// - Oracle: Oracle.setPrimaryPrice (prank ExchangeRouter, holds CONTROLLER) +
//   Oracle.setTimestamps(block.timestamp, block.timestamp), then executeOrder with
//   EMPTY SetPricesParams so setPrices() is a no-op. NO oracle forgery: prices are
//   the live Chainlink feed values read from the DataStore at the fork block.
// - The withOraclePrices modifier clears ALL prices at the END of every handler
//   call, so prices must be re-set before EVERY handler call (done in _executeOrder).
// - tx.gasprice defaults to 0 in Foundry — vm.txGasPrice(0.1 gwei) is set before
//   every create/execute/cancel call, otherwise the keeper payment is 0.
// - Foundry does NOT debit gas from balances, so keeper balance delta == keeper
//   payment exactly, and user balance delta == refund/payout exactly.
// - Minimum execution fee at 0.1 gwei is 0.0004123455 ETH; this test uses 0.001 ETH.
// - Position key = keccak256(abi.encode(account, market, collateralToken, isLong)).
// - Open impact is measured from the position's pendingImpactAmount (index tokens,
//   signed) x entry price; it is STORED at open and realised at close, so the
//   open-impact measurement is clean of close-time caps.
// - Close impact is measured from the payout AND the position's collateral
//   change: totalImpactUsd = payout - collateralBefore + closeFee, with PnL = 0
//   and funding/borrowing = 0 (no time elapses between open and close).
//   CORRECTION to G-P1-4: the position fee is NOT zero — live factors are
//   0.04% (balance improved) / 0.06% (not improved) per market. G-P1-4's D1
//   "$4.23 impact on a $3,850 close" was ~$3.85 position fees + ~$0.38 net
//   impact, not $4.23 of impact. The fee is read live and added back here.
//   For partial closes the collateral stays in the position, so the unified
//   per-piece formula totalImpact = closeFee - collateralDelta + payout is used
//   (verified against the PositionDecrease event values for piece 1).

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../contracts/utils/GmxForkHelpers.sol";
import "../contracts/constants/GmxArbitrumAddresses.sol";
import "../contracts/interfaces/IGmxV2.sol";
import {Keys as GmxKeys} from "../contracts/Keys.sol";

contract GP12DeepenTest is GmxForkHelpers {
    address internal constant M_USDC = 0x70d95587d40A2caf56bd97485aB3Eec10Bee6336;
    address internal constant M_WETH = 0x450bb6774Dd8a756274E0ab4107953259d2ac541;
    address internal constant M_WSTETH = 0x0Cf1fb4d1FF67A3D8Ca92c9d6643F8F9be8e03E5;
    address internal constant WSTETH = 0x5979D7b546E38E414F7E9822514be443A4800529;
    address internal constant USDE = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34;
    uint256 internal constant USDC_PX = 1e24; // $1 per USDC unit (6 decimals)
    uint256 internal constant GAS_PRICE = 0.1 gwei;
    uint256 internal constant STD_FEE = 0.001 ether;

    bytes32 internal constant POSITION_SIZE_IN_USD = keccak256(abi.encode("SIZE_IN_USD"));
    bytes32 internal constant POSITION_COLLATERAL_AMOUNT = keccak256(abi.encode("COLLATERAL_AMOUNT"));
    bytes32 internal constant PENDING_IMPACT_AMOUNT = keccak256(abi.encode("PENDING_IMPACT_AMOUNT"));

    address internal userA = address(0xA11CE);
    address internal userB = address(0xB0B);
    address internal userC = address(0xC11C);
    address internal userD = address(0xD11D);
    address internal userE = address(0xE11E);
    address internal userF = address(0xF11F);
    address internal keeper;
    IERC20 internal weth;
    IERC20 internal usdc;
    IERC20 internal usde;
    uint256 internal entryPx; // WETH GMX price (USD * 1e12)
    uint256 internal wstethPx;
    uint256 internal usdePx;

    function setUp() public {
        vm.createSelectFork("https://arb1.arbitrum.io/rpc", 524059227);
        exchangeRouter = IExchangeRouter(GmxArbitrumAddresses.EXCHANGE_ROUTER);
        orderHandler = IOrderHandler(GmxArbitrumAddresses.ORDER_HANDLER);
        oracle = IOracle(GmxArbitrumAddresses.ORACLE);
        dataStore = IDataStore(GmxArbitrumAddresses.DATA_STORE);
        roleStore = IRoleStore(GmxArbitrumAddresses.ROLE_STORE);
        weth = IERC20(GmxArbitrumAddresses.WETH);
        usdc = IERC20(GmxArbitrumAddresses.USDC);
        usde = IERC20(USDE);

        vm.deal(userA, 100 ether);
        vm.deal(userB, 100 ether);
        vm.deal(userC, 100 ether);
        vm.deal(userD, 100 ether);
        vm.deal(userE, 100 ether);
        vm.deal(userF, 100 ether);

        uint256 kc = roleStore.getRoleMemberCount(Keys.ORDER_KEEPER);
        require(kc > 0, "no keepers");
        address[] memory ks = roleStore.getRoleMembers(Keys.ORDER_KEEPER, 0, kc);
        keeper = ks[0];
        vm.deal(keeper, 10 ether);

        (uint256 px, bool ok) = _feedPrice(GmxArbitrumAddresses.WETH);
        require(ok, "no weth feed");
        entryPx = px;
        (uint256 wpx, bool wok) = _feedPrice(WSTETH);
        wstethPx = wok ? wpx : entryPx;
        (uint256 upx, bool uok) = _feedPrice(USDE);
        usdePx = uok ? upx : 1e24;
        console.log("entryPx (USD*1e12):", entryPx);
        console.log("wstethPx:", wstethPx, "usdePx:", usdePx);
        _setPricesAll();
    }

    // ------------------------------------------------------------------ helpers

    function _feedPrice(address token) internal view returns (uint256 price, bool ok) {
        address feed = dataStore.getAddress(GmxKeys.priceFeedKey(token));
        if (feed == address(0)) return (0, false);
        uint256 mult = dataStore.getUint(GmxKeys.priceFeedMultiplierKey(token));
        (bool success, bytes memory ret) = feed.staticcall(abi.encodeWithSignature("latestRoundData()"));
        if (!success || ret.length < 160) return (0, false);
        (, int256 answer, , , ) = abi.decode(ret, (uint80, int256, uint256, uint256, uint80));
        if (answer <= 0 || mult == 0) return (0, false);
        uint256 ans = uint256(answer);
        if (mult >= 1e30) {
            price = ans * (mult / 1e30);
        } else {
            price = ans * mult / 1e30;
        }
        if (price < 1 || price > 1e36) return (0, false);
        return (price, true);
    }

    function _setPricesAll() internal {
        vm.prank(GmxArbitrumAddresses.EXCHANGE_ROUTER);
        oracle.clearAllPrices();
        vm.prank(GmxArbitrumAddresses.EXCHANGE_ROUTER);
        oracle.setPrimaryPrice(GmxArbitrumAddresses.WETH, Price.Props({min: entryPx, max: entryPx}));
        vm.prank(GmxArbitrumAddresses.EXCHANGE_ROUTER);
        oracle.setPrimaryPrice(GmxArbitrumAddresses.USDC, Price.Props({min: USDC_PX, max: USDC_PX}));
        vm.prank(GmxArbitrumAddresses.EXCHANGE_ROUTER);
        oracle.setPrimaryPrice(WSTETH, Price.Props({min: wstethPx, max: wstethPx}));
        vm.prank(GmxArbitrumAddresses.EXCHANGE_ROUTER);
        oracle.setPrimaryPrice(USDE, Price.Props({min: usdePx, max: usdePx}));
        vm.prank(GmxArbitrumAddresses.EXCHANGE_ROUTER);
        oracle.setTimestamps(block.timestamp, block.timestamp);
    }

    function _emptyOracleParams() internal pure returns (OracleUtils.SetPricesParams memory p) {
        p.tokens = new address[](0);
        p.providers = new address[](0);
        p.data = new bytes[](0);
    }

    function _positionKey(address account, address market, address collateralToken, bool isLong) internal pure returns (bytes32) {
        return keccak256(abi.encode(account, market, collateralToken, isLong));
    }

    function _positionSizeUsd(address account, address market, address collateralToken, bool isLong) internal view returns (uint256) {
        return dataStore.getUint(keccak256(abi.encode(_positionKey(account, market, collateralToken, isLong), POSITION_SIZE_IN_USD)));
    }

    function _positionCollateral(address account, address market, address collateralToken, bool isLong) internal view returns (uint256) {
        return dataStore.getUint(keccak256(abi.encode(_positionKey(account, market, collateralToken, isLong), POSITION_COLLATERAL_AMOUNT)));
    }

    /// Pending impact stored in the position, in index tokens (signed). Negative =
    /// the position owes impact (it worsened the pool balance at open).
    function _pendingImpactTokens(address account, address market, address collateralToken, bool isLong) internal view returns (int256) {
        return dataStore.getInt(keccak256(abi.encode(_positionKey(account, market, collateralToken, isLong), PENDING_IMPACT_AMOUNT)));
    }

    /// Pending impact in USD (1e30). min == max in this harness, so a single price applies.
    /// Note: wei * entryPx == USD in 1e30 scale directly (entryPx is USD x 1e12,
    /// token amounts are 1e18-scaled), so there is NO division by 1e18 here.
    function _pendingImpactUsd(address account, address market, address collateralToken, bool isLong) internal view returns (int256) {
        int256 amt = _pendingImpactTokens(account, market, collateralToken, isLong);
        return amt * int256(entryPx);
    }

    function _impactPoolAmount(address market) internal view returns (uint256) {
        return dataStore.getUint(GmxKeys.positionImpactPoolAmountKey(market));
    }

    function _virtualInventoryTokens() internal view returns (int256) {
        bytes32 vtid = dataStore.getBytes32(GmxKeys.virtualTokenIdKey(GmxArbitrumAddresses.WETH));
        return dataStore.getInt(GmxKeys.virtualInventoryForPositionsInTokensKey(vtid));
    }

    /// Increase-order creation. Collateral + fee are escrowed in the OrderVault
    /// before createOrder: WNT via sendWnt, other tokens via sendTokens (+ fee in WNT).
    function _createIncrease(
        address market,
        address collateralToken,
        address account,
        bool isLong,
        uint256 collateralAmount,
        uint256 sizeDeltaUsd,
        uint256 fee
    ) internal returns (bytes32) {
        IExchangeRouter.CreateOrderParams memory params =
            createIncreaseOrderParams(market, collateralToken, collateralAmount, sizeDeltaUsd, isLong);
        params.orderType = IExchangeRouter.OrderType.MarketIncrease;
        params.numbers.executionFee = fee;
        params.numbers.acceptablePrice = isLong ? type(uint256).max : 1;
        params.numbers.minOutputAmount = 0;
        params.numbers.callbackGasLimit = 0;
        params.numbers.validFromTime = 0;
        params.addresses.receiver = account;
        params.addresses.cancellationReceiver = account;
        params.autoCancel = false;
        params.shouldUnwrapNativeToken = false;
        if (collateralToken == GmxArbitrumAddresses.WETH) {
            params.numbers.initialCollateralDeltaAmount = collateralAmount + fee;
            vm.txGasPrice(GAS_PRICE);
            vm.startPrank(account);
            exchangeRouter.sendWnt{value: collateralAmount + fee}(GmxArbitrumAddresses.ORDER_VAULT, collateralAmount + fee);
            bytes32 key = exchangeRouter.createOrder{value: 0}(params);
            vm.stopPrank();
            return key;
        } else {
            params.numbers.initialCollateralDeltaAmount = collateralAmount;
            vm.txGasPrice(GAS_PRICE);
            vm.startPrank(account);
            // sendTokens routes through Router.pluginTransfer, so the ROUTER
            // plugin (not the ExchangeRouter) is the one that transferFroms —
            // approve it (and the ExchangeRouter for good measure).
            IERC20(collateralToken).approve(address(exchangeRouter), collateralAmount);
            IERC20(collateralToken).approve(GmxArbitrumAddresses.ROUTER, collateralAmount);
            exchangeRouter.sendTokens(collateralToken, GmxArbitrumAddresses.ORDER_VAULT, collateralAmount);
            exchangeRouter.sendWnt{value: fee}(GmxArbitrumAddresses.ORDER_VAULT, fee);
            bytes32 key = exchangeRouter.createOrder{value: 0}(params);
            vm.stopPrank();
            return key;
        }
    }

    /// Decrease-order creation. Only the fee is paid in WNT; payout is unwrapped
    /// to native ETH for WETH-collateral positions.
    function _createDecrease(
        address market,
        address collateralToken,
        address account,
        bool isLong,
        uint256 sizeDeltaUsd,
        uint256 fee
    ) internal returns (bytes32) {
        IExchangeRouter.CreateOrderParams memory params =
            createDecreaseOrderParams(market, collateralToken, sizeDeltaUsd, isLong);
        params.orderType = IExchangeRouter.OrderType.MarketDecrease;
        params.numbers.executionFee = fee;
        params.numbers.acceptablePrice = isLong ? 0 : type(uint256).max;
        params.numbers.minOutputAmount = 0;
        params.numbers.callbackGasLimit = 0;
        params.numbers.validFromTime = 0;
        params.addresses.receiver = account;
        params.addresses.cancellationReceiver = account;
        params.autoCancel = false;
        params.shouldUnwrapNativeToken = true;
        vm.txGasPrice(GAS_PRICE);
        vm.startPrank(account);
        exchangeRouter.sendWnt{value: fee}(GmxArbitrumAddresses.ORDER_VAULT, fee);
        bytes32 key = exchangeRouter.createOrder{value: 0}(params);
        vm.stopPrank();
        return key;
    }

    function _executeOrder(bytes32 key) internal {
        _setPricesAll();
        vm.txGasPrice(GAS_PRICE);
        vm.prank(keeper);
        orderHandler.executeOrder(key, _emptyOracleParams());
    }

    /// USD value (1e30 scale) of a WETH wei amount at entryPx.
    function _usdOf(uint256 weiAmount) internal view returns (uint256) {
        return weiAmount * entryPx;
    }

    /// Live position-fee factor for a market (0.04% if the trade improves the
    /// balance, 0.06% if not — NOT zero; G-P1-4's "POSITION_FEE_FACTOR = 0" was
    /// the base key, not this per-market key).
    function _positionFeeFactor(address market, bool improved) internal view returns (uint256) {
        return dataStore.getUint(GmxKeys.positionFeeFactorKey(market, improved));
    }

    /// Open a SHORT and return its stored (pending) impact in USD (1e30, signed).
    /// Collateral is WETH (native ETH), 10x leverage by default via `collateral`.
    function _openShort(address market, address account, uint256 sizeUsd, uint256 collateralEth) internal returns (int256 pendingUsd) {
        bytes32 key = _createIncrease(market, GmxArbitrumAddresses.WETH, account, false, collateralEth, sizeUsd, STD_FEE);
        _executeOrder(key);
        assertEq(_positionSizeUsd(account, market, GmxArbitrumAddresses.WETH, false), sizeUsd, "short not opened");
        pendingUsd = _pendingImpactUsd(account, market, GmxArbitrumAddresses.WETH, false);
    }

    // ------------------------------------------------------------------ extra helpers

    /// Non-asserting SHORT open: executes via low-level call so a rejection is
    /// captured (ok=false + raw revert data) instead of reverting the test.
    /// Returns (opened, pendingUsd, ok, retData).
    function _tryOpenShort(address market, address account, uint256 sizeUsd, uint256 collateralEth)
        internal
        returns (bool opened, int256 pendingUsd, bool ok, bytes memory retData)
    {
        bytes32 key = _createIncrease(market, GmxArbitrumAddresses.WETH, account, false, collateralEth, sizeUsd, STD_FEE);
        _setPricesAll();
        vm.txGasPrice(GAS_PRICE);
        vm.prank(keeper);
        (ok, retData) = address(orderHandler).call(
            abi.encodeWithSelector(IOrderHandler.executeOrder.selector, key, _emptyOracleParams())
        );
        opened = _positionSizeUsd(account, market, GmxArbitrumAddresses.WETH, false) == sizeUsd;
        if (opened) pendingUsd = _pendingImpactUsd(account, market, GmxArbitrumAddresses.WETH, false);
    }

    /// Non-asserting LONG open (WETH collateral).
    function _tryOpenLong(address market, address account, uint256 sizeUsd, uint256 collateralEth)
        internal
        returns (bool opened, int256 pendingUsd, bool ok, bytes memory retData)
    {
        bytes32 key = _createIncrease(market, GmxArbitrumAddresses.WETH, account, true, collateralEth, sizeUsd, STD_FEE);
        _setPricesAll();
        vm.txGasPrice(GAS_PRICE);
        vm.prank(keeper);
        (ok, retData) = address(orderHandler).call(
            abi.encodeWithSelector(IOrderHandler.executeOrder.selector, key, _emptyOracleParams())
        );
        opened = _positionSizeUsd(account, market, GmxArbitrumAddresses.WETH, true) == sizeUsd;
        if (opened) pendingUsd = _pendingImpactUsd(account, market, GmxArbitrumAddresses.WETH, true);
    }

    /// Log a revert's 4-byte selector; if it is InsufficientReserve[ForOpenInterest]
    /// decode the (reservedUsd, maxReservedUsd) pair.
    function _logRevert(bytes memory retData) internal pure {
        if (retData.length < 4) { console.log("  revert: no data"); return; }
        bytes4 sel = bytes4(retData);
        console.log("  revert selector:");
        console.logBytes4(sel);
        if (retData.length >= 68) {
            (uint256 a, uint256 b) = abi.decode(_slice(retData, 4), (uint256, uint256));
            console.log("  revert arg0 (1e30 or wei):", a);
            console.log("  revert arg1 (1e30 or wei):", b);
        }
    }

    function _slice(bytes memory data, uint256 start) internal pure returns (bytes memory) {
        bytes memory out = new bytes(data.length - start);
        for (uint256 i = 0; i < out.length; i++) out[i] = data[start + i];
        return out;
    }

    /// Close a WETH-collateral SHORT fully; return totalImpactUsd (D1 formula).
    function _closeShortWeth(address market, address account, uint256 sizeUsd, bool improved) internal returns (int256 totalImpactUsd) {
        uint256 collBeforeWei = _positionCollateral(account, market, GmxArbitrumAddresses.WETH, false);
        uint256 feeFactor = _positionFeeFactor(market, improved);
        int256 closeFeeUsd = int256(sizeUsd * feeFactor / 1e30);
        bytes32 decKey = _createDecrease(market, GmxArbitrumAddresses.WETH, account, false, sizeUsd, STD_FEE);
        uint256 userBefore = account.balance;
        uint256 keeperBefore = keeper.balance;
        _executeOrder(decKey);
        require(_positionSizeUsd(account, market, GmxArbitrumAddresses.WETH, false) == 0, "short not closed");
        uint256 userGain = account.balance - userBefore;
        uint256 keeperGain = keeper.balance - keeperBefore;
        int256 payoutUsd = int256(userGain + keeperGain - STD_FEE) * int256(entryPx);
        int256 collBeforeUsd = int256(collBeforeWei) * int256(entryPx);
        totalImpactUsd = payoutUsd - collBeforeUsd + closeFeeUsd;
    }

    /// Close a WETH-collateral LONG fully; return totalImpactUsd (same formula, isLong=true).
    function _closeLongWeth(address market, address account, uint256 sizeUsd, bool improved) internal returns (int256 totalImpactUsd) {
        uint256 collBeforeWei = _positionCollateral(account, market, GmxArbitrumAddresses.WETH, true);
        uint256 feeFactor = _positionFeeFactor(market, improved);
        int256 closeFeeUsd = int256(sizeUsd * feeFactor / 1e30);
        bytes32 decKey = _createDecrease(market, GmxArbitrumAddresses.WETH, account, true, sizeUsd, STD_FEE);
        uint256 userBefore = account.balance;
        uint256 keeperBefore = keeper.balance;
        _executeOrder(decKey);
        require(_positionSizeUsd(account, market, GmxArbitrumAddresses.WETH, true) == 0, "long not closed");
        uint256 userGain = account.balance - userBefore;
        uint256 keeperGain = keeper.balance - keeperBefore;
        int256 payoutUsd = int256(userGain + keeperGain - STD_FEE) * int256(entryPx);
        int256 collBeforeUsd = int256(collBeforeWei) * int256(entryPx);
        totalImpactUsd = payoutUsd - collBeforeUsd + closeFeeUsd;
    }

    /// Raw pool amount in the DataStore (NOT halved for single-token markets).
    function _poolRaw(address market, address token) internal view returns (uint256) {
        return dataStore.getUint(GmxKeys.poolAmountKey(market, token));
    }

    /// Open interest in USD for a side, summed over both collateral tokens.
    function _oiUsd(address market, bool isLong) internal view returns (uint256) {
        return dataStore.getUint(GmxKeys.openInterestKey(market, GmxArbitrumAddresses.WETH, isLong))
            + dataStore.getUint(GmxKeys.openInterestKey(market, GmxArbitrumAddresses.USDC, isLong));
    }

    // ------------------------------------------------------------------ probe

    /// Live config that decides the deepening: reserve factors, max OI, pools,
    /// swap factors, virtual market ids. Read on the fresh fork, not trusted
    /// from the G-P1-2 recon snapshot.
    function test_ProbeDeepenConfig() public {
        console.log("entryPx (USD*1e12):", entryPx);
        console.log("--- M_WETH 0x450bb677 ---");
        console.log("reserveFactor long:", dataStore.getUint(GmxKeys.reserveFactorKey(M_WETH, true)));
        console.log("reserveFactor short:", dataStore.getUint(GmxKeys.reserveFactorKey(M_WETH, false)));
        console.log("oiReserveFactor long:", dataStore.getUint(GmxKeys.openInterestReserveFactorKey(M_WETH, true)));
        console.log("oiReserveFactor short:", dataStore.getUint(GmxKeys.openInterestReserveFactorKey(M_WETH, false)));
        console.log("maxOpenInterest long (1e30):", dataStore.getUint(GmxKeys.maxOpenInterestKey(M_WETH, true)));
        console.log("maxOpenInterest short (1e30):", dataStore.getUint(GmxKeys.maxOpenInterestKey(M_WETH, false)));
        console.log("poolRaw WETH (wei):", _poolRaw(M_WETH, GmxArbitrumAddresses.WETH));
        console.log("oiUsd long (1e30):", _oiUsd(M_WETH, true));
        console.log("oiUsd short (1e30):", _oiUsd(M_WETH, false));
        console.log("posImpactFactor + (1e30):", dataStore.getUint(GmxKeys.positionImpactFactorKey(M_WETH, true)));
        console.log("posImpactFactor - (1e30):", dataStore.getUint(GmxKeys.positionImpactFactorKey(M_WETH, false)));
        console.log("posImpactExponent + (1e30):", dataStore.getUint(GmxKeys.positionImpactExponentFactorKey(M_WETH, true)));
        console.log("posImpactExponent - (1e30):", dataStore.getUint(GmxKeys.positionImpactExponentFactorKey(M_WETH, false)));
        console.log("maxPosImpactFactor + (1e30):", dataStore.getUint(GmxKeys.maxPositionImpactFactorKey(M_WETH, true)));
        console.log("maxPosImpactFactor - (1e30):", dataStore.getUint(GmxKeys.maxPositionImpactFactorKey(M_WETH, false)));
        console.log("impactPool (wei):", _impactPoolAmount(M_WETH));
        console.log("swapImpactFactor + (1e30):", dataStore.getUint(GmxKeys.swapImpactFactorKey(M_WETH, true)));
        console.log("swapImpactFactor - (1e30):", dataStore.getUint(GmxKeys.swapImpactFactorKey(M_WETH, false)));
        console.log("swapImpactExponent (1e30):", dataStore.getUint(GmxKeys.swapImpactExponentFactorKey(M_WETH)));
        console.log("swapFeeFactor improved (1e30):", dataStore.getUint(GmxKeys.swapFeeFactorKey(M_WETH, true)));
        console.log("swapFeeFactor not-improved (1e30):", dataStore.getUint(GmxKeys.swapFeeFactorKey(M_WETH, false)));
        console.log("swapImpactPool WETH (wei):", dataStore.getUint(GmxKeys.swapImpactPoolAmountKey(M_WETH, GmxArbitrumAddresses.WETH)));
        console.log("virtualMarketId M_WETH:");
        console.logBytes32(dataStore.getBytes32(GmxKeys.virtualMarketIdKey(M_WETH)));
        console.log("--- M_USDC 0x70d95587 ---");
        console.log("reserveFactor long:", dataStore.getUint(GmxKeys.reserveFactorKey(M_USDC, true)));
        console.log("reserveFactor short:", dataStore.getUint(GmxKeys.reserveFactorKey(M_USDC, false)));
        console.log("oiReserveFactor long:", dataStore.getUint(GmxKeys.openInterestReserveFactorKey(M_USDC, true)));
        console.log("oiReserveFactor short:", dataStore.getUint(GmxKeys.openInterestReserveFactorKey(M_USDC, false)));
        console.log("maxOpenInterest long (1e30):", dataStore.getUint(GmxKeys.maxOpenInterestKey(M_USDC, true)));
        console.log("maxOpenInterest short (1e30):", dataStore.getUint(GmxKeys.maxOpenInterestKey(M_USDC, false)));
        console.log("poolRaw WETH (wei):", _poolRaw(M_USDC, GmxArbitrumAddresses.WETH));
        console.log("poolRaw USDC (units):", _poolRaw(M_USDC, GmxArbitrumAddresses.USDC));
        console.log("oiUsd long (1e30):", _oiUsd(M_USDC, true));
        console.log("oiUsd short (1e30):", _oiUsd(M_USDC, false));
        console.log("swapImpactFactor + (1e30):", dataStore.getUint(GmxKeys.swapImpactFactorKey(M_USDC, true)));
        console.log("swapImpactFactor - (1e30):", dataStore.getUint(GmxKeys.swapImpactFactorKey(M_USDC, false)));
        console.log("swapImpactExponent (1e30):", dataStore.getUint(GmxKeys.swapImpactExponentFactorKey(M_USDC)));
        console.log("swapFeeFactor improved (1e30):", dataStore.getUint(GmxKeys.swapFeeFactorKey(M_USDC, true)));
        console.log("swapFeeFactor not-improved (1e30):", dataStore.getUint(GmxKeys.swapFeeFactorKey(M_USDC, false)));
        console.log("swapImpactPool WETH (wei):", dataStore.getUint(GmxKeys.swapImpactPoolAmountKey(M_USDC, GmxArbitrumAddresses.WETH)));
        console.log("swapImpactPool USDC (units):", dataStore.getUint(GmxKeys.swapImpactPoolAmountKey(M_USDC, GmxArbitrumAddresses.USDC)));
        console.log("virtualMarketId M_USDC:");
        console.logBytes32(dataStore.getBytes32(GmxKeys.virtualMarketIdKey(M_USDC)));
        console.log("--- shared virtual inventory ---");
        bytes32 vtid = dataStore.getBytes32(GmxKeys.virtualTokenIdKey(GmxArbitrumAddresses.WETH));
        console.log("virtualTokenId WETH:");
        console.logBytes32(vtid);
        console.log("virtualInventoryForPositions (tokens, int256):");
        console.logInt(_virtualInventoryTokens());
        bytes32 vmUsdc = dataStore.getBytes32(GmxKeys.virtualMarketIdKey(M_USDC));
        if (vmUsdc != bytes32(0)) {
            console.log("virtualSwapInventory long (M_USDC vm):", dataStore.getUint(GmxKeys.virtualInventoryForSwapsKey(vmUsdc, true)));
            console.log("virtualSwapInventory short (M_USDC vm):", dataStore.getUint(GmxKeys.virtualInventoryForSwapsKey(vmUsdc, false)));
        }
        bytes32 vmWeth = dataStore.getBytes32(GmxKeys.virtualMarketIdKey(M_WETH));
        if (vmWeth != bytes32(0)) {
            console.log("virtualSwapInventory long (M_WETH vm):", dataStore.getUint(GmxKeys.virtualInventoryForSwapsKey(vmWeth, true)));
            console.log("virtualSwapInventory short (M_WETH vm):", dataStore.getUint(GmxKeys.virtualInventoryForSwapsKey(vmWeth, false)));
        }
    }

    // ------------------------------------------------------------------ test 1: size ladder
    // Each size gets TWO tests (single / split) on a pristine fork, because
    // the single trade's OI change would contaminate the split's measurement.
    // Collateral is 10x (size/10 in ETH); users are topped up inside the test.

    function _collateralFor(uint256 sizeUsd) internal view returns (uint256) {
        return sizeUsd / 10 / entryPx;
    }

    function _logSplitResult(string memory label, bool openedUsdc, int256 pUsdc, bool openedWeth, int256 pWeth, bool okWeth, bytes memory retWeth) internal {
        console.log(label);
        console.log("  USDC half opened:", openedUsdc);
        console.log("  USDC half pendingImpactUsd (1e30):");
        console.logInt(pUsdc);
        console.log("  WETH half opened:", openedWeth);
        console.log("  WETH half pendingImpactUsd (1e30):");
        console.logInt(pWeth);
        console.log("  WETH half total pendingImpactUsd (1e30):");
        console.logInt(pUsdc + pWeth);
        if (!openedWeth) { console.log("  WETH half execute ok:", okWeth); _logRevert(retWeth); }
    }

    function test_S100k_Single() public {
        vm.deal(userA, 2000 ether);
        (bool opened, int256 p, bool ok, bytes memory ret) = _tryOpenShort(M_USDC, userA, 100_000e30, _collateralFor(100_000e30));
        console.log("S100k single opened:", opened, "execute ok:", ok);
        console.log("S100k single pendingImpactUsd (1e30):");
        console.logInt(p);
        if (!opened) _logRevert(ret);
    }

    function test_X100k_Split() public {
        vm.deal(userC, 2000 ether);
        (bool o1, int256 p1, , ) = _tryOpenShort(M_USDC, userC, 50_000e30, _collateralFor(50_000e30));
        (bool o2, int256 p2, bool ok2, bytes memory ret2) = _tryOpenShort(M_WETH, userC, 50_000e30, _collateralFor(50_000e30));
        _logSplitResult("X100k split", o1, p1, o2, p2, ok2, ret2);
    }

    function test_S200k_Single() public {
        vm.deal(userA, 2000 ether);
        (bool opened, int256 p, bool ok, bytes memory ret) = _tryOpenShort(M_USDC, userA, 200_000e30, _collateralFor(200_000e30));
        console.log("S200k single opened:", opened, "execute ok:", ok);
        console.log("S200k single pendingImpactUsd (1e30):");
        console.logInt(p);
        if (!opened) _logRevert(ret);
    }

    function test_X200k_Split() public {
        vm.deal(userC, 2000 ether);
        (bool o1, int256 p1, , ) = _tryOpenShort(M_USDC, userC, 100_000e30, _collateralFor(100_000e30));
        (bool o2, int256 p2, bool ok2, bytes memory ret2) = _tryOpenShort(M_WETH, userC, 100_000e30, _collateralFor(100_000e30));
        _logSplitResult("X200k split", o1, p1, o2, p2, ok2, ret2);
    }

    function test_S500k_Single() public {
        vm.deal(userA, 2000 ether);
        (bool opened, int256 p, bool ok, bytes memory ret) = _tryOpenShort(M_USDC, userA, 500_000e30, _collateralFor(500_000e30));
        console.log("S500k single opened:", opened, "execute ok:", ok);
        console.log("S500k single pendingImpactUsd (1e30):");
        console.logInt(p);
        if (!opened) _logRevert(ret);
    }

    function test_X500k_Split() public {
        vm.deal(userC, 2000 ether);
        (bool o1, int256 p1, , ) = _tryOpenShort(M_USDC, userC, 250_000e30, _collateralFor(250_000e30));
        (bool o2, int256 p2, bool ok2, bytes memory ret2) = _tryOpenShort(M_WETH, userC, 250_000e30, _collateralFor(250_000e30));
        _logSplitResult("X500k split", o1, p1, o2, p2, ok2, ret2);
    }

    function test_S1M_Single() public {
        vm.deal(userA, 2000 ether);
        (bool opened, int256 p, bool ok, bytes memory ret) = _tryOpenShort(M_USDC, userA, 1_000_000e30, _collateralFor(1_000_000e30));
        console.log("S1M single opened:", opened, "execute ok:", ok);
        console.log("S1M single pendingImpactUsd (1e30):");
        console.logInt(p);
        if (!opened) _logRevert(ret);
    }

    function test_X1M_Split() public {
        vm.deal(userC, 2000 ether);
        (bool o1, int256 p1, , ) = _tryOpenShort(M_USDC, userC, 500_000e30, _collateralFor(500_000e30));
        (bool o2, int256 p2, bool ok2, bytes memory ret2) = _tryOpenShort(M_WETH, userC, 500_000e30, _collateralFor(500_000e30));
        _logSplitResult("X1M split", o1, p1, o2, p2, ok2, ret2);
    }

    function test_S2M_Single() public {
        vm.deal(userA, 2000 ether);
        (bool opened, int256 p, bool ok, bytes memory ret) = _tryOpenShort(M_USDC, userA, 2_000_000e30, _collateralFor(2_000_000e30));
        console.log("S2M single opened:", opened, "execute ok:", ok);
        console.log("S2M single pendingImpactUsd (1e30):");
        console.logInt(p);
        if (!opened) _logRevert(ret);
    }

    function test_X2M_Split() public {
        vm.deal(userC, 2000 ether);
        (bool o1, int256 p1, , ) = _tryOpenShort(M_USDC, userC, 1_000_000e30, _collateralFor(1_000_000e30));
        (bool o2, int256 p2, bool ok2, bytes memory ret2) = _tryOpenShort(M_WETH, userC, 1_000_000e30, _collateralFor(1_000_000e30));
        _logSplitResult("X2M split", o1, p1, o2, p2, ok2, ret2);
    }

    function test_S4M_Single() public {
        vm.deal(userA, 2000 ether);
        (bool opened, int256 p, bool ok, bytes memory ret) = _tryOpenShort(M_USDC, userA, 4_000_000e30, _collateralFor(4_000_000e30));
        console.log("S4M single opened:", opened, "execute ok:", ok);
        console.log("S4M single pendingImpactUsd (1e30):");
        console.logInt(p);
        if (!opened) _logRevert(ret);
    }

    function test_X4M_Split() public {
        vm.deal(userC, 2000 ether);
        (bool o1, int256 p1, , ) = _tryOpenShort(M_USDC, userC, 2_000_000e30, _collateralFor(2_000_000e30));
        (bool o2, int256 p2, bool ok2, bytes memory ret2) = _tryOpenShort(M_WETH, userC, 2_000_000e30, _collateralFor(2_000_000e30));
        _logSplitResult("X4M split", o1, p1, o2, p2, ok2, ret2);
    }

    function test_S8M_Single() public {
        vm.deal(userA, 2000 ether);
        (bool opened, int256 p, bool ok, bytes memory ret) = _tryOpenShort(M_USDC, userA, 8_000_000e30, _collateralFor(8_000_000e30));
        console.log("S8M single opened:", opened, "execute ok:", ok);
        console.log("S8M single pendingImpactUsd (1e30):");
        console.logInt(p);
        if (!opened) _logRevert(ret);
    }

    function test_X8M_Split() public {
        vm.deal(userC, 2000 ether);
        (bool o1, int256 p1, , ) = _tryOpenShort(M_USDC, userC, 4_000_000e30, _collateralFor(4_000_000e30));
        (bool o2, int256 p2, bool ok2, bytes memory ret2) = _tryOpenShort(M_WETH, userC, 4_000_000e30, _collateralFor(4_000_000e30));
        _logSplitResult("X8M split", o1, p1, o2, p2, ok2, ret2);
    }

    function test_S12M_Single() public {
        vm.deal(userA, 2000 ether);
        (bool opened, int256 p, bool ok, bytes memory ret) = _tryOpenShort(M_USDC, userA, 12_000_000e30, _collateralFor(12_000_000e30));
        console.log("S12M single opened:", opened, "execute ok:", ok);
        console.log("S12M single pendingImpactUsd (1e30):");
        console.logInt(p);
        if (!opened) _logRevert(ret);
    }

    function test_X12M_Split() public {
        vm.deal(userC, 2000 ether);
        (bool o1, int256 p1, , ) = _tryOpenShort(M_USDC, userC, 6_000_000e30, _collateralFor(6_000_000e30));
        (bool o2, int256 p2, bool ok2, bytes memory ret2) = _tryOpenShort(M_WETH, userC, 6_000_000e30, _collateralFor(6_000_000e30));
        _logSplitResult("X12M split", o1, p1, o2, p2, ok2, ret2);
    }

    function test_S16M_Single() public {
        vm.deal(userA, 2000 ether);
        (bool opened, int256 p, bool ok, bytes memory ret) = _tryOpenShort(M_USDC, userA, 16_000_000e30, _collateralFor(16_000_000e30));
        console.log("S16M single opened:", opened, "execute ok:", ok);
        console.log("S16M single pendingImpactUsd (1e30):");
        console.logInt(p);
        if (!opened) _logRevert(ret);
    }

    function test_X16M_Split() public {
        vm.deal(userC, 2000 ether);
        (bool o1, int256 p1, , ) = _tryOpenShort(M_USDC, userC, 8_000_000e30, _collateralFor(8_000_000e30));
        (bool o2, int256 p2, bool ok2, bytes memory ret2) = _tryOpenShort(M_WETH, userC, 8_000_000e30, _collateralFor(8_000_000e30));
        _logSplitResult("X16M split", o1, p1, o2, p2, ok2, ret2);
    }

    /// Binary search on the WETH leg: $4M opens, $6M does not. Probe $4.5M /
    /// $5M / $5.5M legs (split totals $9M / $10M / $11M). The USDC half is
    /// opened first so the WETH leg is the only variable.
    function test_X9M_Split() public {
        vm.deal(userC, 2000 ether);
        (bool o1, int256 p1, , ) = _tryOpenShort(M_USDC, userC, 4_500_000e30, _collateralFor(4_500_000e30));
        (bool o2, int256 p2, bool ok2, bytes memory ret2) = _tryOpenShort(M_WETH, userC, 4_500_000e30, _collateralFor(4_500_000e30));
        _logSplitResult("X9M split", o1, p1, o2, p2, ok2, ret2);
    }

    function test_X10M_Split() public {
        vm.deal(userC, 2000 ether);
        (bool o1, int256 p1, , ) = _tryOpenShort(M_USDC, userC, 5_000_000e30, _collateralFor(5_000_000e30));
        (bool o2, int256 p2, bool ok2, bytes memory ret2) = _tryOpenShort(M_WETH, userC, 5_000_000e30, _collateralFor(5_000_000e30));
        _logSplitResult("X10M split", o1, p1, o2, p2, ok2, ret2);
    }

    function test_X11M_Split() public {
        vm.deal(userC, 2000 ether);
        (bool o1, int256 p1, , ) = _tryOpenShort(M_USDC, userC, 5_500_000e30, _collateralFor(5_500_000e30));
        (bool o2, int256 p2, bool ok2, bytes memory ret2) = _tryOpenShort(M_WETH, userC, 5_500_000e30, _collateralFor(5_500_000e30));
        _logSplitResult("X11M split", o1, p1, o2, p2, ok2, ret2);
    }

    /// Same-size WETH LONG leg ($6M): distinguishes a short-specific reserve
    /// formula (reservedUsd = OI in USD) from a shared cap such as max OI.
    function test_WethLong6M() public {
        vm.deal(userB, 2000 ether);
        (bool opened, int256 p, bool ok, bytes memory ret) = _tryOpenLong(M_WETH, userB, 6_000_000e30, _collateralFor(6_000_000e30));
        console.log("WETH $6M LONG opened:", opened, "execute ok:", ok);
        console.log("WETH $6M LONG pendingImpactUsd (1e30):");
        console.logInt(p);
        if (!opened) _logRevert(ret);
    }

    /// Threshold refinement: $5.25M WETH leg (split total $10.5M).
    function test_X105M_Split() public {
        vm.deal(userC, 2000 ether);
        (bool o1, int256 p1, , ) = _tryOpenShort(M_USDC, userC, 5_250_000e30, _collateralFor(5_250_000e30));
        (bool o2, int256 p2, bool ok2, bytes memory ret2) = _tryOpenShort(M_WETH, userC, 5_250_000e30, _collateralFor(5_250_000e30));
        _logSplitResult("X10.5M split", o1, p1, o2, p2, ok2, ret2);
    }

    /// Diagnose the XMax failure: open the USDC half first, then simulate the
    /// $5,369,421 WETH leg to see the exact reserve args in that state.
    function test_DiagSimulateXMax() public {
        vm.deal(userC, 2000 ether);
        (bool o1, int256 p1, , ) = _tryOpenShort(M_USDC, userC, 5_369_421e30, _collateralFor(5_369_421e30));
        console.log("diag USDC half opened:", o1);
        console.log("diag USDC half pendingImpactUsd (1e30):");
        console.logInt(p1);
        console.log("diag M_WETH short OI before WETH leg (1e30):", _oiUsd(M_WETH, false));
        console.log("diag M_WETH poolRaw WETH (wei):", _poolRaw(M_WETH, GmxArbitrumAddresses.WETH));
        bytes32 key = _createIncrease(M_WETH, GmxArbitrumAddresses.WETH, userC, false, _collateralFor(5_369_421e30), 5_369_421e30, STD_FEE);
        vm.prank(GmxArbitrumAddresses.EXCHANGE_ROUTER);
        oracle.clearAllPrices();
        SimPrices memory sp;
        address[] memory toks = new address[](4);
        toks[0] = GmxArbitrumAddresses.WETH;
        toks[1] = GmxArbitrumAddresses.USDC;
        toks[2] = WSTETH;
        toks[3] = USDE;
        Price.Props[] memory pxs = new Price.Props[](4);
        pxs[0] = Price.Props({min: entryPx, max: entryPx});
        pxs[1] = Price.Props({min: USDC_PX, max: USDC_PX});
        pxs[2] = Price.Props({min: wstethPx, max: wstethPx});
        pxs[3] = Price.Props({min: usdePx, max: usdePx});
        sp.primaryTokens = toks;
        sp.primaryPrices = pxs;
        sp.minTimestamp = block.timestamp;
        sp.maxTimestamp = block.timestamp;
        vm.txGasPrice(GAS_PRICE);
        vm.prank(keeper);
        (bool ok, bytes memory ret) = address(orderHandler).call(
            abi.encodeWithSelector(
                bytes4(keccak256("simulateExecuteOrder(bytes32,(address[],(uint256,uint256)[],uint256,uint256))")),
                key,
                sp
            )
        );
        console.log("diag simulate WETH leg ok:", ok);
        if (!ok) {
            _logRevert(ret);
            if (ret.length >= 68) {
                (uint256 a, uint256 b) = abi.decode(_slice(ret, 4), (uint256, uint256));
                console.log("  diag reservedUsd (1e30):", a);
                console.log("  diag maxReservedUsd (1e30):", b);
            }
        }
    }

    /// Max-size split: computed WETH-leg cap = maxReservedUsd - current short OI
    /// = $6,156,982.88 - $787,561.73 = $5,369,421.15 (from the
    /// InsufficientReserveForOpenInterest args in test_DiagSimulateWethShort55M).
    /// A $5,369,421 leg FAILS in the split sequence by a $24.53 margin
    /// (test_DiagSimulateXMax: reserved $6,156,982.73 vs max $6,156,958.20),
    /// so the practical max leg is ~$5,369,397. Use $5,369,000 legs
    /// (total $10,738,000) — $421 of headroom.
    function test_SMax_Single() public {
        vm.deal(userA, 2000 ether);
        (bool opened, int256 p, bool ok, bytes memory ret) = _tryOpenShort(M_USDC, userA, 10_738_000e30, _collateralFor(10_738_000e30));
        console.log("Smax single opened:", opened, "execute ok:", ok);
        console.log("Smax single pendingImpactUsd (1e30):");
        console.logInt(p);
        if (!opened) _logRevert(ret);
    }

    function test_XMax_Split() public {
        vm.deal(userC, 2000 ether);
        (bool o1, int256 p1, , ) = _tryOpenShort(M_USDC, userC, 5_369_000e30, _collateralFor(5_369_000e30));
        (bool o2, int256 p2, bool ok2, bytes memory ret2) = _tryOpenShort(M_WETH, userC, 5_369_000e30, _collateralFor(5_369_000e30));
        _logSplitResult("Xmax split", o1, p1, o2, p2, ok2, ret2);
    }

    /// Diagnose the exact rejection: simulateExecuteOrder does NOT swallow the
    /// error (unlike executeOrder, which cancels the order and returns ok),
    /// so its revert data names the check and its (actual, max) args.
    /// SimulatePricesParams mirrors gmx-synthetics OracleUtils.sol:27
    /// (primaryTokens, primaryPrices, minTimestamp, maxTimestamp).
    struct SimPrices {
        address[] primaryTokens;
        Price.Props[] primaryPrices;
        uint256 minTimestamp;
        uint256 maxTimestamp;
    }

    function test_DiagSimulateWethShort55M() public {
        vm.deal(userC, 2000 ether);
        bytes32 key = _createIncrease(M_WETH, GmxArbitrumAddresses.WETH, userC, false, _collateralFor(5_500_000e30), 5_500_000e30, STD_FEE);
        // setUp() already set primary prices; simulated prices are set via
        // setPrimaryPrice too, which reverts PriceAlreadySet if set twice.
        // Clear first so the simulation can set its own.
        vm.prank(GmxArbitrumAddresses.EXCHANGE_ROUTER);
        oracle.clearAllPrices();
        SimPrices memory sp;
        address[] memory toks = new address[](4);
        toks[0] = GmxArbitrumAddresses.WETH;
        toks[1] = GmxArbitrumAddresses.USDC;
        toks[2] = WSTETH;
        toks[3] = USDE;
        Price.Props[] memory pxs = new Price.Props[](4);
        pxs[0] = Price.Props({min: entryPx, max: entryPx});
        pxs[1] = Price.Props({min: USDC_PX, max: USDC_PX});
        pxs[2] = Price.Props({min: wstethPx, max: wstethPx});
        pxs[3] = Price.Props({min: usdePx, max: usdePx});
        sp.primaryTokens = toks;
        sp.primaryPrices = pxs;
        sp.minTimestamp = block.timestamp;
        sp.maxTimestamp = block.timestamp;
        vm.txGasPrice(GAS_PRICE);
        vm.prank(keeper);
        (bool ok, bytes memory ret) = address(orderHandler).call(
            abi.encodeWithSelector(
                bytes4(keccak256("simulateExecuteOrder(bytes32,(address[],(uint256,uint256)[],uint256,uint256))")),
                key,
                sp
            )
        );
        console.log("simulate $5.5M WETH short ok:", ok);
        if (!ok) {
            console.log("simulate revert data length:", ret.length);
            _logRevert(ret);
            if (ret.length >= 100) {
                (uint256 a, uint256 b, uint256 c) = abi.decode(_slice(ret, 4), (uint256, uint256, uint256));
                console.log("  revert arg0:", a);
                console.log("  revert arg1:", b);
                console.log("  revert arg2:", c);
            }
            console.log("simulate revert raw:");
            console.logBytes(ret);
        }
    }

    // ------------------------------------------------------------------ test 2: virtual-inventory shift
    // Code says the charged impact is min(real, virtual) when real < 0, so a
    // shift can only make a trade MORE expensive, never cheaper. These tests
    // measure it anyway. Net = (control cost - shifted cost) - WETH leg cost,
    // where the WETH leg cost is the full round-trip ETH balance change
    // (open fee + close fee + net impact + keeper payments).

    function test_V0_ControlUsdcShort100k() public {
        vm.deal(userA, 2000 ether);
        (bool opened, int256 p, , ) = _tryOpenShort(M_USDC, userA, 100_000e30, _collateralFor(100_000e30));
        console.log("V0 control opened:", opened);
        console.log("V0 control $100k USDC short pendingImpactUsd (1e30):");
        console.logInt(p);
        console.log("V0 virtualInventory (tokens):");
        console.logInt(_virtualInventoryTokens());
    }

    function test_V1_ShiftShortThenUsdc() public {
        vm.deal(userA, 2000 ether);
        vm.deal(userB, 2000 ether);
        int256 vBefore = _virtualInventoryTokens();
        uint256 ethBefore = userB.balance;
        (bool openedW, int256 pW, bool okW, bytes memory retW) = _tryOpenShort(M_WETH, userB, 2_000_000e30, _collateralFor(2_000_000e30));
        console.log("V1 WETH $2M SHORT opened:", openedW, "execute ok:", okW);
        console.log("V1 WETH leg pendingImpactUsd (1e30):");
        console.logInt(pW);
        if (!openedW) _logRevert(retW);
        int256 vAfterOpen = _virtualInventoryTokens();
        console.log("V1 virtualInventory before (tokens):");
        console.logInt(vBefore);
        console.log("V1 virtualInventory after WETH open (tokens):");
        console.logInt(vAfterOpen);
        (bool openedU, int256 pU, , ) = _tryOpenShort(M_USDC, userA, 100_000e30, _collateralFor(100_000e30));
        console.log("V1 USDC $100k SHORT opened:", openedU);
        console.log("V1 USDC $100k SHORT pendingImpactUsd (1e30):");
        console.logInt(pU);
        // Close the WETH leg and measure its full round-trip cost from balances.
        // Closing a short on a short-heavy market improves the balance (0.04%).
        int256 closeImpact = _closeShortWeth(M_WETH, userB, 2_000_000e30, true);
        uint256 ethAfter = userB.balance;
        console.log("V1 WETH leg close totalImpactUsd (1e30):");
        console.logInt(closeImpact);
        console.log("V1 WETH leg round-trip ETH cost (wei):", ethBefore - ethAfter);
        console.log("V1 WETH leg round-trip USD cost (1e30):", (ethBefore - ethAfter) * entryPx);
        console.log("V1 virtualInventory after WETH close (tokens):");
        console.logInt(_virtualInventoryTokens());
    }

    function test_V2_ShiftLongThenUsdc() public {
        vm.deal(userA, 2000 ether);
        vm.deal(userB, 2000 ether);
        int256 vBefore = _virtualInventoryTokens();
        uint256 ethBefore = userB.balance;
        (bool openedW, int256 pW, bool okW, bytes memory retW) = _tryOpenLong(M_WETH, userB, 2_000_000e30, _collateralFor(2_000_000e30));
        console.log("V2 WETH $2M LONG opened:", openedW, "execute ok:", okW);
        console.log("V2 WETH leg pendingImpactUsd (1e30):");
        console.logInt(pW);
        if (!openedW) _logRevert(retW);
        int256 vAfterOpen = _virtualInventoryTokens();
        console.log("V2 virtualInventory before (tokens):");
        console.logInt(vBefore);
        console.log("V2 virtualInventory after WETH open (tokens):");
        console.logInt(vAfterOpen);
        (bool openedU, int256 pU, , ) = _tryOpenShort(M_USDC, userA, 100_000e30, _collateralFor(100_000e30));
        console.log("V2 USDC $100k SHORT opened:", openedU);
        console.log("V2 USDC $100k SHORT pendingImpactUsd (1e30):");
        console.logInt(pU);
        // Closing the long removes $2M of long OI: the market goes from
        // long-heavy (diff $1.76M) back to short-heavy (diff $0.24M), so the
        // close IMPROVES the balance -> improved fee 0.04%. (Passing
        // improved=false here overstated the close fee by $400 and made the
        // close impact read +$400; the true close impact is ~$0.)
        int256 closeImpact = _closeLongWeth(M_WETH, userB, 2_000_000e30, true);
        uint256 ethAfter = userB.balance;
        console.log("V2 WETH leg close totalImpactUsd (1e30):");
        console.logInt(closeImpact);
        console.log("V2 WETH leg round-trip ETH cost (wei):", ethBefore - ethAfter);
        console.log("V2 WETH leg round-trip USD cost (1e30):", (ethBefore - ethAfter) * entryPx);
        console.log("V2 virtualInventory after WETH close (tokens):");
        console.logInt(_virtualInventoryTokens());
    }

    // ------------------------------------------------------------------ test 3: swaps
    // Swap order params mirror the repo's SwapOrder.ts test: swapPath is a list
    // of MARKET tokens, market = address(0), sizeDeltaUsd = 0.

    function _createSwap(address marketToken, address tokenIn, address account, uint256 amountIn, uint256 fee) internal returns (bytes32) {
        address[] memory path = new address[](1);
        path[0] = marketToken;
        IExchangeRouter.CreateOrderParams memory params = IExchangeRouter.CreateOrderParams({
            addresses: IExchangeRouter.CreateOrderParamsAddresses({
                receiver: account,
                cancellationReceiver: account,
                callbackContract: address(0),
                uiFeeReceiver: address(0),
                market: address(0),
                initialCollateralToken: tokenIn,
                swapPath: path
            }),
            numbers: IExchangeRouter.CreateOrderParamsNumbers({
                sizeDeltaUsd: 0,
                initialCollateralDeltaAmount: amountIn,
                triggerPrice: 0,
                acceptablePrice: 0,
                executionFee: fee,
                callbackGasLimit: 0,
                minOutputAmount: 0,
                validFromTime: 0
            }),
            orderType: IExchangeRouter.OrderType.MarketSwap,
            decreasePositionSwapType: IExchangeRouter.DecreasePositionSwapType.NoSwap,
            isLong: false,
            shouldUnwrapNativeToken: true,
            autoCancel: false,
            referralCode: bytes32(0),
            dataList: new bytes32[](0)
        });
        vm.txGasPrice(GAS_PRICE);
        vm.startPrank(account);
        if (tokenIn == GmxArbitrumAddresses.WETH) {
            exchangeRouter.sendWnt{value: amountIn + fee}(GmxArbitrumAddresses.ORDER_VAULT, amountIn + fee);
        } else {
            IERC20(tokenIn).approve(address(exchangeRouter), amountIn);
            IERC20(tokenIn).approve(GmxArbitrumAddresses.ROUTER, amountIn);
            exchangeRouter.sendTokens(tokenIn, GmxArbitrumAddresses.ORDER_VAULT, amountIn);
            exchangeRouter.sendWnt{value: fee}(GmxArbitrumAddresses.ORDER_VAULT, fee);
        }
        bytes32 key = exchangeRouter.createOrder{value: 0}(params);
        vm.stopPrank();
        return key;
    }

    /// Execute a swap order (low-level, so a rejection is captured) and measure
    /// the native-ETH output. amountOutWei = (ethAfter - ethBefore) - fee + keeperGain.
    function _execSwapMeasure(address marketToken, address tokenIn, address account, uint256 amountIn)
        internal
        returns (uint256 amountOutWei, bool ok, bytes memory retData)
    {
        bytes32 key = _createSwap(marketToken, tokenIn, account, amountIn, STD_FEE);
        uint256 ethBefore = account.balance;
        uint256 keeperBefore = keeper.balance;
        _setPricesAll();
        vm.txGasPrice(GAS_PRICE);
        vm.prank(keeper);
        (ok, retData) = address(orderHandler).call(
            abi.encodeWithSelector(IOrderHandler.executeOrder.selector, key, _emptyOracleParams())
        );
        if (ok) {
            uint256 keeperGain = keeper.balance - keeperBefore;
            amountOutWei = (account.balance - ethBefore) - STD_FEE + keeperGain;
        }
    }

    /// Virtual swap inventory (combined pools) for M_USDC's virtual market.
    function _virtualSwapInventory() internal view returns (uint256 longAmt, uint256 shortAmt) {
        bytes32 vmId = dataStore.getBytes32(GmxKeys.virtualMarketIdKey(M_USDC));
        longAmt = dataStore.getUint(GmxKeys.virtualInventoryForSwapsKey(vmId, true));
        shortAmt = dataStore.getUint(GmxKeys.virtualInventoryForSwapsKey(vmId, false));
    }

    /// Baseline: swap USDC -> WETH $100k via M_USDC. Impact is measured from
    /// the output: impactUsd = amountOutUsd - amountInUsd * (1 - swapFeeFactor).
    /// The swap worsens the pool imbalance (diff grows) -> not-improved fee 0.07%.
    function test_Swap_Baseline() public {
        vm.deal(userA, 2000 ether);
        deal(GmxArbitrumAddresses.USDC, userA, 100_000e6);
        (uint256 vLongBefore, uint256 vShortBefore) = _virtualSwapInventory();
        console.log("Swap baseline virtualSwapInventory long (wei):", vLongBefore);
        console.log("Swap baseline virtualSwapInventory short (units):", vShortBefore);
        (uint256 amountOutWei, bool ok, bytes memory ret) = _execSwapMeasure(M_USDC, GmxArbitrumAddresses.USDC, userA, 100_000e6);
        console.log("Swap baseline execute ok:", ok);
        if (!ok) _logRevert(ret);
        int256 amountOutUsd = int256(amountOutWei) * int256(entryPx);
        int256 amountInUsd = int256(100_000e6) * int256(USDC_PX);
        uint256 feeNotImproved = dataStore.getUint(GmxKeys.swapFeeFactorKey(M_USDC, false));
        uint256 feeImproved = dataStore.getUint(GmxKeys.swapFeeFactorKey(M_USDC, true));
        int256 impactNotImproved = amountOutUsd - amountInUsd * (int256(1e30) - int256(feeNotImproved)) / int256(1e30);
        int256 impactImproved = amountOutUsd - amountInUsd * (int256(1e30) - int256(feeImproved)) / int256(1e30);
        console.log("Swap baseline amountOut (wei):", amountOutWei);
        console.log("Swap baseline amountOutUsd (1e30):");
        console.logInt(amountOutUsd);
        console.log("Swap baseline impactUsd if fee 0.07% (1e30):");
        console.logInt(impactNotImproved);
        console.log("Swap baseline impactUsd if fee 0.05% (1e30):");
        console.logInt(impactImproved);
        (uint256 vLongAfter, uint256 vShortAfter) = _virtualSwapInventory();
        console.log("Swap baseline virtualSwapInventory long after (wei):", vLongAfter);
        console.log("Swap baseline virtualSwapInventory short after (units):", vShortAfter);
    }

    /// WETH -> WETH $10k via M_WETH: the degenerate swap. M_WETH has swap
    /// factors 0 / 0 and fee factors 0 / 0 and NO virtualMarketId, so this
    /// should execute at exactly $0 impact + $0 fee (only the execution fee).
    function test_Swap_WethWeth() public {
        vm.deal(userB, 2000 ether);
        (uint256 vLongBefore, uint256 vShortBefore) = _virtualSwapInventory();
        // The swap ORDER CREATION itself reverts (InvalidSwapMarket) — a
        // single-token market is not a valid swap market. Capture it.
        bytes32 key;
        bool createOk = true;
        bytes memory createRet;
        try this._createSwapExternal(M_WETH, GmxArbitrumAddresses.WETH, userB, 10_000e30 / entryPx) returns (bytes32 k) {
            key = k;
        } catch (bytes memory r) {
            createOk = false;
            createRet = r;
        }
        console.log("Swap WETH->WETH create ok:", createOk);
        if (!createOk) _logRevert(createRet);
        if (createOk) {
            uint256 ethBefore = userB.balance;
            uint256 keeperBefore = keeper.balance;
            _setPricesAll();
            vm.txGasPrice(GAS_PRICE);
            vm.prank(keeper);
            (bool ok, bytes memory ret) = address(orderHandler).call(
                abi.encodeWithSelector(IOrderHandler.executeOrder.selector, key, _emptyOracleParams())
            );
            console.log("Swap WETH->WETH execute ok:", ok);
            if (!ok) _logRevert(ret);
            if (ok) {
                uint256 keeperGain = keeper.balance - keeperBefore;
                uint256 amountOutWei = (userB.balance - ethBefore) - STD_FEE + keeperGain;
                console.log("Swap WETH->WETH amountIn (wei):", 10_000e30 / entryPx);
                console.log("Swap WETH->WETH amountOut (wei):", amountOutWei);
            }
        }
        (uint256 vLongAfter, uint256 vShortAfter) = _virtualSwapInventory();
        console.log("Swap WETH->WETH virtualSwapInventory long before/after (wei):", vLongBefore, vLongAfter);
        console.log("Swap WETH->WETH virtualSwapInventory short before/after (units):", vShortBefore, vShortAfter);
    }

    /// USDC -> WETH $50k via M_WETH: USDC is not a token of M_WETH. This must
    /// revert — it proves a USDC/WETH swap cannot be split onto the cheap market.
    function test_Swap_WrongPair() public {
        vm.deal(userC, 2000 ether);
        deal(GmxArbitrumAddresses.USDC, userC, 50_000e6);
        bytes32 key;
        bool createOk = true;
        bytes memory createRet;
        try this._createSwapExternal(M_WETH, GmxArbitrumAddresses.USDC, userC, 50_000e6) returns (bytes32 k) {
            key = k;
        } catch (bytes memory r) {
            createOk = false;
            createRet = r;
        }
        console.log("Swap wrong-pair create ok:", createOk);
        if (!createOk) _logRevert(createRet);
        if (createOk) {
            _setPricesAll();
            vm.txGasPrice(GAS_PRICE);
            vm.prank(keeper);
            (bool ok, bytes memory ret) = address(orderHandler).call(
                abi.encodeWithSelector(IOrderHandler.executeOrder.selector, key, _emptyOracleParams())
            );
            console.log("Swap wrong-pair execute ok:", ok);
            if (!ok) _logRevert(ret);
        }
    }

    /// External wrapper so the wrong-pair create can be try/caught.
    function _createSwapExternal(address marketToken, address tokenIn, address account, uint256 amountIn) external returns (bytes32) {
        return _createSwap(marketToken, tokenIn, account, amountIn, STD_FEE);
    }

    /// Multi-hop USDC -> wstETH: [M_USDC, M_WSTETH] vs the same path with an
    /// M_WETH (WETH -> WETH) hop inserted. Output is wstETH; measured by balance.
    function _createSwapPath(address[] memory path, address tokenIn, address account, uint256 amountIn) internal returns (bytes32) {
        IExchangeRouter.CreateOrderParams memory params = IExchangeRouter.CreateOrderParams({
            addresses: IExchangeRouter.CreateOrderParamsAddresses({
                receiver: account,
                cancellationReceiver: account,
                callbackContract: address(0),
                uiFeeReceiver: address(0),
                market: address(0),
                initialCollateralToken: tokenIn,
                swapPath: path
            }),
            numbers: IExchangeRouter.CreateOrderParamsNumbers({
                sizeDeltaUsd: 0,
                initialCollateralDeltaAmount: amountIn,
                triggerPrice: 0,
                acceptablePrice: 0,
                executionFee: STD_FEE,
                callbackGasLimit: 0,
                minOutputAmount: 0,
                validFromTime: 0
            }),
            orderType: IExchangeRouter.OrderType.MarketSwap,
            decreasePositionSwapType: IExchangeRouter.DecreasePositionSwapType.NoSwap,
            isLong: false,
            shouldUnwrapNativeToken: false,
            autoCancel: false,
            referralCode: bytes32(0),
            dataList: new bytes32[](0)
        });
        vm.txGasPrice(GAS_PRICE);
        vm.startPrank(account);
        IERC20(tokenIn).approve(address(exchangeRouter), amountIn);
        IERC20(tokenIn).approve(GmxArbitrumAddresses.ROUTER, amountIn);
        exchangeRouter.sendTokens(tokenIn, GmxArbitrumAddresses.ORDER_VAULT, amountIn);
        exchangeRouter.sendWnt{value: STD_FEE}(GmxArbitrumAddresses.ORDER_VAULT, STD_FEE);
        bytes32 key = exchangeRouter.createOrder{value: 0}(params);
        vm.stopPrank();
        return key;
    }

    function test_Swap_MultiHop() public {
        vm.deal(userA, 2000 ether);
        vm.deal(userB, 2000 ether);
        deal(GmxArbitrumAddresses.USDC, userA, 100_000e6);
        deal(GmxArbitrumAddresses.USDC, userB, 100_000e6);
        // Baseline: [M_USDC, M_WSTETH].
        address[] memory path2 = new address[](2);
        path2[0] = M_USDC;
        path2[1] = M_WSTETH;
        bytes32 key2 = _createSwapPath(path2, GmxArbitrumAddresses.USDC, userA, 100_000e6);
        uint256 wstethBefore = IERC20(WSTETH).balanceOf(userA);
        _setPricesAll();
        vm.txGasPrice(GAS_PRICE);
        vm.prank(keeper);
        (bool ok2, bytes memory ret2) = address(orderHandler).call(
            abi.encodeWithSelector(IOrderHandler.executeOrder.selector, key2, _emptyOracleParams())
        );
        console.log("Swap multi-hop 2-hop execute ok:", ok2);
        if (!ok2) _logRevert(ret2);
        console.log("Swap multi-hop 2-hop wstETH out (wei):", IERC20(WSTETH).balanceOf(userA) - wstethBefore);
        // With an M_WETH hop inserted: [M_USDC, M_WETH, M_WSTETH].
        // Creation reverts (InvalidSwapMarket on the M_WETH hop) — capture it.
        address[] memory path3 = new address[](3);
        path3[0] = M_USDC;
        path3[1] = M_WETH;
        path3[2] = M_WSTETH;
        bytes32 key3;
        bool createOk3 = true;
        bytes memory createRet3;
        try this._createSwapPathExternal(path3, GmxArbitrumAddresses.USDC, userB, 100_000e6) returns (bytes32 k) {
            key3 = k;
        } catch (bytes memory r) {
            createOk3 = false;
            createRet3 = r;
        }
        console.log("Swap multi-hop 3-hop (M_WETH inserted) create ok:", createOk3);
        if (!createOk3) _logRevert(createRet3);
        if (createOk3) {
            uint256 wstethBefore3 = IERC20(WSTETH).balanceOf(userB);
            _setPricesAll();
            vm.txGasPrice(GAS_PRICE);
            vm.prank(keeper);
            (bool ok3, bytes memory ret3) = address(orderHandler).call(
                abi.encodeWithSelector(IOrderHandler.executeOrder.selector, key3, _emptyOracleParams())
            );
            console.log("Swap multi-hop 3-hop (M_WETH inserted) execute ok:", ok3);
            if (!ok3) _logRevert(ret3);
            if (ok3) console.log("Swap multi-hop 3-hop wstETH out (wei):", IERC20(WSTETH).balanceOf(userB) - wstethBefore3);
        }
    }

    /// External wrapper so a multi-hop swap create can be try/caught.
    function _createSwapPathExternal(address[] memory path, address tokenIn, address account, uint256 amountIn) external returns (bytes32) {
        return _createSwapPath(path, tokenIn, account, amountIn);
    }

    /// Virtual-shift for swaps: a large WETH -> WETH swap on M_WETH first
    /// (if it executes), then the USDC -> WETH $100k baseline swap. M_WETH has
    /// no virtualMarketId, so the cheap-market swap must NOT move the shared
    /// virtual swap inventory and must NOT change the baseline swap's impact.
    function test_Swap_VirtualShift() public {
        vm.deal(userA, 2000 ether);
        vm.deal(userB, 2000 ether);
        deal(GmxArbitrumAddresses.USDC, userA, 100_000e6);
        (uint256 vLongBefore, uint256 vShortBefore) = _virtualSwapInventory();
        // The WETH -> WETH swap creation reverts (InvalidSwapMarket) — capture
        // it and continue: the point is that the cheap market cannot be used
        // to move the shared virtual swap inventory at all.
        bool createOkW = true;
        bytes memory createRetW;
        try this._createSwapExternal(M_WETH, GmxArbitrumAddresses.WETH, userB, 1_000_000e30 / entryPx) returns (bytes32) {
        } catch (bytes memory r) {
            createOkW = false;
            createRetW = r;
        }
        console.log("Swap virtual-shift WETH->WETH $1M create ok:", createOkW);
        if (!createOkW) _logRevert(createRetW);
        (uint256 vLongMid, uint256 vShortMid) = _virtualSwapInventory();
        console.log("Swap virtual-shift virtual long before/after WETH swap (wei):", vLongBefore, vLongMid);
        console.log("Swap virtual-shift virtual short before/after WETH swap (units):", vShortBefore, vShortMid);
        (uint256 amountOutWei, bool ok, bytes memory ret) = _execSwapMeasure(M_USDC, GmxArbitrumAddresses.USDC, userA, 100_000e6);
        console.log("Swap virtual-shift USDC->WETH execute ok:", ok);
        if (!ok) _logRevert(ret);
        int256 amountOutUsd = int256(amountOutWei) * int256(entryPx);
        int256 amountInUsd = int256(100_000e6) * int256(USDC_PX);
        uint256 feeNotImproved = dataStore.getUint(GmxKeys.swapFeeFactorKey(M_USDC, false));
        int256 impact = amountOutUsd - amountInUsd * (int256(1e30) - int256(feeNotImproved)) / int256(1e30);
        console.log("Swap virtual-shift USDC->WETH amountOutUsd (1e30):");
        console.logInt(amountOutUsd);
        console.log("Swap virtual-shift USDC->WETH impactUsd if fee 0.07% (1e30):");
        console.logInt(impact);
    }
}
