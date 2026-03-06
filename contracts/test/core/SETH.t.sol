// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { SETH } from "@core/SETH.sol";

// --------------------------------------------
//  SETH Unit Tests
// --------------------------------------------

contract SETHTest is Test {
    SETH public seth;
    address public adapter;

    receive() external payable { }

    function setUp() public {
        adapter = makeAddr("adapter");
        seth = new SETH(adapter);
    }

    // --------------------------------------------
    //  Collateral Exchange
    // --------------------------------------------

    function test_deposit_mintsAt100to1() public {
        vm.deal(address(this), 10 ether);
        seth.deposit{ value: 10 ether }();
        assertEq(seth.balanceOf(address(this)), 1000 ether);
        assertEq(address(seth).balance, 10 ether);
    }

    function test_withdraw_burnsAndSendsEth() public {
        vm.deal(address(this), 10 ether);
        seth.deposit{ value: 10 ether }();
        uint256 balanceBefore = address(this).balance;
        seth.withdraw(100 ether); // 100 SETH = 1 ETH
        assertEq(seth.balanceOf(address(this)), 900 ether);
        assertEq(address(this).balance - balanceBefore, 1 ether);
        assertEq(address(seth).balance, 9 ether);
    }

    function test_transfer_appliesFee() public {
        vm.deal(address(this), 10 ether);
        seth.deposit{ value: 10 ether }();
        address recipient = makeAddr("recipient");
        require(seth.transfer(recipient, 100 ether), "transfer failed");
        // 0.3% fee on 100 ether = 0.3 ether SETH
        assertEq(seth.balanceOf(recipient), 99.7 ether);
        assertEq(seth.accruedFeesInEth(), 0.003 ether);
    }

    function test_isFullyBacked_excludesAccruedFees() public {
        vm.deal(address(this), 10 ether);
        seth.deposit{ value: 10 ether }();
        address recipient = makeAddr("recipient");
        require(seth.transfer(recipient, 100 ether), "transfer failed"); // accrues fees
        (bool fullyBacked, uint256 ratioBps) = seth.isFullyBacked();
        assertTrue(fullyBacked);
        assertGe(ratioBps, 10000);
    }

    function test_ethCollateral_excludesAccruedFees() public {
        vm.deal(address(this), 10 ether);
        seth.deposit{ value: 10 ether }();
        require(seth.transfer(makeAddr("r"), 100 ether), "transfer failed");
        uint256 collateral = seth.ethCollateral();
        uint256 accrued = seth.accruedFeesInEth();
        assertEq(collateral, address(seth).balance - accrued);
    }

    // --------------------------------------------
    //  Constructor
    // --------------------------------------------

    function test_constructor_revertsOnZeroAdapter() public {
        vm.expectRevert(SETH.InvalidAddress.selector);
        new SETH(address(0));
    }

    // --------------------------------------------
    //  Adapter-Only (Cross-Chain)
    // --------------------------------------------

    function test_burn_revertsWhenNotAdapter() public {
        vm.deal(address(this), 10 ether);
        seth.deposit{ value: 10 ether }();
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(SETH.Unauthorized.selector);
        seth.burn(address(this), 100 ether);
    }

    function test_mint_revertsWhenNotAdapter() public {
        address recipient = makeAddr("recipient");
        vm.prank(recipient);
        vm.expectRevert(SETH.Unauthorized.selector);
        seth.mint(recipient, 100 ether);
    }

    function test_releaseCollateral_revertsWhenNotAdapter() public {
        vm.deal(address(this), 10 ether);
        seth.deposit{ value: 10 ether }();
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(SETH.Unauthorized.selector);
        seth.releaseCollateral(100 ether);
    }

    function test_receiveCollateral_revertsWhenNotAdapter() public {
        vm.deal(makeAddr("attacker"), 1 ether);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(SETH.Unauthorized.selector);
        seth.receiveCollateral{ value: 1 ether }();
    }
}
