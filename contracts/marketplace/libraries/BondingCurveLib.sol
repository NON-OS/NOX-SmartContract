// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

library BondingCurveLib {
    uint256 internal constant CURVE_K = 1e10;
    uint256 internal constant SCALE   = 1e16;
    uint256 internal constant ONE = 1e18;
    uint256 internal constant BPS = 10000;
    uint256 internal constant MIN_PRICE = 1e6;

    error InvalidGraduationSupply();
    error InvalidFee();
    error AmountTooSmall();
    error SellExceedsSupply();

    function reserveAtSupply(uint256 supplyWei) internal pure returns (uint256 reserveWei) {
        uint256 sUnits = supplyWei / ONE;
        if (sUnits == 0) return 0;
        reserveWei = (CURVE_K * sUnits * sUnits * sUnits) / (3 * SCALE);
    }

    function priceAtSupply(uint256 supplyWei) internal pure returns (uint256 priceWeiPerToken) {
        uint256 sUnits = supplyWei / ONE;
        if (sUnits == 0) return MIN_PRICE;
        priceWeiPerToken = (CURVE_K * sUnits * sUnits) / SCALE;
        if (priceWeiPerToken < MIN_PRICE) priceWeiPerToken = MIN_PRICE;
    }

    function supplyAtReserve(uint256 reserveWei) internal pure returns (uint256 supplyWei) {
        if (reserveWei == 0) return 0;
        uint256 scaled = (3 * reserveWei * SCALE) / CURVE_K;
        uint256 sUnits = _icbrt(scaled);
        return sUnits * ONE;
    }

    function quoteBuy(
        uint256 currentSupplyWei,
        uint256 graduationSupplyWei,
        uint256 ethIn,
        uint16 feeBps
    ) internal pure returns (uint256 tokensOut, uint256 feeOut) {
        if (feeBps >= BPS) revert InvalidFee();
        if (graduationSupplyWei == 0) revert InvalidGraduationSupply();

        feeOut = (ethIn * feeBps) / BPS;
        uint256 ethAfterFee = ethIn - feeOut;
        if (ethAfterFee == 0) revert AmountTooSmall();

        uint256 currentReserve = reserveAtSupply(currentSupplyWei);
        uint256 newReserve = currentReserve + ethAfterFee;
        uint256 newSupply = supplyAtReserve(newReserve);

        if (newSupply > graduationSupplyWei) {
            newSupply = graduationSupplyWei;
        }
        if (newSupply <= currentSupplyWei) revert AmountTooSmall();

        tokensOut = newSupply - currentSupplyWei;
    }

    function quoteSell(
        uint256 currentSupplyWei,
        uint256 tokenAmountWei,
        uint16 feeBps
    ) internal pure returns (uint256 ethOut, uint256 feeOut) {
        if (feeBps >= BPS) revert InvalidFee();
        if (tokenAmountWei > currentSupplyWei) revert SellExceedsSupply();
        if (tokenAmountWei == 0) {
            return (0, 0);
        }

        uint256 newSupplyWei = currentSupplyWei - tokenAmountWei;
        uint256 currentReserve = reserveAtSupply(currentSupplyWei);
        uint256 newReserve = reserveAtSupply(newSupplyWei);
        uint256 grossEth = currentReserve - newReserve;

        feeOut = (grossEth * feeBps) / BPS;
        ethOut = grossEth - feeOut;
    }

    function graduationProgressBps(
        uint256 currentSupplyWei,
        uint256 graduationSupplyWei
    ) internal pure returns (uint256) {
        if (graduationSupplyWei == 0) return 0;
        if (currentSupplyWei >= graduationSupplyWei) return BPS;
        return (currentSupplyWei * BPS) / graduationSupplyWei;
    }

    function _icbrt(uint256 n) private pure returns (uint256) {
        if (n == 0) return 0;
        if (n < 8) return 1;

        uint256 x = n;
        uint256 r = 1;
        while (x >= 8) {
            x >>= 3;
            r <<= 1;
        }

        for (uint256 i = 0; i < 8; i++) {
            unchecked {
                uint256 r2 = r * r;
                if (r2 == 0 || r == 0) break;
                r = (2 * r + n / r2) / 3;
            }
        }

        unchecked {
            while (r > 0 && r * r * r > n) {
                r--;
            }
            while (true) {
                uint256 next = r + 1;
                if (next == 0) break;
                uint256 nc = next * next * next;
                if (nc == 0 || nc > n) break;
                r = next;
            }
        }
        return r;
    }
}
