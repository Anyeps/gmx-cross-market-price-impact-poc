// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// GMX lead G-P1-2(a) — CLOSE-SPLIT follow-up.
// Question: does the cross-market price-impact split saving also apply on the
// CLOSE leg of a round trip? DEEPENING.md claimed (unverified) "the close can
// be split the same way" — this file tests it.
// Fork: Arbitrum, block 524063246 (fresh, 2026-11-14 ~11:42 WIB).
// Markets: ETH/USD [WETH-USDC] 0x70d95587..., [WETH-WETH] 0x450bb677...
// (index WETH, shared virtualTokenId 0x3c48...).
//
// Measurement definitions (IMPORTANT — see CLOSE-SPLIT.md):
// - openPendingUsd = position's stored pendingImpactAmount (index tokens) x price.
//   It is a DEFERRED liability, not cash paid at open: it is realised at close
//   inside totalImpactUsd (totalImpact = proportionalPending + priceImpact at
//   close; for a full close proportionalPending == openPending exactly).
// - closeTotalUsd = payout - collateralBefore + closeFee (D1 formula), PnL = 0,
//   funding/borrowing = 0 (no time elapses, same oracle price throughout).
// - TRUE cash net impact paid over the round trip = -closeTotalUsd (summed over
//   legs). The task's literal formula openPending + closeTotal DOUBLE-COUNTS the
//   pending (it appears in both terms); both numbers are logged so the
//   distinction is auditable, and the verdict uses the true cash net.
// - Cross-check: impact-pool delta (USD) must equal -closeTotalUsd to the cent
//   (C1 verified this). A wrong close-fee factor (0.04% improved vs 0.06%
//   not-improved) would shift the measured closeTotal by exactly 0.02% x size
//   and break the pool match — so the pool match validates the fee factor.
//   Closing a SHORT on a short-heavy market improves the balance, so
//   improved=true (0.04%) is used for every close here.
//
// Harness notes (same as G-P1-2 / G-P1-4 / DEEPENING):
// - Oracle bypass (explicit): prank the ExchangeRouter (holds CONTROLLER),
//   Oracle.setPrimaryPrice + Oracle.setTimestamps with the LIVE Chainlink feed
//   values read from the DataStore at the fork block, then handlers with EMPTY
//   SetPricesParams so setPrices() is a no-op. No oracle forgery, no fake prices.
// - withOraclePrices clears prices at the END of every handler call — re-set
//   before EVERY handler call (done in _executeOrder).
// - vm.txGasPrice(0.1 gwei) before every create/execute; min execution fee at
//   0.1 gwei is 0.0004123455 ETH; STD_FEE = 0.001 ETH.
// - Position key = keccak256(abi.encode(account, market, collateralToken, isLong)).
// - Live position fee factors are improved 0.04% / not-improved 0.06% (NOT 0).
// - Read-only mainnet, local fork only. No report drafted or submitted.

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../contracts/utils/GmxForkHelpers.sol";
import "../contracts/constants/GmxArbitrumAddresses.sol";
import "../contracts/interfaces/IGmxV2.sol";
import {Keys as GmxKeys} from "../contracts/Keys.sol";

