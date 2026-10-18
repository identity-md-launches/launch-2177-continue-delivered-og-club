// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";
import {OGClubFarmVault} from "../src/OGClubFarmVault.sol";
import {OGClubStaking} from "../src/OGClubStaking.sol";
import {OGClubRaffle} from "../src/OGClubRaffle.sol";
import {MockOG} from "../src/mocks/MockOG.sol";

contract DeploymentTest is Test {
    function test_SepoliaDeploymentAndOwnerSetup() public {
        vm.chainId(11155111);
        address owner = makeAddr("launch owner");
        Deploy script = new Deploy();
        (MockOG token, OGClubFurniture furniture, OGClubFarmVault vault, OGClubStaking staking, OGClubRaffle raffle) =
            script.deploySepolia(owner);
        assertEq(token.balanceOf(owner), token.INITIAL_SUPPLY());
        assertEq(furniture.owner(), owner);
        assertEq(vault.owner(), owner);
        assertEq(staking.owner(), owner);
        assertEq(raffle.owner(), owner);
        assertEq(address(vault.token()), address(token));
        assertEq(address(staking.token()), address(token));
        assertEq(staking.vault(), address(vault));
        assertEq(address(raffle.staking()), address(staking));
        assertEq(address(raffle.furniture()), address(furniture));
        assertEq(staking.pointsPerTokenDay(), 1e18);
        assertEq(raffle.raffleNotice(), 0);
        assertFalse(furniture.bootstrapped());
        assertFalse(staking.bootstrapped());
        vm.startPrank(owner);
        furniture.grantMinter(address(raffle));
        staking.grantSpender(address(raffle));
        vm.stopPrank();
        assertTrue(furniture.minters(address(raffle)));
        assertTrue(staking.spenders(address(raffle)));
        checkRuntime(address(token).code);
        checkRuntime(address(furniture).code);
        checkRuntime(address(vault).code);
        checkRuntime(address(staking).code);
        checkRuntime(address(raffle).code);
    }

    function checkRuntime(bytes memory code) internal pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
        }
    }

    function test_ConstructorsDoNotCallDependenciesOrAssignFactoryOwner() public {
        address owner = makeAddr("owner");
        address absent = makeAddr("absent dependency");
        OGClubStaking staking = new OGClubStaking(IERC20(absent), owner, owner, 1e18);
        OGClubFarmVault vault = new OGClubFarmVault(IERC20(absent), owner);
        OGClubRaffle raffle = new OGClubRaffle(OGClubStaking(absent), OGClubFurniture(absent), owner, 7 days);
        assertEq(staking.owner(), owner);
        assertEq(vault.owner(), owner);
        assertEq(raffle.owner(), owner);
        assertEq(raffle.raffleNotice(), 604800);
        assertEq(staking.accrualDenominator(), 0);
    }

    function test_InvalidConfigurationAndConstructorBounds() public {
        address owner = makeAddr("owner");
        IERC20 token = IERC20(makeAddr("token"));
        OGClubFurniture furniture = new OGClubFurniture(owner, owner);
        vm.expectRevert(OGClubStaking.InvalidAddress.selector);
        new OGClubStaking(IERC20(address(0)), owner, owner, 1e18);
        vm.expectRevert(OGClubStaking.InvalidAddress.selector);
        new OGClubStaking(token, address(0), owner, 1e18);
        vm.expectRevert(OGClubStaking.InvalidRate.selector);
        new OGClubStaking(token, owner, owner, 0);
        vm.expectRevert(OGClubStaking.InvalidRate.selector);
        new OGClubStaking(token, owner, owner, uint256(type(uint96).max) + 1);
        vm.expectRevert(OGClubFarmVault.InvalidAddress.selector);
        new OGClubFarmVault(IERC20(address(0)), owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new OGClubFarmVault(token, address(0));
        OGClubStaking staking = new OGClubStaking(token, owner, owner, 1e18);
        OGClubRaffle widest = new OGClubRaffle(staking, furniture, owner, 30 days);
        assertEq(widest.raffleNotice(), 30 days);
        vm.expectRevert(OGClubRaffle.InvalidNotice.selector);
        new OGClubRaffle(staking, furniture, owner, 30 days + 1);
        vm.expectRevert(OGClubRaffle.InvalidAddress.selector);
        new OGClubRaffle(staking, OGClubFurniture(address(0)), owner, 0);
        vm.expectRevert(OGClubRaffle.InvalidAddress.selector);
        new OGClubRaffle(OGClubStaking(address(0)), furniture, owner, 0);
        Deploy script = new Deploy();
        vm.expectRevert(Deploy.InvalidConfiguration.selector);
        script.deploy(address(0), owner, 1e18, 0);
        vm.chainId(1);
        vm.expectRevert(Deploy.MockOnlyOnTestnets.selector);
        script.deploySepolia(owner);
    }

    function test_MockIsDeliberatelyUnlimitedTestnetOnly() public {
        address recipient = makeAddr("recipient");
        MockOG token = new MockOG(recipient);
        assertEq(token.symbol(), "mockog");
        assertEq(token.decimals(), 18);
        assertEq(token.balanceOf(recipient), token.INITIAL_SUPPLY());
        vm.prank(makeAddr("anyone"));
        token.mint(recipient, 7 ether);
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY() + 7 ether);
    }
}
