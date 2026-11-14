// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// GMX lead G-P1-2 — probe: live impact config on a fresh Arbitrum fork.
// Verifies (not trusts) the recon snapshot in ~/workspace/hunts/gmx/markets_info.json:
// which WETH-index markets share a virtual token id, their impact factors,
// exponents, caps, impact-pool amounts, lendable config, and OI.

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../contracts/utils/GmxForkHelpers.sol";
import "../contracts/constants/GmxArbitrumAddresses.sol";
import "../contracts/interfaces/IGmxV2.sol";
import {Keys as GmxKeys} from "../contracts/Keys.sol";

contract GP12ProbeTest is GmxForkHelpers {
    address internal constant M_USDC = 0x70d95587d40A2caf56bd97485aB3Eec10Bee6336; // ETH/USD [WETH-USDC]
    address internal constant M_WETH = 0x450bb6774Dd8a756274E0ab4107953259d2ac541; // ETH/USD [WETH-WETH]
    address internal constant M_WSTETH = 0x0Cf1fb4d1FF67A3D8Ca92c9d6643F8F9be8e03E5; // ETH/USD [WSTETH-USDE]

    function setUp() public {
        vm.createSelectFork("https://arb1.arbitrum.io/rpc", 524054954);
        dataStore = IDataStore(GmxArbitrumAddresses.DATA_STORE);
    }

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

    function test_ProbeLiveImpactConfig() public {
        (uint256 wethPx, bool ok) = _feedPrice(GmxArbitrumAddresses.WETH);
        require(ok, "no weth feed");
        console.log("WETH price (USD*1e12):", wethPx);

        bool useOiTokens = dataStore.getBool(GmxKeys.USE_OPEN_INTEREST_IN_TOKENS_FOR_BALANCE);
        console.log("USE_OPEN_INTEREST_IN_TOKENS_FOR_BALANCE:", useOiTokens);

        bytes32 vtid = dataStore.getBytes32(GmxKeys.virtualTokenIdKey(GmxArbitrumAddresses.WETH));
        console.log("virtualTokenId(WETH):");
        console.logBytes32(vtid);
        int256 vInv = dataStore.getInt(GmxKeys.virtualInventoryForPositionsKey(vtid));
        int256 vInvTok = dataStore.getInt(GmxKeys.virtualInventoryForPositionsInTokensKey(vtid));
        console.log("virtualInventoryForPositions (1e30 USD, int):");
        console.logInt(vInv);
        console.log("virtualInventoryForPositionsInTokens (int):");
        console.logInt(vInvTok);
        console.log("virtualInventoryInTokens in USD (x wethPx):", uint256(vInvTok >= 0 ? vInvTok : -vInvTok) * wethPx / 1e18);

        _logMarket("M_USDC [WETH-USDC]", M_USDC);
        _logMarket("M_WETH [WETH-WETH]", M_WETH);
        _logMarket("M_WSTETH [WSTETH-USDE]", M_WSTETH);
    }

    function test_ProbeWstethPools() public {
        address wsteth = address(0x5979D7b546E38E414F7E9822514be443A4800529);
        address usde = address(0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34);
        (uint256 wethPx, bool ok0) = _feedPrice(GmxArbitrumAddresses.WETH);
        require(ok0, "no weth feed");
        (uint256 wstethPx, bool ok1) = _feedPrice(wsteth);
        (uint256 usdePx, bool ok2) = _feedPrice(usde);
        // wstETH/USDE have no usable DataStore feed on this fork (same fallback
        // as the main test): wstETH ~1.17x WETH, USDE ~$1.00.
        if (!ok1) wstethPx = wethPx * 117 / 100;
        if (!ok2) usdePx = 1e24;
        console.log("wstETH price (USD*1e12):", wstethPx);
        console.log("USDE price (USD*1e12):", usdePx);
        console.log("M_WSTETH long pool (wstETH wei):", dataStore.getUint(GmxKeys.poolAmountKey(M_WSTETH, wsteth)));
        console.log("M_WSTETH short pool (USDE wei):", dataStore.getUint(GmxKeys.poolAmountKey(M_WSTETH, usde)));
        console.log("M_WSTETH reserveFactor long:", dataStore.getUint(GmxKeys.reserveFactorKey(M_WSTETH, true)));
        console.log("M_WSTETH reserveFactor short:", dataStore.getUint(GmxKeys.reserveFactorKey(M_WSTETH, false)));
        console.log("M_WSTETH OI reserveFactor long:", dataStore.getUint(GmxKeys.openInterestReserveFactorKey(M_WSTETH, true)));
        console.log("M_WSTETH OI reserveFactor short:", dataStore.getUint(GmxKeys.openInterestReserveFactorKey(M_WSTETH, false)));
        console.log("M_WSTETH OI long wstETH-collat:", dataStore.getUint(GmxKeys.openInterestKey(M_WSTETH, wsteth, true)));
        console.log("M_WSTETH OI long USDE-collat:", dataStore.getUint(GmxKeys.openInterestKey(M_WSTETH, usde, true)));
        console.log("M_WSTETH OI short wstETH-collat:", dataStore.getUint(GmxKeys.openInterestKey(M_WSTETH, wsteth, false)));
        console.log("M_WSTETH OI short USDE-collat:", dataStore.getUint(GmxKeys.openInterestKey(M_WSTETH, usde, false)));
        console.log("M_WSTETH impact pool:", dataStore.getUint(GmxKeys.positionImpactPoolAmountKey(M_WSTETH)));
        console.log("M_WSTETH posFeeFactor improved:", dataStore.getUint(GmxKeys.positionFeeFactorKey(M_WSTETH, true)));
        console.log("M_WSTETH posFeeFactor not-improved:", dataStore.getUint(GmxKeys.positionFeeFactorKey(M_WSTETH, false)));
    }

    /// Probe a candidate drain market: GMX/USD [GMX-GMX] (single-token market,
    /// snapshot pool ~$29k, token pools ~$515k each side).
    function test_ProbeGmxMarket() public {
        address mkt = 0xbD48149673724f9cAeE647bb4e9D9dDaF896Efeb;
        address gmx = 0xfc5A1A6EB076a2C7aD06eD22C90d7E710E35ad0a;
        (uint256 gmxPx, bool ok) = _feedPrice(gmx);
        console.log("GMX price (USD*1e12):", gmxPx, "feed ok:", ok);
        console.log("GMX/USD disabled:", dataStore.getBool(GmxKeys.isMarketDisabledKey(mkt)));
        console.log("posImpactFactor(+):", dataStore.getUint(GmxKeys.positionImpactFactorKey(mkt, true)));
        console.log("posImpactFactor(-):", dataStore.getUint(GmxKeys.positionImpactFactorKey(mkt, false)));
        console.log("posImpactExponent(+):", dataStore.getUint(GmxKeys.positionImpactExponentFactorKey(mkt, true)));
        console.log("posImpactExponent(-):", dataStore.getUint(GmxKeys.positionImpactExponentFactorKey(mkt, false)));
        console.log("maxPosImpactFactor(+):", dataStore.getUint(GmxKeys.maxPositionImpactFactorKey(mkt, true)));
        console.log("maxPosImpactFactor(-):", dataStore.getUint(GmxKeys.maxPositionImpactFactorKey(mkt, false)));
        console.log("impact pool (GMX wei):", dataStore.getUint(GmxKeys.positionImpactPoolAmountKey(mkt)));
        console.log("long pool (GMX wei):", dataStore.getUint(GmxKeys.poolAmountKey(mkt, gmx)));
        console.log("short pool (GMX wei):", dataStore.getUint(GmxKeys.poolAmountKey(mkt, gmx)));
        console.log("reserveFactor long:", dataStore.getUint(GmxKeys.reserveFactorKey(mkt, true)));
        console.log("reserveFactor short:", dataStore.getUint(GmxKeys.reserveFactorKey(mkt, false)));
        console.log("maxOpenInterest long:", dataStore.getUint(GmxKeys.maxOpenInterestKey(mkt, true)));
        console.log("maxOpenInterest short:", dataStore.getUint(GmxKeys.maxOpenInterestKey(mkt, false)));
        console.log("OI long (GMX collat):", dataStore.getUint(GmxKeys.openInterestKey(mkt, gmx, true)));
        console.log("OI short (GMX collat):", dataStore.getUint(GmxKeys.openInterestKey(mkt, gmx, false)));
        console.log("posFeeFactor improved:", dataStore.getUint(GmxKeys.positionFeeFactorKey(mkt, true)));
        console.log("posFeeFactor not-improved:", dataStore.getUint(GmxKeys.positionFeeFactorKey(mkt, false)));
    }

    /// Live pools/OI for M_USDC (the drain-test market candidate).
    function test_ProbeUsdcPools() public {
        address mkt = 0x70d95587d40A2caf56bd97485aB3Eec10Bee6336;
        address weth = GmxArbitrumAddresses.WETH;
        address usdc = GmxArbitrumAddresses.USDC;
        console.log("M_USDC long pool (WETH wei):", dataStore.getUint(GmxKeys.poolAmountKey(mkt, weth)));
        console.log("M_USDC short pool (USDC wei):", dataStore.getUint(GmxKeys.poolAmountKey(mkt, usdc)));
        console.log("M_USDC impact pool (WETH wei):", dataStore.getUint(GmxKeys.positionImpactPoolAmountKey(mkt)));
        console.log("M_USDC reserveFactor long:", dataStore.getUint(GmxKeys.reserveFactorKey(mkt, true)));
        console.log("M_USDC reserveFactor short:", dataStore.getUint(GmxKeys.reserveFactorKey(mkt, false)));
        console.log("M_USDC OI long WETH-collat:", dataStore.getUint(GmxKeys.openInterestKey(mkt, weth, true)));
        console.log("M_USDC OI long USDC-collat:", dataStore.getUint(GmxKeys.openInterestKey(mkt, usdc, true)));
        console.log("M_USDC OI short WETH-collat:", dataStore.getUint(GmxKeys.openInterestKey(mkt, weth, false)));
        console.log("M_USDC OI short USDC-collat:", dataStore.getUint(GmxKeys.openInterestKey(mkt, usdc, false)));
    }

    /// Token-denominated OI for M_USDC (the impact calc uses the TOKENS path:
    /// USE_OPEN_INTEREST_IN_TOKENS_FOR_BALANCE = true). Needed to explain why
    /// a $1.55M balancing LONG in C1 stored NEGATIVE pending impact.
    function test_ProbeUsdcOiTokens() public {
        address mkt = 0x70d95587d40A2caf56bd97485aB3Eec10Bee6336;
        address weth = GmxArbitrumAddresses.WETH;
        address usdc = GmxArbitrumAddresses.USDC;
        console.log("OI tokens long WETH-collat:", dataStore.getUint(GmxKeys.openInterestInTokensKey(mkt, weth, true)));
        console.log("OI tokens long USDC-collat:", dataStore.getUint(GmxKeys.openInterestInTokensKey(mkt, usdc, true)));
        console.log("OI tokens short WETH-collat:", dataStore.getUint(GmxKeys.openInterestInTokensKey(mkt, weth, false)));
        console.log("OI tokens short USDC-collat:", dataStore.getUint(GmxKeys.openInterestInTokensKey(mkt, usdc, false)));
        bytes32 vtid = dataStore.getBytes32(GmxKeys.virtualTokenIdKey(weth));
        console.log("virtualTokenId(WETH):");
        console.logBytes32(vtid);
        console.log("virtualInventoryForPositionsInTokens:");
        console.logInt(dataStore.getInt(GmxKeys.virtualInventoryForPositionsInTokensKey(vtid)));
        console.log("virtualInventoryForPositions (USD 1e30):");
        console.logInt(dataStore.getInt(GmxKeys.virtualInventoryForPositionsKey(vtid)));
    }

    /// Token-denominated OI for M_WSTETH (input to validateReserve).
    function test_ProbeWstethOiTokens() public {
        address mkt = 0x0Cf1fb4d1FF67A3D8Ca92c9d6643F8F9be8e03E5;
        address wsteth = address(0x5979D7b546E38E414F7E9822514be443A4800529);
        address usde = address(0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34);
        console.log("M_WSTETH OI tokens long wstETH-collat:", dataStore.getUint(GmxKeys.openInterestInTokensKey(mkt, wsteth, true)));
        console.log("M_WSTETH OI tokens long USDE-collat:", dataStore.getUint(GmxKeys.openInterestInTokensKey(mkt, usde, true)));
        console.log("M_WSTETH OI tokens short wstETH-collat:", dataStore.getUint(GmxKeys.openInterestInTokensKey(mkt, wsteth, false)));
        console.log("M_WSTETH OI tokens short USDE-collat:", dataStore.getUint(GmxKeys.openInterestInTokensKey(mkt, usde, false)));
        console.log("M_WSTETH collateral sum long wstETH-collat:", dataStore.getUint(GmxKeys.collateralSumKey(mkt, wsteth, true)));
        console.log("M_WSTETH collateral sum long USDE-collat:", dataStore.getUint(GmxKeys.collateralSumKey(mkt, usde, true)));
        console.log("M_WSTETH maxCollateralSum shortToken long:", dataStore.getUint(GmxKeys.maxCollateralSumKey(mkt, usde, true)));
        console.log("M_WSTETH maxCollateralSum longToken long:", dataStore.getUint(GmxKeys.maxCollateralSumKey(mkt, wsteth, true)));
    }

    function _logMarket(string memory label, address market) internal view {
        console.log("---", label, "---");
        console.log("posImpactFactor(+):", dataStore.getUint(GmxKeys.positionImpactFactorKey(market, true)));
        console.log("posImpactFactor(-):", dataStore.getUint(GmxKeys.positionImpactFactorKey(market, false)));
        console.log("posImpactExponent(+):", dataStore.getUint(GmxKeys.positionImpactExponentFactorKey(market, true)));
        console.log("posImpactExponent(-):", dataStore.getUint(GmxKeys.positionImpactExponentFactorKey(market, false)));
        console.log("maxPosImpactFactor(+):", dataStore.getUint(GmxKeys.maxPositionImpactFactorKey(market, true)));
        console.log("maxPosImpactFactor(-):", dataStore.getUint(GmxKeys.maxPositionImpactFactorKey(market, false)));
        console.log("maxPosImpactForLiquidations:", dataStore.getUint(GmxKeys.maxPositionImpactFactorForLiquidationsKey(market)));
        console.log("positionImpactPoolAmount:", dataStore.getUint(GmxKeys.positionImpactPoolAmountKey(market)));
        console.log("lentPositionImpactPoolAmount:", dataStore.getUint(GmxKeys.lentPositionImpactPoolAmountKey(market)));
        console.log("maxLendableImpactFactor:", dataStore.getUint(GmxKeys.maxLendableImpactFactorKey(market)));
        console.log("maxLendableImpactUsd:", dataStore.getUint(GmxKeys.maxLendableImpactUsdKey(market)));
        console.log("minCollateralFactor:", dataStore.getUint(GmxKeys.minCollateralFactorKey(market)));
        console.log("maxOpenInterest long:", dataStore.getUint(GmxKeys.maxOpenInterestKey(market, true)));
        console.log("maxOpenInterest short:", dataStore.getUint(GmxKeys.maxOpenInterestKey(market, false)));
        // OI in USD per collateral token (long token + short token as collateral)
        address longTok = market == M_WETH
            ? GmxArbitrumAddresses.WETH
            : market == M_WSTETH
                ? address(0x5979D7b546E38E414F7E9822514be443A4800529) // wstETH
                : GmxArbitrumAddresses.WETH;
        address shortTok = market == M_WETH
            ? GmxArbitrumAddresses.WETH
            : market == M_WSTETH
                ? address(0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34) // USDE
                : GmxArbitrumAddresses.USDC;
        console.log("OI long (longTok collat):", dataStore.getUint(GmxKeys.openInterestKey(market, longTok, true)));
        console.log("OI long (shortTok collat):", dataStore.getUint(GmxKeys.openInterestKey(market, shortTok, true)));
        console.log("OI short (longTok collat):", dataStore.getUint(GmxKeys.openInterestKey(market, longTok, false)));
        console.log("OI short (shortTok collat):", dataStore.getUint(GmxKeys.openInterestKey(market, shortTok, false)));
    }
}