contract GP12CloseSplitTest is GmxForkHelpers {
    address internal constant M_USDC = 0x70d95587d40A2caf56bd97485aB3Eec10Bee6336;
    address internal constant M_WETH = 0x450bb6774Dd8a756274E0ab4107953259d2ac541;
    address internal constant WSTETH = 0x5979D7b546E38E414F7E9822514be443A4800529;
    address internal constant USDE = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34;
    uint256 internal constant USDC_PX = 1e24; // $1 per USDC unit (6 decimals)
    uint256 internal constant GAS_PRICE = 0.1 gwei;
    uint256 internal constant STD_FEE = 0.001 ether;

    bytes32 internal constant POSITION_SIZE_IN_USD = keccak256(abi.encode("SIZE_IN_USD"));
    bytes32 internal constant POSITION_COLLATERAL_AMOUNT = keccak256(abi.encode("COLLATERAL_AMOUNT"));
    bytes32 internal constant PENDING_IMPACT_AMOUNT = keccak256(abi.encode("PENDING_IMPACT_AMOUNT"));

    address internal userA = address(0xA11CE);
    address internal userC = address(0xC11C);
    address internal keeper;
    IERC20 internal weth;
    IERC20 internal usdc;
    uint256 internal entryPx;

    function setUp() public {
        vm.createSelectFork("https://arb1.arbitrum.io/rpc", 524063246);
        exchangeRouter = IExchangeRouter(GmxArbitrumAddresses.EXCHANGE_ROUTER);
        orderHandler = IOrderHandler(GmxArbitrumAddresses.ORDER_HANDLER);
        oracle = IOracle(GmxArbitrumAddresses.ORACLE);
        dataStore = IDataStore(GmxArbitrumAddresses.DATA_STORE);
        roleStore = IRoleStore(GmxArbitrumAddresses.ROLE_STORE);
        weth = IERC20(GmxArbitrumAddresses.WETH);
        usdc = IERC20(GmxArbitrumAddresses.USDC);

        vm.deal(userA, 2000 ether);
        vm.deal(userC, 2000 ether);

        uint256 kc = roleStore.getRoleMemberCount(Keys.ORDER_KEEPER);
        require(kc > 0, "no keepers");
        address[] memory ks = roleStore.getRoleMembers(Keys.ORDER_KEEPER, 0, kc);
        keeper = ks[0];
        vm.deal(keeper, 10 ether);

        (uint256 px, bool ok) = _feedPrice(GmxArbitrumAddresses.WETH);
        require(ok, "no weth feed");
        entryPx = px;
        console.log("entryPx (USD*1e12):", entryPx);
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
        uint256 wstethPx;
        (uint256 wpx, bool wok) = _feedPrice(WSTETH);
        wstethPx = wok ? wpx : entryPx;
        uint256 usdePx;
        (uint256 upx, bool uok) = _feedPrice(USDE);
        usdePx = uok ? upx : 1e24;
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

    function _pendingImpactTokens(address account, address market, address collateralToken, bool isLong) internal view returns (int256) {
        return dataStore.getInt(keccak256(abi.encode(_positionKey(account, market, collateralToken, isLong), PENDING_IMPACT_AMOUNT)));
    }

    function _pendingImpactUsd(address account, address market, address collateralToken, bool isLong) internal view returns (int256) {
        return _pendingImpactTokens(account, market, collateralToken, isLong) * int256(entryPx);
    }

    function _impactPoolAmount(address market) internal view returns (uint256) {
        return dataStore.getUint(GmxKeys.positionImpactPoolAmountKey(market));
    }

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
        params.numbers.initialCollateralDeltaAmount = collateralAmount + fee;
        vm.txGasPrice(GAS_PRICE);
        vm.startPrank(account);
        exchangeRouter.sendWnt{value: collateralAmount + fee}(GmxArbitrumAddresses.ORDER_VAULT, collateralAmount + fee);
        bytes32 key = exchangeRouter.createOrder{value: 0}(params);
        vm.stopPrank();
        return key;
    }

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

    function _positionFeeFactor(address market, bool improved) internal view returns (uint256) {
        return dataStore.getUint(GmxKeys.positionFeeFactorKey(market, improved));
    }

    function _collateralFor(uint256 sizeUsd) internal view returns (uint256) {
        return sizeUsd / 10 / entryPx;
    }

    /// Open a SHORT (WETH collateral, 10x) and return its stored pending impact USD (1e30).
    function _openShort(address market, address account, uint256 sizeUsd) internal returns (int256 pendingUsd) {
        bytes32 key = _createIncrease(market, GmxArbitrumAddresses.WETH, account, false, _collateralFor(sizeUsd), sizeUsd, STD_FEE);
        _executeOrder(key);
        assertEq(_positionSizeUsd(account, market, GmxArbitrumAddresses.WETH, false), sizeUsd, "short not opened");
        pendingUsd = _pendingImpactUsd(account, market, GmxArbitrumAddresses.WETH, false);
    }

    /// Close a WETH-collateral SHORT fully (D1 formula) and return
    /// (totalImpactUsd, impactPoolDeltaUsd). Pool delta must equal -totalImpact
    /// (ground-truth cross-check; C1 verified it to the cent).
    /// `improved` selects the live fee factor: closing a SHORT on a short-heavy
    /// market improves the balance -> true (0.04%).
    function _closeShortWeth(address market, address account, uint256 sizeUsd, bool improved)
        internal
        returns (int256 totalImpactUsd, int256 poolDeltaUsd)
    {
        uint256 poolBefore = _impactPoolAmount(market);
        uint256 collBeforeWei = _positionCollateral(account, market, GmxArbitrumAddresses.WETH, false);
        int256 closeFeeUsd = int256(sizeUsd * _positionFeeFactor(market, improved) / 1e30);
        bytes32 decKey = _createDecrease(market, GmxArbitrumAddresses.WETH, account, false, sizeUsd, STD_FEE);
        uint256 userBefore = account.balance;
        uint256 keeperBefore = keeper.balance;
        _executeOrder(decKey);
        require(_positionSizeUsd(account, market, GmxArbitrumAddresses.WETH, false) == 0, "short not closed");
        totalImpactUsd = _payoutImpact(account, collBeforeWei, closeFeeUsd, userBefore, keeperBefore);
        poolDeltaUsd = (int256(_impactPoolAmount(market)) - int256(poolBefore)) * int256(entryPx);
    }

    function _payoutImpact(address account, uint256 collBeforeWei, int256 closeFeeUsd, uint256 userBefore, uint256 keeperBefore)
        internal
        view
        returns (int256 totalImpactUsd)
    {
        int256 payoutUsd = int256(account.balance - userBefore + keeper.balance - keeperBefore - STD_FEE) * int256(entryPx);
        totalImpactUsd = payoutUsd - int256(collBeforeWei) * int256(entryPx) + closeFeeUsd;
    }

    /// Log an exact 1e30 value and its whole-dollar truncation.
    function _logUsd(string memory label, int256 v) internal pure {
        console.log(label);
        console.logInt(v);
        console.log("  whole USD (truncated):");
        console.logInt(v / 1e30);
    }

    /// Log one leg's open + close + pool check.
    function _logLeg(string memory label, int256 openPending, int256 closeTotal, int256 poolDelta) internal pure {
        _logUsd(string.concat(label, " open pending (1e30)"), openPending);
        _logUsd(string.concat(label, " close totalImpact (1e30)"), closeTotal);
        _logUsd(string.concat(label, " close priceImpact rebate = closeTotal - openPending (1e30)"), closeTotal - openPending);
        _logUsd(string.concat(label, " impact-pool delta (1e30, must be -closeTotal)"), poolDelta);
    }

    /// Log a round trip's summary: true net paid (-closeTotal) and the task's
    /// literal open+close sum (double-counts pending — see header).
    function _logRoundTrip(string memory label, int256 openTotal, int256 closeTotal) internal pure {
        _logUsd(string.concat(label, " NET IMPACT PAID = -closeTotal (1e30)"), -closeTotal);
        _logUsd(string.concat(label, " literal open+close sum (1e30, double-counts pending)"), openTotal + closeTotal);
    }

    // ------------------------------------------------------------------ $100k

    function test_CS100k_SingleRoundTrip() public {
        int256 openPending = _openShort(M_USDC, userA, 100_000e30);
        (int256 closeTotal, int256 poolDelta) = _closeShortWeth(M_USDC, userA, 100_000e30, true);
        _logLeg("CS100k SINGLE [WETH-USDC]", openPending, closeTotal, poolDelta);
        _logRoundTrip("CS100k SINGLE", openPending, closeTotal);
        assertApproxEqAbs(poolDelta, -closeTotal, 1e30, "CS100k single: pool delta must match -closeTotal");
        assertLe(closeTotal, 0, "CS100k single: round trip must not earn positive impact");
    }

    function test_CS100k_SplitRoundTrip() public {
        int256 pUsdc = _openShort(M_USDC, userC, 50_000e30);
        int256 pWeth = _openShort(M_WETH, userC, 50_000e30);
        // Close in the same order as the open: USDC leg first, then WETH leg.
        (int256 cUsdc, int256 poolUsdc) = _closeShortWeth(M_USDC, userC, 50_000e30, true);
        (int256 cWeth, int256 poolWeth) = _closeShortWeth(M_WETH, userC, 50_000e30, true);
        _logLeg("CS100k SPLIT USDC leg", pUsdc, cUsdc, poolUsdc);
        _logLeg("CS100k SPLIT WETH leg", pWeth, cWeth, poolWeth);
        _logRoundTrip("CS100k SPLIT total", pUsdc + pWeth, cUsdc + cWeth);
        assertApproxEqAbs(poolUsdc, -cUsdc, 1e30, "CS100k split: USDC pool delta must match -closeTotal");
        assertApproxEqAbs(poolWeth, -cWeth, 1e30, "CS100k split: WETH pool delta must match -closeTotal");
    }

    function test_CS100k_SplitRoundTrip_ReverseClose() public {
        int256 pUsdc = _openShort(M_USDC, userC, 50_000e30);
        int256 pWeth = _openShort(M_WETH, userC, 50_000e30);
        // Close order reversed: WETH leg first, then USDC leg.
        (int256 cWeth, int256 poolWeth) = _closeShortWeth(M_WETH, userC, 50_000e30, true);
        (int256 cUsdc, int256 poolUsdc) = _closeShortWeth(M_USDC, userC, 50_000e30, true);
        _logLeg("CS100k SPLIT-REV WETH leg", pWeth, cWeth, poolWeth);
        _logLeg("CS100k SPLIT-REV USDC leg", pUsdc, cUsdc, poolUsdc);
        _logRoundTrip("CS100k SPLIT-REV total", pUsdc + pWeth, cUsdc + cWeth);
        assertApproxEqAbs(poolUsdc, -cUsdc, 1e30, "CS100k rev: USDC pool delta must match -closeTotal");
        assertApproxEqAbs(poolWeth, -cWeth, 1e30, "CS100k rev: WETH pool delta must match -closeTotal");
    }

    // ------------------------------------------------------------------ $1M

    function test_CS1M_SingleRoundTrip() public {
        int256 openPending = _openShort(M_USDC, userA, 1_000_000e30);
        (int256 closeTotal, int256 poolDelta) = _closeShortWeth(M_USDC, userA, 1_000_000e30, true);
        _logLeg("CS1M SINGLE [WETH-USDC]", openPending, closeTotal, poolDelta);
        _logRoundTrip("CS1M SINGLE", openPending, closeTotal);
        assertApproxEqAbs(poolDelta, -closeTotal, 1e30, "CS1M single: pool delta must match -closeTotal");
        assertLe(closeTotal, 0, "CS1M single: round trip must not earn positive impact");
    }

    function test_CS1M_SplitRoundTrip() public {
        int256 pUsdc = _openShort(M_USDC, userC, 500_000e30);
        int256 pWeth = _openShort(M_WETH, userC, 500_000e30);
        (int256 cUsdc, int256 poolUsdc) = _closeShortWeth(M_USDC, userC, 500_000e30, true);
        (int256 cWeth, int256 poolWeth) = _closeShortWeth(M_WETH, userC, 500_000e30, true);
        _logLeg("CS1M SPLIT USDC leg", pUsdc, cUsdc, poolUsdc);
        _logLeg("CS1M SPLIT WETH leg", pWeth, cWeth, poolWeth);
        _logRoundTrip("CS1M SPLIT total", pUsdc + pWeth, cUsdc + cWeth);
        assertApproxEqAbs(poolUsdc, -cUsdc, 1e30, "CS1M split: USDC pool delta must match -closeTotal");
        assertApproxEqAbs(poolWeth, -cWeth, 1e30, "CS1M split: WETH pool delta must match -closeTotal");
    }

    function test_CS1M_SplitRoundTrip_ReverseClose() public {
        int256 pUsdc = _openShort(M_USDC, userC, 500_000e30);
        int256 pWeth = _openShort(M_WETH, userC, 500_000e30);
        (int256 cWeth, int256 poolWeth) = _closeShortWeth(M_WETH, userC, 500_000e30, true);
        (int256 cUsdc, int256 poolUsdc) = _closeShortWeth(M_USDC, userC, 500_000e30, true);
        _logLeg("CS1M SPLIT-REV WETH leg", pWeth, cWeth, poolWeth);
        _logLeg("CS1M SPLIT-REV USDC leg", pUsdc, cUsdc, poolUsdc);
        _logRoundTrip("CS1M SPLIT-REV total", pUsdc + pWeth, cUsdc + cWeth);
        assertApproxEqAbs(poolUsdc, -cUsdc, 1e30, "CS1M rev: USDC pool delta must match -closeTotal");
        assertApproxEqAbs(poolWeth, -cWeth, 1e30, "CS1M rev: WETH pool delta must match -closeTotal");
    }
}
