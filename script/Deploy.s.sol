// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";
import {OGClubFarmVault} from "../src/OGClubFarmVault.sol";
import {OGClubStaking} from "../src/OGClubStaking.sol";
import {OGClubRaffle} from "../src/OGClubRaffle.sol";
import {MockOG} from "../src/mocks/MockOG.sol";

/// @notice Deployment preparation; no private keys are read. The owner grants the raffle's two roles afterwards.
contract Deploy is Script {
    uint256 public constant DEFAULT_POINTS_PER_TOKEN_DAY = 1e18;
    error InvalidConfiguration();
    error MockOnlyOnTestnets();

    /// @dev TOKEN must be an existing token. Mainnet requires a fresh deployer, OWNER Safe, RAFFLE_NOTICE=604800.
    function run()
        external
        returns (OGClubFurniture furniture, OGClubFarmVault vault, OGClubStaking staking, OGClubRaffle raffle)
    {
        address token = vm.envAddress("TOKEN");
        address owner = vm.envAddress("OWNER");
        uint256 notice = vm.envUint("RAFFLE_NOTICE");
        uint256 rate = vm.envOr("POINTS_PER_TOKEN_DAY", DEFAULT_POINTS_PER_TOKEN_DAY);
        vm.startBroadcast();
        (furniture, vault, staking, raffle) = deploy(token, owner, rate, notice);
        vm.stopBroadcast();
    }

    function deploy(address token, address owner, uint256 rate, uint256 notice)
        public
        returns (OGClubFurniture furniture, OGClubFarmVault vault, OGClubStaking staking, OGClubRaffle raffle)
    {
        if (token == address(0) || owner == address(0)) revert InvalidConfiguration();
        furniture = new OGClubFurniture(owner, owner);
        vault = new OGClubFarmVault(IERC20(token), owner);
        staking = new OGClubStaking(IERC20(token), address(vault), owner, rate);
        raffle = new OGClubRaffle(staking, furniture, owner, notice);
    }

    /// @notice Local/Sepolia helper matching launch.json. Returns contracts without impersonating OWNER for grants.
    function deploySepolia(address owner)
        external
        returns (
            MockOG token,
            OGClubFurniture furniture,
            OGClubFarmVault vault,
            OGClubStaking staking,
            OGClubRaffle raffle
        )
    {
        if (block.chainid != 11155111 && block.chainid != 31337) revert MockOnlyOnTestnets();
        if (owner == address(0)) revert InvalidConfiguration();
        token = new MockOG(owner);
        (furniture, vault, staking, raffle) = deploy(address(token), owner, DEFAULT_POINTS_PER_TOKEN_DAY, 0);
    }
}
