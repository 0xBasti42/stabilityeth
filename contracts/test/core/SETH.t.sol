// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { SETH } from "@core/SETH.sol";

// --------------------------------------------
//  SETH Unit Tests
// --------------------------------------------

contract SETHTest is Test {
    SETH public seth;
    address public adapter;

    /// @notice Chainlink ETH/USD feed; address(0) uses DynamicFee fallback ($3000)
    address constant CHAINLINK_ETH_USD = address(0);

    receive() external payable { }

    function setUp() public {
        adapter = makeAddr("adapter");
        seth = new SETH(adapter, CHAINLINK_ETH_USD);
    }

    // --------------------------------------------
    //  Collateral Exchange
    // --------------------------------------------

    function test_deposit_mintsAt100to1() public {
        uint256 depositAmount = 10 ether;
        vm.deal(address(this), depositAmount);
        uint256 feeBps = seth.calculateDynamicFee(depositAmount);
        uint256 expectedFee = (depositAmount * feeBps) / 10_000;
        uint256 expectedSeth = (depositAmount - expectedFee) * seth.EXCHANGE_RATE();

        seth.deposit{ value: depositAmount }();

        uint256 sethBalance = seth.balanceOf(address(this));
        assertApproxEqAbs(sethBalance, expectedSeth, 1 ether, "SETH minted");
        assertEq(address(seth).balance, depositAmount);
        assertApproxEqAbs(seth.accruedFeesInEth(), expectedFee, 0.01 ether, "accrued fees");
    }

    function test_withdraw_burnsAndSendsEth() public {
        vm.deal(address(this), 10 ether);
        seth.deposit{ value: 10 ether }();
        uint256 sethBefore = seth.balanceOf(address(this));
        uint256 balanceBefore = address(this).balance;
        seth.withdraw(100 ether); // 100 SETH = 1 ETH; dynamic fee ~3.8% on 1 ETH
        assertEq(seth.balanceOf(address(this)), sethBefore - 100 ether);
        assertApproxEqAbs(address(this).balance - balanceBefore, 0.962 ether, 0.01 ether);
        assertApproxEqAbs(address(seth).balance, 9.038 ether, 0.01 ether);
    }

    function test_transfer_noFee() public {
        vm.deal(address(this), 10 ether);
        seth.deposit{ value: 10 ether }();
        address recipient = makeAddr("recipient");
        uint256 accruedBefore = seth.accruedFeesInEth();
        require(seth.transfer(recipient, 100 ether), "transfer failed");
        // No fee on transfer; recipient gets full amount
        assertEq(seth.balanceOf(recipient), 100 ether);
        assertEq(seth.accruedFeesInEth(), accruedBefore); // No additional fee from transfer
    }

    function test_isFullyBacked_excludesAccruedFees() public {
        vm.deal(address(this), 10 ether);
        seth.deposit{ value: 10 ether }(); // accrues 0.3% fee on deposit
        address recipient = makeAddr("recipient");
        require(seth.transfer(recipient, 100 ether), "transfer failed");
        (bool fullyBacked, uint256 ratioBps) = seth.isFullyBacked();
        assertTrue(fullyBacked);
        assertGe(ratioBps, 10_000);
    }

    function test_ethCollateral_excludesAccruedFees() public {
        vm.deal(address(this), 10 ether);
        seth.deposit{ value: 10 ether }(); // accrues fee on deposit
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
        new SETH(address(0), CHAINLINK_ETH_USD);
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

    function test_burn_releasesEthToAdapter() public {
        vm.deal(address(this), 10 ether);
        seth.deposit{ value: 10 ether }();
        uint256 balanceBefore = seth.balanceOf(address(this));
        uint256 adapterBalanceBefore = adapter.balance;
        vm.prank(adapter);
        seth.burn(address(this), 100 ether); // 100 SETH = 1 ETH released
        assertEq(adapter.balance - adapterBalanceBefore, 1 ether);
        assertEq(seth.balanceOf(address(this)), balanceBefore - 100 ether);
    }

    function test_mint_revertsWhenWrongEthAmount() public {
        vm.deal(adapter, 2 ether);
        vm.prank(adapter);
        vm.expectRevert(SETH.InvalidAmount.selector);
        seth.mint{ value: 2 ether }(address(this), 100 ether); // 100 SETH expects 1 ether, not 2
    }

    function test_mint_successWhenAdapterSendsCorrectEth() public {
        vm.deal(adapter, 1 ether);
        vm.prank(adapter);
        seth.mint{ value: 1 ether }(address(this), 100 ether);
        assertEq(seth.balanceOf(address(this)), 100 ether);
        assertEq(address(seth).balance, 1 ether);
    }
}
