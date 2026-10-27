// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @notice GoatChainlinkFeeds: the Chainlink USD proxy addresses on Robinhood Chain (chain ID 4663) that
 *         `GoatPriceAnchor` receives in its constructor as its initial feed table. A library, so it holds
 *         no state on chain.
 *
 * @dev Each row pairs a token on Robinhood's official token list (docs.robinhood.com/chain/contracts)
 *      with the standard Chainlink proxy for it (`proxyAddress`, not the SVR variant), listed in
 *      Chainlink's directory for Robinhood Chain. Each feed reports 8 decimals, has a description that
 *      names the ticker, a single phase and `answeredInRound >= roundId`, and its price was compared
 *      with the deepest live pool. A token with the same name or ticker at another address is not a
 *      Robinhood token and is not listed.
 *
 * @dev uiMultiplier (ERC-8056): the Chainlink answer is already per raw token, multiplier included, so
 *      it is not applied again.
 *
 * @dev Not listed: GLD (its feed is derived from DEX prices, which is circular as an anchor for DEX
 *      pools); ORCL, EWY, CLSK, IONQ and RGTI (their feed price could not be matched with a pool); crypto
 *      feeds whose token has no official Robinhood address (BTC, USDC, USDT and others).
 *
 * @dev The hard-coded address is the proxy; the aggregator behind it can change without an event. The
 *      table can be changed later through `GoatPriceAnchor.queueFeed`, which waits 24 hours.
 *
 * @dev Stock feeds update 24/5 (Sunday 20:00 ET to Friday 20:00 ET) and keep their last value over the
 *      weekend (see `GoatPriceAnchor.MAX_FEED_AGE`).
 *
 * @dev Every row has a 24-hour heartbeat and a 0.5% deviation threshold; the anchor rejects answers
 *      above `GoatPriceAnchor.MAX_FEED_ANSWER`. For the two rows that update around the clock (WETH and
 *      USDG) the anchor's constructor writes a 25-hour age limit from `initialMaxAge` into `feedMaxAge`,
 *      so it applies from deployment with no queued change. Stock rows keep 0, the 5-day default. Later
 *      changes go through `queueFeedMaxAge`, a 24-hour wait, then `applyFeedMaxAge`.
 */
