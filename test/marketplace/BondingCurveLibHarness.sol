// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {BondingCurveLib} from "../../contracts/marketplace/libraries/BondingCurveLib.sol";

contract BondingCurveLibHarness {
    function quoteBuy(
        uint256 supply,
        uint256 graduationSupply,
        uint256 ethIn,
        uint16 feeBps
    ) external pure returns (uint256, uint256) {
        return BondingCurveLib.quoteBuy(supply, graduationSupply, ethIn, feeBps);
    }

    function quoteSell(
        uint256 supply,
        uint256 tokenAmount,
        uint16 feeBps
    ) external pure returns (uint256, uint256) {
        return BondingCurveLib.quoteSell(supply, tokenAmount, feeBps);
    }
}
