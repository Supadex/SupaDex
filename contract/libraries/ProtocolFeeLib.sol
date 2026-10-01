// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMathLib} from "./FullMathLib.sol";

/**
 * @title ProtocolFeeLib
 * @notice Pure helpers for splitting swap fees between LPs and the protocol.
 * @dev `protocolFee` is stored in Slot0 as hundredths of a bip applied to the swap fee amount
 *      (same units as pool `fee`): protocolTake = feeAmount * protocolFee / 1e6.
 */
library ProtocolFeeLib {
    uint24 internal constant MAX_PROTOCOL_FEE = 1_000_000; // 100% of fee amount

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
        if (protocolFee >= MAX_PROTOCOL_FEE) {
            return (0, feeAmount);
        }
        protocolTake = FullMathLib.mulDiv(feeAmount, protocolFee, MAX_PROTOCOL_FEE);
        lpFee = feeAmount - protocolTake;
    }
}
