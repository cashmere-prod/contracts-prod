// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

// Founding NC rows of GoatPairTable (pairs priced from a reference pool, see NcCfg). cap and capX are the hourly swap
// budgets in raw units: cap in the hard leg (the token with a Chainlink price), capX in the X leg. They are sized from
// the depth of each reference pool; a source pool used by more than one listing shares one budget between them.

import "./GoatPairTypes.sol";

library GoatFoundingNc {
    function rows() internal pure returns (NcRow[] memory r) {
        r = new NcRow[](7);
        // RDDT/USDG: X = RDDT (stock token, market hours), reference pool fee tier 10000, SR 150 ticks/h
        r[0] = NcRow(0x05b37Fb53A299a1b874A619e1c4C404D52C36F4C, 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168, NcCfg(0xa8744E76aED23B05F0126335E7BD38f7935D19fe, 150, 150, false, true, 150, 2618948673, 17232149325552345519, FeedCfg(0x61B7e5650328764B076A108EFF5fa7282a1B9aD2, 8, 6, false, 90_000, 90000000, 110000000)));
        // CASHCAT/WETH: X = CASHCAT, reference pool fee tier 10000, SR 1000 ticks/h
        r[1] = NcRow(0x020bfC650A365f8BB26819deAAbF3E21291018b4, 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, NcCfg(0xA70fc67C9F69da90B63a0e4C05D229954574E313, 150, 150, false, false, 1000, 1679434546218415192, 36977747011852919999902, FeedCfg(0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9, 8, 18, false, 90_000, 10000000000, 10000000000000)));
        // WETH/PONS: X = PONS, reference pool fee tier 10000, SR 600 ticks/h (budget shared with v4 PONS/USDG)
        r[2] = NcRow(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, 0x39dBED3a2bd333467115dE45665cC57F813C4571, NcCfg(0x10CC6BD38112cAc182db90B6a71d8Bb5939526bA, 150, 150, true, false, 600, 1633675022143809370, 10323876281989107850036, FeedCfg(0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9, 8, 18, false, 90_000, 10000000000, 10000000000000)));
        // USDG/HIMS: X = HIMS (stock token, market hours), reference pool fee tier 3000, SR 150 ticks/h
        r[3] = NcRow(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168, 0xCceE82fE024c36fA15E1005edE3E9e4787e23D09, NcCfg(0xC8C90d3a1c1a24967E773ac2aD0d456BA3E31F64, 150, 150, true, true, 150, 3459962472, 122072387549416754125, FeedCfg(0x61B7e5650328764B076A108EFF5fa7282a1B9aD2, 8, 6, false, 90_000, 90000000, 110000000)));
        // WETH/DELTA: X = DELTA, reference pool fee tier 10000, SR 300 ticks/h
        r[4] = NcRow(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, 0xe8ffd7e24187F72afB08d75B1bb13088A989a791, NcCfg(0xD64FbdA67E1015dF43Fa5e49F02cA844729E5F94, 150, 150, true, false, 300, 924325620941721004, 196447747094023744765456, FeedCfg(0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9, 8, 18, false, 90_000, 10000000000, 10000000000000)));
        // WETH/PIPEDOG: X = PIPEDOG, reference pool fee tier 10000, SR 300 ticks/h
        r[5] = NcRow(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, 0x5Cb6F181081301b44905F3ae15419112ecaBd8A6, NcCfg(0xB7f10f74B39291b9290b779978e19A7637C742D6, 150, 150, true, false, 300, 1101896357063741411, 2413534165834876475820021, FeedCfg(0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9, 8, 18, false, 90_000, 10000000000, 10000000000000)));
        // USDG/GLD: X = GLD (stock token, market hours), reference pool fee tier 500, SR 300 ticks/h
        r[6] = NcRow(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168, 0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e, NcCfg(0xBA2f1ed4cEB2169D538d1e614D847E83C5A55913, 150, 150, true, true, 300, 3518655526, 9311374439822379512, FeedCfg(0x61B7e5650328764B076A108EFF5fa7282a1B9aD2, 8, 6, false, 90_000, 90000000, 110000000)));
    }
}
