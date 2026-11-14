// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// GMX lead G-P1-2 — price-impact / swap-path manipulation.
// Fork: Arbitrum, block 524054954 (fresh, 2026-11-14 ~11:10 WIB).
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

contract GP12PriceImpactTest is GmxForkHelpers {
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
        vm.createSelectFork("https://arb1.arbitrum.io/rpc", 524054954);
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

    // ------------------------------------------------------------------ test (a)

    /// (a1) Baseline: $100k SHORT on [WETH-USDC] alone. Market is short-heavy
    /// (diff -$1.55M), so the short worsens the imbalance -> negative impact.
    function test_A1_ShortUsdcOnly() public {
        int256 vBefore = _virtualInventoryTokens();
        int256 pending = _openShort(M_USDC, userA, 100_000e30, 10 ether);
        int256 vAfter = _virtualInventoryTokens();
        console.log("A1 pendingImpactUsd (1e30):");
        console.logInt(pending);
        console.log("A1 virtualInventory delta (tokens):");
        console.logInt(vAfter - vBefore);
        assertLt(pending, 0, "A1: short on short-heavy market should pay negative impact");
        // Sanity: impact must be material (> $10) and small vs size (< 2%).
        assertGt(-pending, 10e30, "A1: impact suspiciously small");
        assertLt(-pending, 2000e30, "A1: impact suspiciously large");
    }

    /// (a2) Same $100k SHORT on [WETH-WETH] alone. Same index token, same shared
    /// virtual inventory — but this market's impact factors are ~1e-15 (exponent 1.0).
    function test_A2_ShortWethOnly() public {
        int256 vBefore = _virtualInventoryTokens();
        int256 pending = _openShort(M_WETH, userB, 100_000e30, 10 ether);
        int256 vAfter = _virtualInventoryTokens();
        console.log("A2 pendingImpactUsd (1e30):");
        console.logInt(pending);
        console.log("A2 virtualInventory delta (tokens):");
        console.logInt(vAfter - vBefore);
        // The trade MUST still move the shared virtual inventory (it is the same
        // virtualTokenId); only the price charged for it differs.
        assertGt(vAfter - vBefore, 0, "A2: short must increase the shared virtual inventory");
    }

    /// (a3) Split: $50k SHORT on [WETH-USDC] + $50k SHORT on [WETH-WETH].
    /// Compare the TOTAL open impact with the single $100k trade in A1.
    function test_A3_SplitAcrossMarkets() public {
        int256 p1 = _openShort(M_USDC, userC, 50_000e30, 5 ether);
        int256 p2 = _openShort(M_WETH, userC, 50_000e30, 5 ether);
        int256 total = p1 + p2;
        console.log("A3 USDC half pendingImpactUsd (1e30):");
        console.logInt(p1);
        console.log("A3 WETH half pendingImpactUsd (1e30):");
        console.logInt(p2);
        console.log("A3 total pendingImpactUsd (1e30):");
        console.logInt(total);
        assertLt(total, 0, "A3: split trade should still pay some negative impact");
    }

    /// (a4) Control: same $100k SHORT on [WETH-USDC] as two sequential $50k
    /// increases of ONE position. Telescoping (impact is a state function of the
    /// OI imbalance) predicts the total equals the single-trade impact in A1.
    function test_A4_SameMarketSplitControl() public {
        int256 p1 = _openShort(M_USDC, userD, 50_000e30, 5 ether);
        // Second increase adds to the SAME position (same account/market/collateral/dir).
        bytes32 key2 = _createIncrease(M_USDC, GmxArbitrumAddresses.WETH, userD, false, 5 ether, 50_000e30, STD_FEE);
        _executeOrder(key2);
        assertEq(_positionSizeUsd(userD, M_USDC, GmxArbitrumAddresses.WETH, false), 100_000e30, "A4: position should be $100k");
        int256 total = _pendingImpactUsd(userD, M_USDC, GmxArbitrumAddresses.WETH, false);
        console.log("A4 first half pendingImpactUsd (1e30):");
        console.logInt(p1);
        console.log("A4 total pendingImpactUsd (1e30):");
        console.logInt(total);
        assertLt(total, 0, "A4: control trade should pay negative impact");
    }

    /// (a5) Split in the reverse order: [WETH-WETH] half first, then [WETH-USDC].
    /// The total must be ~the same as A3 (order-independence check).
    function test_A5_SplitReverseOrder() public {
        int256 p1 = _openShort(M_WETH, userE, 50_000e30, 5 ether);
        int256 p2 = _openShort(M_USDC, userE, 50_000e30, 5 ether);
        int256 total = p1 + p2;
        console.log("A5 WETH half pendingImpactUsd (1e30):");
        console.logInt(p1);
        console.log("A5 USDC half pendingImpactUsd (1e30):");
        console.logInt(p2);
        console.log("A5 total pendingImpactUsd (1e30):");
        console.logInt(total);
        assertLt(total, 0, "A5: reverse-order split should still pay some negative impact");
    }

    // ------------------------------------------------------------------ test (b)

    /// (b1) Leverage: same $100k SHORT on [WETH-USDC] at 2x / 10x / 50x.
    /// Impact is a function of sizeDeltaUsd and OI only — per-dollar impact must
    /// be leverage-independent if the formula has no leverage term.
    function test_B1_LeverageVsImpact() public {
        int256 p2x = _openShort(M_USDC, userA, 100_000e30, 50 ether);
        int256 p10x = _openShort(M_USDC, userB, 100_000e30, 10 ether);
        int256 p50x = _openShort(M_USDC, userC, 100_000e30, 2 ether);
        console.log("B1 2x pendingImpactUsd (1e30):");
        console.logInt(p2x);
        console.log("B1 10x pendingImpactUsd (1e30):");
        console.logInt(p10x);
        console.log("B1 50x pendingImpactUsd (1e30):");
        console.logInt(p50x);
        // All three open the same size against (nearly) the same OI state, so the
        // impacts must be within a few dollars of each other (drift: each trade
        // moves the OI, so later trades pay slightly more).
        assertLt(p2x, 0, "B1: 2x should pay negative impact");
        assertLt(p10x, 0, "B1: 10x should pay negative impact");
        assertLt(p50x, 0, "B1: 50x should pay negative impact");
    }

    /// (b2) Max leverage: $100k SHORT at true 200x ($500 collateral) and 500x
    /// ($200 collateral). The min-collateral check includes the full-close
    /// negative impact (capped at 0 if positive) and the open fee, so an
    /// over-leveraged open must be CANCELLED (market orders: _handleOrderError
    /// cancels on user errors, the outer executeOrder still returns ok=true).
    /// The test therefore checks the POSITION SIZE after execution, not ok.
    function test_B2_MaxLeverageBinds() public {
        // True 200x: $500 collateral; true 500x: $200 collateral (USD 1e30 / entryPx = wei).
        uint256 coll200 = 500e30 / entryPx;
        uint256 coll500 = 200e30 / entryPx;
        console.log("B2 coll200 wei:", coll200, "coll500 wei:", coll500);

        bytes32 key200 = _createIncrease(M_USDC, GmxArbitrumAddresses.WETH, userF, false, coll200, 100_000e30, STD_FEE);
        _setPricesAll();
        vm.txGasPrice(GAS_PRICE);
        vm.prank(keeper);
        (bool ok200, bytes memory ret200) = address(orderHandler).call(
            abi.encodeWithSelector(IOrderHandler.executeOrder.selector, key200, _emptyOracleParams())
        );
        uint256 size200 = _positionSizeUsd(userF, M_USDC, GmxArbitrumAddresses.WETH, false);
        console.log("B2 200x execute ok:", ok200, "position size (1e30):", size200);
        if (!ok200) console.logBytes4(bytes4(ret200));

        bytes32 key500 = _createIncrease(M_USDC, GmxArbitrumAddresses.WETH, userE, false, coll500, 100_000e30, STD_FEE);
        _setPricesAll();
        vm.txGasPrice(GAS_PRICE);
        vm.prank(keeper);
        (bool ok500, bytes memory ret500) = address(orderHandler).call(
            abi.encodeWithSelector(IOrderHandler.executeOrder.selector, key500, _emptyOracleParams())
        );
        uint256 size500 = _positionSizeUsd(userE, M_USDC, GmxArbitrumAddresses.WETH, false);
        console.log("B2 500x execute ok:", ok500, "position size (1e30):", size500);
        if (!ok500) console.logBytes4(bytes4(ret500));
    }

    // ------------------------------------------------------------------ test (d)

    /// (d1) Round trip: open $100k SHORT on [WETH-USDC], close it fully at the
    /// same price. Net impact paid = -(totalImpactUsd at close). The open stores
    /// negative impact at the NEGATIVE factor; the close earns it back at the
    /// POSITIVE factor (clamped <= negative factor), so the round trip must LOSE
    /// money (the pool's take) — a net GAIN here would be a harvestable loop.
    /// Measurement: totalImpactUsd = payout - collateralBefore + closeFee, where
    /// payout = userGain + keeperGain - fee (balances snapshotted AFTER the
    /// decrease order is created, so the escrowed fee is excluded), collateralBefore
    /// is the position's actual collateral after the open fee, and closeFee is the
    /// live position fee (0.04% here — the close improves the balance).
    function test_D1_RoundTripShort() public {
        int256 pendingOpen = _openShort(M_USDC, userA, 100_000e30, 10 ether);
        console.log("D1 open pendingImpactUsd (1e30):");
        console.logInt(pendingOpen);

        uint256 collBeforeWei = _positionCollateral(userA, M_USDC, GmxArbitrumAddresses.WETH, false);
        uint256 feeFactor = _positionFeeFactor(M_USDC, true);
        int256 closeFeeUsd = int256(100_000e30 * feeFactor / 1e30);

        bytes32 decKey = _createDecrease(M_USDC, GmxArbitrumAddresses.WETH, userA, false, 100_000e30, STD_FEE);
        uint256 userBefore = userA.balance;
        uint256 keeperBefore = keeper.balance;
        _executeOrder(decKey);
        assertEq(_positionSizeUsd(userA, M_USDC, GmxArbitrumAddresses.WETH, false), 0, "D1: position should be closed");
        uint256 userGain = userA.balance - userBefore;
        uint256 keeperGain = keeper.balance - keeperBefore;
        int256 payoutUsd = int256(userGain + keeperGain - STD_FEE) * int256(entryPx);
        int256 collBeforeUsd = int256(collBeforeWei) * int256(entryPx);
        int256 closeImpactUsd = payoutUsd - collBeforeUsd + closeFeeUsd;
        console.log("D1 close totalImpactUsd (1e30):");
        console.logInt(closeImpactUsd);
        console.log("D1 net impact paid over round trip (1e30):");
        console.logInt(-closeImpactUsd);
        // The round trip must not PROFIT the trader from impact alone.
        assertLe(closeImpactUsd, 0, "D1: round trip must not earn positive impact");
    }

    /// (d2) Split close: open ONE $500k SHORT on [WETH-USDC], then close it in
    /// FIVE $100k pieces (separate test) vs ONE $500k close (separate test).
    /// Both caps that could be dodged scale with sizeDeltaUsd (max-factor cap)
    /// or deplete globally (pool cap), so the totals must match within rounding.
    function test_D2_SplitCloseSingle() public {
        int256 pendingOpen = _openShort(M_USDC, userA, 500_000e30, 50 ether);
        console.log("D2 single-close open pendingImpactUsd (1e30):");
        console.logInt(pendingOpen);

        uint256 collBeforeWei = _positionCollateral(userA, M_USDC, GmxArbitrumAddresses.WETH, false);
        uint256 feeFactor = _positionFeeFactor(M_USDC, true);
        int256 closeFeeUsd = int256(500_000e30 * feeFactor / 1e30);

        bytes32 decKey = _createDecrease(M_USDC, GmxArbitrumAddresses.WETH, userA, false, 500_000e30, STD_FEE);
        uint256 userBefore = userA.balance;
        uint256 keeperBefore = keeper.balance;
        _executeOrder(decKey);
        assertEq(_positionSizeUsd(userA, M_USDC, GmxArbitrumAddresses.WETH, false), 0, "D2: position should be closed");
        uint256 userGain = userA.balance - userBefore;
        uint256 keeperGain = keeper.balance - keeperBefore;
        int256 payoutUsd = int256(userGain + keeperGain - STD_FEE) * int256(entryPx);
        int256 collBeforeUsd = int256(collBeforeWei) * int256(entryPx);
        int256 closeImpactUsd = payoutUsd - collBeforeUsd + closeFeeUsd;
        console.log("D2 single-close totalImpactUsd (1e30):");
        console.logInt(closeImpactUsd);
    }

    function test_D2_SplitCloseFivePieces() public {
        int256 pendingOpen = _openShort(M_USDC, userA, 500_000e30, 50 ether);
        console.log("D2 five-piece open pendingImpactUsd (1e30):");
        console.logInt(pendingOpen);

        // Per-piece unified formula (verified against the PositionDecrease event
        // values for piece 1: priceImpact +$34.02, pending -$40.53, total -$6.52):
        // totalImpact_piece = closeFee - (collateralBefore - collateralAfter) + payout,
        // where payout = userGain + keeperGain - fee (balances AFTER create).
        // For a partial close the collateral stays in the position except for
        // fees/impact, so the collateral delta carries the impact; for the final
        // full close the remaining collateral is paid out as part of payout.
        uint256 feeFactor = _positionFeeFactor(M_USDC, true);
        int256 closeFeeUsd = int256(100_000e30 * feeFactor / 1e30);
        int256 totalCloseImpactUsd = 0;
        for (uint256 i = 0; i < 5; i++) {
            uint256 collBeforeWei = _positionCollateral(userA, M_USDC, GmxArbitrumAddresses.WETH, false);
            bytes32 decKey = _createDecrease(M_USDC, GmxArbitrumAddresses.WETH, userA, false, 100_000e30, STD_FEE);
            uint256 userBefore = userA.balance;
            uint256 keeperBefore = keeper.balance;
            _executeOrder(decKey);
            uint256 collAfterWei = _positionCollateral(userA, M_USDC, GmxArbitrumAddresses.WETH, false);
            uint256 userGain = userA.balance - userBefore;
            uint256 keeperGain = keeper.balance - keeperBefore;
            int256 payoutUsd = int256(userGain + keeperGain - STD_FEE) * int256(entryPx);
            int256 collDeltaUsd = (int256(collBeforeWei) - int256(collAfterWei)) * int256(entryPx);
            int256 pieceImpactUsd = closeFeeUsd - collDeltaUsd + payoutUsd;
            totalCloseImpactUsd += pieceImpactUsd;
            console.log("D2 piece impactUsd (1e30):");
            console.logInt(pieceImpactUsd);
        }
        assertEq(_positionSizeUsd(userA, M_USDC, GmxArbitrumAddresses.WETH, false), 0, "D2: position should be fully closed");
        console.log("D2 five-piece totalImpactUsd (1e30):");
        console.logInt(totalCloseImpactUsd);
    }

    // ------------------------------------------------------------------ test (c)

    /// Open a LONG with USDC collateral; return its stored (pending) impact in USD.
    function _openLongUsdc(address market, address account, uint256 sizeUsd, uint256 collateralUsdc) internal returns (int256 pendingUsd) {
        deal(GmxArbitrumAddresses.USDC, account, collateralUsdc);
        bytes32 key = _createIncrease(market, GmxArbitrumAddresses.USDC, account, true, collateralUsdc, sizeUsd, STD_FEE);
        _executeOrder(key);
        assertEq(_positionSizeUsd(account, market, GmxArbitrumAddresses.USDC, true), sizeUsd, "long not opened");
        pendingUsd = _pendingImpactUsd(account, market, GmxArbitrumAddresses.USDC, true);
    }

    /// Open a SHORT with USDC collateral; return its stored (pending) impact in USD.
    function _openShortUsdc(address market, address account, uint256 sizeUsd, uint256 collateralUsdc) internal returns (int256 pendingUsd) {
        deal(GmxArbitrumAddresses.USDC, account, collateralUsdc);
        bytes32 key = _createIncrease(market, GmxArbitrumAddresses.USDC, account, false, collateralUsdc, sizeUsd, STD_FEE);
        _executeOrder(key);
        assertEq(_positionSizeUsd(account, market, GmxArbitrumAddresses.USDC, false), sizeUsd, "short not opened");
        pendingUsd = _pendingImpactUsd(account, market, GmxArbitrumAddresses.USDC, false);
    }

    /// Close a USDC-collateral position fully; return totalImpactUsd.
    /// totalImpactUsd = (usdcGain - collBeforeWei) * USDC_PX + closeFeeUsd, with
    /// balances snapshotted AFTER the decrease order is created. The fee factor
    /// follows balanceWasImproved = nextDiff < initialDiff (PositionPricingUtils
    /// _getPriceImpactUsd): a close that shrinks |OI imbalance| is improved
    /// (0.04%), one that grows it is not (0.06%). The caller passes the flag
    /// from the known OI direction of the trade.
    function _closePositionUsdc(address market, address account, uint256 sizeUsd, bool isLong, bool improved) internal returns (int256 totalImpactUsd) {
        uint256 collBeforeWei = _positionCollateral(account, market, GmxArbitrumAddresses.USDC, isLong);
        uint256 feeFactor = _positionFeeFactor(market, improved);
        int256 closeFeeUsd = int256(sizeUsd * feeFactor / 1e30);
        bytes32 decKey = _createDecrease(market, GmxArbitrumAddresses.USDC, account, isLong, sizeUsd, STD_FEE);
        uint256 usdcBefore = usdc.balanceOf(account);
        _executeOrder(decKey);
        assertEq(_positionSizeUsd(account, market, GmxArbitrumAddresses.USDC, isLong), 0, "position not closed");
        uint256 usdcGain = usdc.balanceOf(account) - usdcBefore;
        totalImpactUsd = (int256(usdcGain) - int256(collBeforeWei)) * int256(USDC_PX) + closeFeeUsd;
    }

    /// Close a WETH-collateral SHORT fully; return totalImpactUsd (D1 formula:
    /// payout - collateralBefore + closeFee, balances after create).
    function _closeShortWeth(address market, address account, uint256 sizeUsd, bool improved) internal returns (int256 totalImpactUsd) {
        uint256 collBeforeWei = _positionCollateral(account, market, GmxArbitrumAddresses.WETH, false);
        uint256 feeFactor = _positionFeeFactor(market, improved);
        int256 closeFeeUsd = int256(sizeUsd * feeFactor / 1e30);
        bytes32 decKey = _createDecrease(market, GmxArbitrumAddresses.WETH, account, false, sizeUsd, STD_FEE);
        uint256 userBefore = account.balance;
        uint256 keeperBefore = keeper.balance;
        _executeOrder(decKey);
        assertEq(_positionSizeUsd(account, market, GmxArbitrumAddresses.WETH, false), 0, "short not closed");
        uint256 userGain = account.balance - userBefore;
        uint256 keeperGain = keeper.balance - keeperBefore;
        int256 payoutUsd = int256(userGain + keeperGain - STD_FEE) * int256(entryPx);
        int256 collBeforeUsd = int256(collBeforeWei) * int256(entryPx);
        totalImpactUsd = payoutUsd - collBeforeUsd + closeFeeUsd;
    }

    /// (c1) Pool-drain attempt on M_USDC (impact pool ~445 WETH ~ $844k).
    /// A opens a LONG $1.55M (intended as a balancing trade, but the
    /// TOKEN-denominated imbalance is only ~319 WETH short-heavy, so the
    /// $1.55M LONG OVERSHOOTS into long-heavy territory and stores NEGATIVE
    /// pending via the crossover formula), B opens a SHORT $5M (deepens the
    /// short-heavy imbalance, pays negative pending), A closes the LONG
    /// (now WORSENING: removing longs from a deeply short-heavy market, so
    /// it pays negative impact into the pool), B closes the SHORT (balancing:
    /// earns +$730 from the pool). Net: the pool GREW — the drain attempt
    /// fails on its own terms. A fresh $100k SHORT afterwards must pay the
    /// same impact as the baseline (pool state cannot discount negative
    /// impact — it is never pool-capped).
    function test_C1_PoolDrainAttempt() public {
        // Baseline: a $100k SHORT's pending impact on the pristine fork, then
        // close it to restore the OI exactly. The fresh short at the end is
        // compared against THIS value (not a hardcoded number — the OI drifts
        // between fork blocks, so a hardcoded A1 value is brittle).
        int256 pendingBase = _openShort(M_USDC, userA, 100_000e30, 10 ether);
        console.log("C1 baseline $100k short pendingImpactUsd (1e30):");
        console.logInt(pendingBase);
        int256 baseCloseImpact = _closeShortWeth(M_USDC, userA, 100_000e30, true);
        console.log("C1 baseline close totalImpactUsd (1e30):");
        console.logInt(baseCloseImpact);

        uint256 poolBefore = _impactPoolAmount(M_USDC);
        console.log("C1 pool before (WETH wei):", poolBefore);

        int256 pendingA = _openLongUsdc(M_USDC, userC, 1_550_000e30, 155_000e6);
        console.log("C1 A long open pendingImpactUsd (1e30):");
        console.logInt(pendingA);

        int256 pendingB = _openShortUsdc(M_USDC, userD, 5_000_000e30, 500_000e6);
        console.log("C1 B short open pendingImpactUsd (1e30):");
        console.logInt(pendingB);

        // A closes the LONG while the market is still short-heavy. NOTE: this
        // close is NOT balancing — B's $5M short overshot the other way, so
        // removing longs now WORSENS the imbalance (token diff goes from
        // -2,139 WETH to -2,957 WETH): the close pays NEGATIVE impact and its
        // fee factor is the not-improved 0.06% (improved=false). With the
        // correct factor the balance-measured totalImpact matches the pool
        // credit exactly (see FINDINGS.md).
        int256 impactA = _closePositionUsdc(M_USDC, userC, 1_550_000e30, true, false);
        console.log("C1 A long close totalImpactUsd (1e30):");
        console.logInt(impactA);
        uint256 poolAfterA = _impactPoolAmount(M_USDC);
        console.log("C1 pool after A close (WETH wei):", poolAfterA);

        int256 impactB = _closePositionUsdc(M_USDC, userD, 5_000_000e30, false, true);
        console.log("C1 B short close totalImpactUsd (1e30):");
        console.logInt(impactB);
        uint256 poolAfterB = _impactPoolAmount(M_USDC);
        console.log("C1 pool after B close (WETH wei):", poolAfterB);

        int256 pendingFresh = _openShort(M_USDC, userA, 100_000e30, 10 ether);
        console.log("C1 fresh $100k short pendingImpactUsd (1e30):");
        console.logInt(pendingFresh);
        // Same OI state as the baseline (A and B both closed, net zero), same
        // size and direction: the pending impact must be IDENTICAL. A drained
        // pool cannot discount it — negative impact is never pool-capped.
        assertEq(pendingFresh, pendingBase, "C1: fresh short impact must equal baseline");
    }

    /// (c2) Repeated SMALL balancing trades: 5x open+close of a $100k LONG on
    /// M_USDC with nobody else moving the market. Each round trip's close
    /// reverses its open, so the close's negative impact cancels the open's
    /// positive pending (negative factor > positive factor) and the pool must
    /// NOT shrink — small trades cannot drain it without a counterparty who
    /// sustains the imbalance, and that counterparty pays more into the pool
    /// than the drainer can take out (see C1).
    function test_C2_SmallBalancingRoundTrips() public {
        uint256 poolBefore = _impactPoolAmount(M_USDC);
        int256 totalEarned = 0;
        for (uint256 i = 0; i < 5; i++) {
            int256 pending = _openLongUsdc(M_USDC, userC, 100_000e30, 10_000e6);
            // The close re-creates the short-heavy imbalance: not improved (0.06%).
            int256 impact = _closePositionUsdc(M_USDC, userC, 100_000e30, true, false);
            totalEarned += impact;
            console.log("C2 trip pending (1e30):");
            console.logInt(pending);
            console.log("C2 trip close totalImpactUsd (1e30):");
            console.logInt(impact);
        }
        uint256 poolAfter = _impactPoolAmount(M_USDC);
        console.log("C2 pool before (WETH wei):", poolBefore);
        console.log("C2 pool after (WETH wei):", poolAfter);
        console.log("C2 total impact earned over 5 trips (1e30):");
        console.logInt(totalEarned);
        assertLe(totalEarned, 0, "C2: small balancing round trips must not extract impact");
        assertGe(poolAfter, poolBefore, "C2: pool must not shrink from balancing round trips");
    }

    /// Side observation (NOT a finding): M_WSTETH has a size-dependent
    /// rejection for new positions whose threshold moves with live state.
    /// On block 524048515 a $100 LONG opened while $10k/$100k LONGs were
    /// cancelled; on block 524054954 $1k/$5k LONGs and a $10k SHORT all
    /// opened. The repo's validateReserve (long reservedUsd ~$3.09M vs long
    /// pool ~$10.7k x 1.25) predicts ANY increase should fail, yet small
    /// ones open — so the deployed reserve path differs from repo main
    /// @ a85ea34, or another size-dependent check binds. The exact check
    /// is NOT identified (the -vvvv trace RPC prunes the old block).
    /// Recorded here only so the drain test's market choice (M_USDC, deep
    /// pools) is justified; not pursued further.
    function test_ReserveBoundary_MWSTETH() public {
        // Boundary probe: LONG $1k, $5k; SHORT $10k (is the bind long-only?).
        address[3] memory users = [userA, userB, userC];
        bool[3] memory isLong = [true, true, false];
        uint256[3] memory sizes = [uint256(1_000e30), uint256(5_000e30), uint256(10_000e30)];
        uint256[3] memory colls = [uint256(100e18), uint256(500e18), uint256(1_000e18)];
        for (uint256 i = 0; i < 3; i++) {
            deal(USDE, users[i], colls[i]);
            bytes32 key = _createIncrease(M_WSTETH, USDE, users[i], isLong[i], colls[i], sizes[i], STD_FEE);
            vm.recordLogs();
            _setPricesAll();
            vm.txGasPrice(GAS_PRICE);
            vm.prank(keeper);
            (bool ok, ) = address(orderHandler).call(
                abi.encodeWithSelector(IOrderHandler.executeOrder.selector, key, _emptyOracleParams())
            );
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 size = _positionSizeUsd(users[i], M_WSTETH, USDE, isLong[i]);
            console.log("M_WSTETH attempt isLong:", isLong[i]);
            console.log("  sizeUsd (1e30):", sizes[i]);
            console.log("  execute ok:", ok, "position size (1e30):", size);
            if (size == 0 && logs.length > 0) {
                // Dump the last log's raw data (the cancel event carries the
                // revert reason inside the EventLogData struct).
                console.log("  last log data:");
                console.logBytes(logs[logs.length - 1].data);
            }
        }
    }
}
