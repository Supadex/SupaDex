// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMathLib} from "./FullMathLib.sol";

/**
 * @title ProtocolFeeLib
 * @notice Pure helpers for splitting swap fees between LPs and the protocol.
 * @dev `protocolFee` is stored in Slot0 as hundredths of a bip applied to the swap fee amount
 *      (same units as pool `fee`): protocolTake = feeAmount * protocolFee / 1e6.
 *      The protocol may take at most 25% of the swap fee (Uniswap v3's maximum, 1/4). 100% is rejected
 *      so governance cannot redirect every LP fee to the protocol (L-04).
 */
library ProtocolFeeLib {
    /// @dev Denominator for `protocolFee`. 1_000_000 = 100% of the swap fee.
    uint24 internal constant PROTOCOL_FEE_DENOMINATOR = 1_000_000;

    /// @notice Hard ceiling: 25% of the swap fee. Strictly below 100%.
    uint24 internal constant MAX_PROTOCOL_FEE = 250_000;

    /**
     * @notice Splits a swap fee amount into LP and protocol portions.
     * @param feeAmount Total fee charged on the swap input.
     * @param protocolFee Protocol take rate in hundredths of a bip of `feeAmount`.
     * @return lpFee Amount credited to LP fee growth.
     * @return protocolTake Amount accrued to the protocol.
     */
    function splitFee(uint256 feeAmount, uint24 protocolFee)
        internal
        pure
        returns (uint256 lpFee, uint256 protocolTake)
    {
        if (feeAmount == 0 || protocolFee == 0) {
            return (feeAmount, 0);
        }
        // Defence in depth: a stored rate above the ceiling still cannot take more than 25%.
        uint256 rate = protocolFee > MAX_PROTOCOL_FEE ? uint256(MAX_PROTOCOL_FEE) : uint256(protocolFee);
        protocolTake = FullMathLib.mulDiv(feeAmount, rate, PROTOCOL_FEE_DENOMINATOR);
        lpFee = feeAmount - protocolTake;
    }
}
