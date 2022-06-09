pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {Authority} from "solmate/auth/Auth.sol";
import {MultiRolesAuthority} from "solmate/auth/authorities/MultiRolesAuthority.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {IERC1155Receiver} from "openzeppelin/token/ERC1155/IERC1155Receiver.sol";
import {ERC721} from "openzeppelin/token/ERC721/ERC721.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";
import {ICollateralVault, CollateralVault, LienToken, ILienToken} from "../CollateralVault.sol";
import {MockERC721} from "solmate/test/utils/mocks/MockERC721.sol";
import {IBrokerRouter, BrokerRouter} from "../BrokerRouter.sol";
import {AuctionHouse} from "gpl/AuctionHouse.sol";
import {Strings2} from "./utils/Strings2.sol";
import {IBroker, SoloBroker, BrokerImplementation} from "../BrokerImplementation.sol";
import {BrokerVault} from "../BrokerVault.sol";
import {TransferProxy} from "../TransferProxy.sol";
import {BeaconProxy} from "openzeppelin/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

import {TestHelpers, Dummy721, IWETH9} from "./TestHelpers.sol";

string constant weth9Artifact = "src/tests/WETH9.json";

//TODO:
// - setup helpers to repay loans
// - setup helpers to pay loans at their schedule
// - test for interest
// - test auction flow
// - create/cancel/end
contract AstariaTest is TestHelpers {
    /**
       Ensure that we can borrow capital from the bond controller
       ensure that we're emitting the correct events
       ensure that we're repaying the proper collateral
   */
    function testCommitToLoan() public {
        //        address tokenContract = address(
        //            0x938e5ed128458139A9c3306aCE87C60BCBA9c067
        //        );
        //        uint256 tokenId = uint256(10);
        //
        //        _hijackNFT(tokenContract, tokenId);

        Dummy721 loanTest = new Dummy721();
        address tokenContract = address(address(loanTest));
        uint256 tokenId = uint256(1);
        uint256 maxAmount = uint256(100000000000000000000);
        uint256 interestRate = uint256(50000000000000000000);
        uint256 duration = uint256(block.timestamp + 10 minutes);
        uint256 amount = uint256(1 ether);
        uint8 lienPosition = uint8(0);
        uint256 schedule = uint256(50);

        uint256 balanceBefore = WETH9.balanceOf(address(this));
        //balance of WETH before loan
        (bytes32 vaultHash, ) = _commitToLoan(
            tokenContract,
            tokenId,
            maxAmount,
            interestRate,
            duration,
            amount,
            lienPosition,
            schedule
        );

        //assert weth balance is before + 1 ether
        assert(WETH9.balanceOf(address(this)) == balanceBefore + 1 ether);
    }

    function testReleaseToAddress() public {
        Dummy721 releaseTest = new Dummy721();
        address tokenContract = address(releaseTest);
        uint256 tokenId = uint256(1);
        _depositNFTs(tokenContract, tokenId);
        // startMeasuringGas("ReleaseTo Address");

        COLLATERAL_VAULT.releaseToAddress(
            uint256(keccak256(abi.encodePacked(tokenContract, tokenId))),
            address(this)
        );
        // stopMeasuringGas();
    }

    /**
        Ensure that asset's that have liens cannot be released to Anyone.
     */
    function testLiens() public {
        //trigger loan commit
        //try to release asset

        Dummy721 loanTest = new Dummy721();
        address tokenContract = address(address(loanTest));
        uint256 tokenId = uint256(1);
        uint256 maxAmount = uint256(100000000000000000000);
        uint256 interestRate = uint256(50000000000000000000);
        uint256 duration = uint256(block.timestamp + 10 minutes);
        uint256 amount = uint256(1 ether);
        uint8 lienPosition = uint8(0);
        uint256 schedule = uint256(50);
        (
            bytes32 vaultHash,
            ICollateralVault.Terms memory terms
        ) = _commitToLoan(
                tokenContract,
                tokenId,
                maxAmount,
                interestRate,
                duration,
                amount,
                lienPosition,
                schedule
            );
        vm.expectRevert(bytes("must be no liens or auctions to call this"));

        COLLATERAL_VAULT.releaseToAddress(
            uint256(keccak256(abi.encodePacked(tokenContract, tokenId))),
            address(this)
        );
    }

    /**
        Ensure that we can auction underlying vaults
        ensure that we're emitting the correct events
        ensure that we're repaying the proper collateral

    */

    struct TestAuctionVaultResponse {
        bytes32 hash;
        uint256 collateralVault;
        uint256 reserve;
    }

    function testAuctionVault()
        public
        returns (TestAuctionVaultResponse memory)
    {
        Dummy721 loanTest = new Dummy721();
        address tokenContract = address(address(loanTest));
        uint256 tokenId = uint256(1);
        uint256 maxAmount = uint256(100000000000000000000);
        uint256 interestRate = uint256(50000000000000000000);
        uint256 duration = uint256(block.timestamp + 10 minutes);
        uint256 amount = uint256(1 ether);
        uint8 lienPosition = uint8(0);
        uint256 schedule = uint256(50);
        (
            bytes32 vaultHash,
            ICollateralVault.Terms memory terms
        ) = _commitToLoan(
                tokenContract,
                tokenId,
                maxAmount,
                interestRate,
                duration,
                amount,
                lienPosition,
                schedule
            );
        uint256 starId = uint256(
            keccak256(abi.encodePacked(tokenContract, tokenId))
        );
        _warpToMaturity(starId, uint256(0));
        address broker = BOND_CONTROLLER.getBroker(vaultHash);
        uint256 reserve = BOND_CONTROLLER.liquidate(terms);
        //        return (vaultHash, starId, reserve);
        return TestAuctionVaultResponse(vaultHash, starId, reserve);
    }

    /**
        Ensure that owner of the token can cancel the auction by repaying the reserve(sum of debt + fee)
        ensure that we're emitting the correct events

    */
    function testCancelAuction() public {
        TestAuctionVaultResponse memory response = testAuctionVault();
        vm.deal(address(this), response.reserve);
        WETH9.deposit{value: response.reserve}();
        WETH9.approve(address(TRANSFER_PROXY), response.reserve);
        COLLATERAL_VAULT.cancelAuction(response.collateralVault);
    }

    function testEndAuctionWithBids() public {
        TestAuctionVaultResponse memory response = testAuctionVault();
        _createBid(bidderOne, response.collateralVault, response.reserve);
        _createBid(
            bidderTwo,
            response.collateralVault,
            response.reserve += ((response.reserve * 5) / 100)
        );
        _createBid(
            bidderOne,
            response.collateralVault,
            response.reserve += ((response.reserve * 30) / 100)
        );
        _warpToAuctionEnd(response.collateralVault);
        COLLATERAL_VAULT.endAuction(response.collateralVault);
    }

    function testRefinanceLoan() public {
        Dummy721 loanTest = new Dummy721();
        address tokenContract = address(address(loanTest));
        uint256 tokenId = uint256(1);

        uint256[] memory loanDetails = new uint256[](6);
        loanDetails[0] = uint256(100000000000000000000); //maxAmount
        loanDetails[1] = uint256(50000000000000000000); //interestRate
        loanDetails[2] = uint256(block.timestamp + 10 minutes); //duration
        loanDetails[3] = uint256(1 ether); //amount
        loanDetails[4] = uint256(0); //lienPosition
        loanDetails[5] = uint256(50); //schedule

        uint256[] memory loanDetails2 = new uint256[](6);
        loanDetails2[0] = uint256(100000000000000000000); //maxAmount
        loanDetails2[1] = uint256(10000000000000000000); //interestRate
        loanDetails2[2] = uint256(block.timestamp + 10 minutes * 2); //duration
        loanDetails2[3] = uint256(1 ether); //amount
        loanDetails2[4] = uint256(0); //lienPosition
        loanDetails2[5] = uint256(50); //schedule
        (bytes32 outgoing, ICollateralVault.Terms memory terms) = _commitToLoan(
            tokenContract,
            tokenId,
            loanDetails[0],
            loanDetails[1],
            loanDetails[2],
            loanDetails[3],
            loanDetails[4],
            loanDetails[5]
        );

        uint256 collateralVault = uint256(
            keccak256(
                abi.encodePacked(
                    tokenContract, //based ghoul
                    tokenId
                )
            )
        );
        {
            (bytes32 incoming, bytes32[] memory newLoanProof) = _generateLoanProof(
                collateralVault,
                loanDetails2[0], //max amount
                loanDetails2[1], //interestRate
                loanDetails2[2], //duration
                loanDetails2[4], //lienPosition
                loanDetails2[5] //schedule
            );

            _createBondVault(
                appraiserTwo,
                block.timestamp + 30 days, //expiration
                block.timestamp + 1 days, //deadline
                uint256(10), //buyout
                incoming,
                appraiserTwoPK
            );

            _lendToVault(incoming, uint256(500 ether), appraiserTwo);

            vm.startPrank(appraiserTwo);
            bytes32[] memory dealBrokers = new bytes32[](2);
            dealBrokers[0] = outgoing;
            dealBrokers[1] = incoming;
            //            uint256[] memory collateralDetails = new uint256[](2);
            //            collateralDetails[0] = collateralVault;
            //            collateralDetails[1] = uint256(0);

            //            BrokerImplementation(BOND_CONTROLLER.getBroker(incoming))
            //                .buyoutLien(
            //                    collateralVault,
            //                    uint256(0),
            //                    newLoanProof,
            //                    loanDetails2
            //                );
            vm.stopPrank();
        }
    }

    // failure testing
    function testFailLendWithoutTransfer() public {
        WETH9.transfer(address(BOND_CONTROLLER), uint256(1));
        IBroker(BOND_CONTROLLER.getBroker(testBondVaultHash)).deposit(
            uint256(1),
            address(this)
        );
    }

    function testFailLendWithNonexistentVault() public {
        BrokerRouter emptyController;
        //        emptyController.lendToVault(testBondVaultHash, uint256(1));
        IBroker(BOND_CONTROLLER.getBroker(testBondVaultHash)).deposit(
            uint256(1),
            address(this)
        );
    }

    function testFailLendPastExpiration() public {
        _createBondVault(testBondVaultHash);
        vm.deal(lender, 1000 ether);
        vm.startPrank(lender);
        WETH9.deposit{value: 50 ether}();
        WETH9.approve(
            address(BOND_CONTROLLER.getBroker(testBondVaultHash)),
            type(uint256).max
        );

        vm.warp(block.timestamp + 10000 days); // forward past expiration date

        //        BOND_CONTROLLER.lendToVault(testBondVaultHash, 50 ether);
        IBroker(BOND_CONTROLLER.getBroker(testBondVaultHash)).deposit(
            50 ether,
            address(this)
        );
        vm.stopPrank();
    }

    function testFailCommitToLoanNotOwner() public {
        Dummy721 loanTest = new Dummy721();
        address tokenContract = address(loanTest);
        uint256 tokenId = uint256(1);
        vm.prank(address(1));
        (bytes32 vaultHash, ) = _commitToLoan(tokenContract, tokenId);
    }
}