library GoatChainlinkFeeds {
    address internal constant WETH  = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant USDG  = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant AAPL  = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant AMD   = 0x86923f96303D656E4aa86D9d42D1e57ad2023fdC;
    address internal constant AMZN  = 0x12f190a9F9d7D37a250758b26824B97CE941bF54;
    address internal constant ASML  = 0x47F93d52cBeC7C6D2CfC080e154002370a60dAEA;
    address internal constant BABA  = 0xad25Ac6C84D497db898fa1E8387bf6Af3532a1c4;
    address internal constant COIN  = 0x6330D8C3178a418788dF01a47479c0ce7CCF450b;
    address internal constant CRCL  = 0xdF0992E440dD0be65BD8439b609d6D4366bf1CB5;
    address internal constant CRWV  = 0x5f10A1C971B69e47e059e1dC91901B59b3fB49C3;
    address internal constant DELL  = 0x941AE714EC6D8130c7B75d67160Ca08f1e7d11Dd;
    address internal constant GME   = 0x1b0E319c6A659F002271B69dB8A7df2F911c153E;
    address internal constant GOOGL = 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3;
    address internal constant INTC  = 0xc72b96e0E48ecd4DC75E1e45396e26300BC39681;
    address internal constant META  = 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35;
    address internal constant MSFT  = 0xe93237C50D904957Cf27E7B1133b510C669c2e74;
    address internal constant MSTR  = 0xec262a75e413fAfD0dF80480274532C79D42da09;
    address internal constant MU    = 0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD;
    address internal constant NBIS  = 0x9D9c6684F596F66a64C030B93A886D51Fd4D7931;
    address internal constant NVDA  = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant PLTR  = 0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A;
    address internal constant QQQ   = 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68;
    address internal constant RKLB  = 0x3b14C39E89D60D627b42a1A4CA45b5bb45Fc12e2;
    address internal constant SGOV  = 0x92FD66527192E3e61d4DDd13322Aa222DE86F9B5;
    address internal constant SLV   = 0x411eFb0E7f985935DAec3D4C3ebaEa0d0AD7D89f;
    address internal constant SNDK  = 0xB90A19fF0Af67f7779afF50A882A9CfF42446400;
    address internal constant SPCX  = 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa;
    address internal constant SPY   = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address internal constant TSLA  = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address internal constant TSM   = 0x58FfE4a942d3885bAa22D7520691F611EF09e7AA;
    address internal constant USAR  = 0xd917B029C761D264c6A312BBbcDA868658eF86a6;
    address internal constant USO   = 0xa30FA36Db767ad9eD3f7a60fC79526fB4d56D344;

    // Chainlink USD proxies. Each trailing comment is the feed's on-chain description().
    address internal constant FEED_ETH_USD   = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9; // "ETH / USD"
    address internal constant FEED_USDG_USD  = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2; // "USDG / USD"
    address internal constant FEED_AAPL_USD  = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0; // "Robinhood AAPL / USD"
    address internal constant FEED_AMD_USD   = 0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72; // "RHAMD / USD"
    address internal constant FEED_AMZN_USD  = 0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C; // "Robinhood AMZN / USD"
    address internal constant FEED_ASML_USD  = 0xB4106147E8cce40b7d46124090d373A71b70f87D; // "Robinhood ASML / USD"
    address internal constant FEED_BABA_USD  = 0x62Cc8F9b5f56a33c9C8A60c8B92779f523c4E984; // "Robinhood BABA / USD"
    address internal constant FEED_COIN_USD  = 0xA3a468A452940B7D6b69991207B508c609a98Ef2; // "Robinhood COIN / USD"
    address internal constant FEED_CRCL_USD  = 0x6652eDf64bA3731C4F2D3ce821A0Fb1f1f6b482a; // "Robinhood CRCL / USD"
    address internal constant FEED_CRWV_USD  = 0xe1b3aABCAFAd1c94708dc1367dcfF8Aa4407487C; // "Robinhood CRWV / USD"
    address internal constant FEED_DELL_USD  = 0x1C6c8cADBe02E19129c39dDB92281cE4c0bf206b; // Robinhood DELL/USD (the description uses a hyphen)
    address internal constant FEED_GME_USD   = 0x27C71df6A64fB476468EdF256CF72c038baB5B67; // "Robinhood GME / USD"
    address internal constant FEED_GOOGL_USD = 0xF6f373a037c30F0e5010d854385cA89185AE638b; // "Robinhood GOOGL / USD"
    address internal constant FEED_INTC_USD  = 0x3f390C5C24628Ac7C489515402235FeAD71D1913; // "RHINTC / USD"
    address internal constant FEED_META_USD  = 0x7C38C00C30BEe9378381E7B6135d7283356D71b1; // "Robinhood META / USD"
    address internal constant FEED_MSFT_USD  = 0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E; // "RHMSFT / USD"
    address internal constant FEED_MSTR_USD  = 0x396118bdFB181e6240E74D243F266B061c0edc3D; // "Robinhood MSTR / USD"
    address internal constant FEED_MU_USD    = 0x425EEFdCf05ed6526C3cE61Af99429A228a6d596; // "RHMU / USD"
    address internal constant FEED_NBIS_USD  = 0xE1D87B116Ba0fe898998f1D140339D1fA1E09705; // "Robinhood NBIS / USD"
    address internal constant FEED_NVDA_USD  = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15; // "RHNVDA / USD"
    address internal constant FEED_PLTR_USD  = 0x820ABedFF239034956B7A9d2F0a331f9F075eB4c; // "Robinhood PLTR / USD"
    address internal constant FEED_QQQ_USD   = 0x80901d846d5D7B030F26B480776EE3b29374C2ae; // "Robinhood QQQ / USD"
    address internal constant FEED_RKLB_USD  = 0x045477BF65Aef6f4F2386ad0164579e48381CC74; // "Robinhood RKLB / USD"
    address internal constant FEED_SGOV_USD  = 0xa0DF4ee0fFf975306345875E3548Fcc519577A11; // Robinhood SGOV/USD (the description uses a hyphen)
    address internal constant FEED_SLV_USD   = 0x209b73908e92Ae021826eD79609845451Ecba2ce; // "Robinhood SLV / USD"
    address internal constant FEED_SNDK_USD  = 0xfb133Fa4B7b385802B693a293606682Df47109A3; // "RHSNDK / USD"
    address internal constant FEED_SPCX_USD  = 0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb; // "Robinhood SPCX / USD"
    address internal constant FEED_SPY_USD   = 0x319724394D3A0e3669269846abE664Cd621f9f6A; // "RHSPY / USD"
    address internal constant FEED_TSLA_USD  = 0x4A1166a659A55625345e9515b32adECea5547C38; // "RHTSLA / USD"
    address internal constant FEED_TSM_USD   = 0x874cF94aa8eC88Fd9560094dD065f2fB3E41Fc2F; // "Robinhood TSM / USD"
    address internal constant FEED_USAR_USD  = 0xA994d3684e8400A6c8078226925779FdeE682DD9; // Robinhood USAR/USD (the description uses a hyphen)
    address internal constant FEED_USO_USD   = 0x75a9c76Ef439e2C7c2E5a34Ab105EcFe3766431c; // "RHUSO / USD"

    /// @notice The (token, feed) pairs; `tokens[i]` is priced by `feeds[i]`.
    function table() internal pure returns (address[] memory tokens, address[] memory feeds) {
        tokens = new address[](32);
        feeds = new address[](32);
        tokens[0] = WETH; feeds[0] = FEED_ETH_USD;
        tokens[1] = USDG; feeds[1] = FEED_USDG_USD;
        tokens[2] = AAPL; feeds[2] = FEED_AAPL_USD;
        tokens[3] = AMD; feeds[3] = FEED_AMD_USD;
        tokens[4] = AMZN; feeds[4] = FEED_AMZN_USD;
        tokens[5] = ASML; feeds[5] = FEED_ASML_USD;
        tokens[6] = BABA; feeds[6] = FEED_BABA_USD;
        tokens[7] = COIN; feeds[7] = FEED_COIN_USD;
        tokens[8] = CRCL; feeds[8] = FEED_CRCL_USD;
        tokens[9] = CRWV; feeds[9] = FEED_CRWV_USD;
        tokens[10] = DELL; feeds[10] = FEED_DELL_USD;
        tokens[11] = GME; feeds[11] = FEED_GME_USD;
        tokens[12] = GOOGL; feeds[12] = FEED_GOOGL_USD;
        tokens[13] = INTC; feeds[13] = FEED_INTC_USD;
        tokens[14] = META; feeds[14] = FEED_META_USD;
        tokens[15] = MSFT; feeds[15] = FEED_MSFT_USD;
        tokens[16] = MSTR; feeds[16] = FEED_MSTR_USD;
        tokens[17] = MU; feeds[17] = FEED_MU_USD;
        tokens[18] = NBIS; feeds[18] = FEED_NBIS_USD;
        tokens[19] = NVDA; feeds[19] = FEED_NVDA_USD;
        tokens[20] = PLTR; feeds[20] = FEED_PLTR_USD;
        tokens[21] = QQQ; feeds[21] = FEED_QQQ_USD;
        tokens[22] = RKLB; feeds[22] = FEED_RKLB_USD;
        tokens[23] = SGOV; feeds[23] = FEED_SGOV_USD;
        tokens[24] = SLV; feeds[24] = FEED_SLV_USD;
        tokens[25] = SNDK; feeds[25] = FEED_SNDK_USD;
        tokens[26] = SPCX; feeds[26] = FEED_SPCX_USD;
        tokens[27] = SPY; feeds[27] = FEED_SPY_USD;
        tokens[28] = TSLA; feeds[28] = FEED_TSLA_USD;
        tokens[29] = TSM; feeds[29] = FEED_TSM_USD;
        tokens[30] = USAR; feeds[30] = FEED_USAR_USD;
        tokens[31] = USO; feeds[31] = FEED_USO_USD;
    }

    /// @notice Age limit set at deployment for the two rows that update around the clock (WETH with
    /// "ETH / USD", USDG with "USDG / USD", 24-hour heartbeat): 25 hours. Any other (token, feed) gets 0,
    /// which means `MAX_FEED_AGE`.
    /// @dev Token and feed must both match, because the limit follows the feed's update schedule. The same
    /// token installed with a different feed keeps the default.
    function initialMaxAge(address token, address feed) internal pure returns (uint32) {
        if ((token == WETH && feed == FEED_ETH_USD) || (token == USDG && feed == FEED_USDG_USD)) {
            return 25 hours;
        }
        return 0;
    }
}
