// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TestMintableERC20} from "../contract/test/TestMintableERC20.sol";

/**
 * @title DeployTestTokens
 * @notice Deploys 10 diversified test ERC-20 tokens with 1,000,000 initial supply to the deployer.
 */
contract DeployTestTokens is Script {
    struct TokenInfo {
        string name;
        string symbol;
        uint8 decimals;
        uint256 initialSupply;
    }

    function run() external {
        uint256 deployerPrivateKey =
            vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address deployer = vm.addr(deployerPrivateKey);

        TokenInfo[10] memory tokens = [
            TokenInfo("USD Coin", "USDC", 6, 1_000_000 * 10 ** 6),
            TokenInfo("Tether USD", "USDT", 6, 1_000_000 * 10 ** 6),
            TokenInfo("Dai Stablecoin", "DAI", 18, 1_000_000 * 10 ** 18),
            TokenInfo("Wrapped Bitcoin", "WBTC", 8, 1_000 * 10 ** 8),
            TokenInfo("Wrapped Ether", "WETH", 18, 10_000 * 10 ** 18),
            TokenInfo("SupaDex Governance", "SUPA", 18, 10_000_000 * 10 ** 18),
            TokenInfo("Chainlink Token", "LINK", 18, 500_000 * 10 ** 18),
            TokenInfo("Uniswap", "UNI", 18, 500_000 * 10 ** 18),
            TokenInfo("Aave Token", "AAVE", 18, 250_000 * 10 ** 18),
            TokenInfo("Arbitrum", "ARB", 18, 2_000_000 * 10 ** 18)
        ];

        vm.startBroadcast(deployerPrivateKey);

        console2.log("=== Deploying 10 Diversified Test Tokens ===");
        console2.log("Recipient / Deployer:", deployer);

        for (uint256 i = 0; i < tokens.length; i++) {
            TestMintableERC20 token = new TestMintableERC20(
                tokens[i].name,
                tokens[i].symbol,
                tokens[i].decimals,
                deployer,
                tokens[i].initialSupply
            );
            console2.log(string.concat(tokens[i].symbol, ":"), address(token));
        }

        vm.stopBroadcast();
        console2.log("=== Test Tokens Deployed Successfully ===");
    }
}
