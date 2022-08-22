pragma solidity ^0.8.16;

import {Auth, Authority} from "solmate/auth/Auth.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {IERC721} from "gpl/interfaces/IERC721.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";
import {ICollateralToken} from "./interfaces/ICollateralToken.sol";
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";
import {ILienBase, ILienToken} from "./interfaces/ILienToken.sol";
import {CollateralLookup} from "./libraries/CollateralLookup.sol";
import {ITransferProxy} from "./interfaces/ITransferProxy.sol";
import {IAstariaRouter} from "./interfaces/IAstariaRouter.sol";
import {IVault, VaultImplementation} from "./VaultImplementation.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Pausable} from "./utils/Pausable.sol";

interface IInvoker {
    function onBorrowAndBuy(bytes calldata data, address token, uint256 amount, address payable recipient)
        external
        returns (bool);
}

contract AstariaRouter is Auth, Pausable, IAstariaRouter {
    using SafeTransferLib for ERC20;
    using CollateralLookup for address;
    using FixedPointMathLib for uint256;

    ERC20 public immutable WETH;
    ICollateralToken public immutable COLLATERAL_TOKEN;
    ILienToken public immutable LIEN_TOKEN;
    ITransferProxy public immutable TRANSFER_PROXY;
    address public VAULT_IMPLEMENTATION;
    address public SOLO_IMPLEMENTATION;
    address public WITHDRAW_IMPLEMENTATION;

    address public feeTo;

    uint256 public LIQUIDATION_FEE_PERCENT;
    uint256 public STRATEGIST_ORIGINATION_FEE_NUMERATOR;
    uint256 public STRATEGIST_ORIGINATION_FEE_BASE;
    uint256 public MIN_INTEREST_BPS; // was uint64
    uint64 public MIN_DURATION_INCREASE;
    uint256 public MIN_EPOCH_LENGTH;
    uint256 public MAX_EPOCH_LENGTH;

    //public vault contract => appraiser
    mapping(address => address) public vaults;
    mapping(address => uint256) public appraiserNonce;

    // See https://eips.ethereum.org/EIPS/eip-191

    constructor(
        Authority _AUTHORITY,
        address _WETH,
        address _COLLATERAL_TOKEN,
        address _LIEN_TOKEN,
        address _TRANSFER_PROXY,
        address _VAULT_IMPL, //TODO: move these out of constructor into setup flow? or just use the default?
        address _SOLO_IMPL
    )
        Auth(address(msg.sender), _AUTHORITY)
    {
        WETH = ERC20(_WETH);
        COLLATERAL_TOKEN = ICollateralToken(_COLLATERAL_TOKEN);
        LIEN_TOKEN = ILienToken(_LIEN_TOKEN);
        TRANSFER_PROXY = ITransferProxy(_TRANSFER_PROXY);
        VAULT_IMPLEMENTATION = _VAULT_IMPL;
        SOLO_IMPLEMENTATION = _SOLO_IMPL;
        LIQUIDATION_FEE_PERCENT = 13;
        MIN_INTEREST_BPS = 5; //5 bps
        STRATEGIST_ORIGINATION_FEE_NUMERATOR = 200;
        STRATEGIST_ORIGINATION_FEE_BASE = 1000;
        MIN_DURATION_INCREASE = 14 days;
    }

    function __emergencyPause() external requiresAuth whenNotPaused {
        _pause();
    }

    function __emergencyUnpause() external requiresAuth whenPaused {
        _unpause();
    }

    function file(bytes32[] memory what, bytes[] calldata data) external requiresAuth {
        require(what.length == data.length, "data length mismatch");
        for (uint256 i = 0; i < what.length; i++) {
            file(what[i], data[i]);
        }
    }

    function file(bytes32 what, bytes calldata data) public requiresAuth {
        if (what == "LIQUIDATION_FEE_PERCENT") {
            uint256 value = abi.decode(data, (uint256));
            LIQUIDATION_FEE_PERCENT = value;
        } else if (what == "MIN_INTEREST_BPS") {
            uint256 value = abi.decode(data, (uint256));
            MIN_INTEREST_BPS = uint256(value);
        } else if (what == "APPRAISER_NUMERATOR") {
            uint256 value = abi.decode(data, (uint256));
            STRATEGIST_ORIGINATION_FEE_NUMERATOR = value;
        } else if (what == "APPRAISER_ORIGINATION_FEE_BASE") {
            uint256 value = abi.decode(data, (uint256));
            STRATEGIST_ORIGINATION_FEE_BASE = value;
        } else if (what == "MIN_DURATION_INCREASE") {
            uint256 value = abi.decode(data, (uint256));
            MIN_DURATION_INCREASE = uint64(value);
        } else if (what == "feeTo") {
            address addr = abi.decode(data, (address));
            feeTo = addr;
        } else if (what == "WITHDRAW_IMPLEMENTATION") {
            address addr = abi.decode(data, (address));
            WITHDRAW_IMPLEMENTATION = addr;
        } else if (what == "VAULT_IMPLEMENTATION") {
            address addr = abi.decode(data, (address));
            VAULT_IMPLEMENTATION = addr;
        } else if (what == "SOLO_IMPLEMENTATION") {
            address addr = abi.decode(data, (address));
            SOLO_IMPLEMENTATION = addr;
        } else if (what == "MIN_EPOCH_LENGTH") {
            MIN_EPOCH_LENGTH = abi.decode(data, (uint256));
        } else if (what == "MAX_EPOCH_LENGTH") {
            MAX_EPOCH_LENGTH = abi.decode(data, (uint256));
        } else {
            revert("unsupported/file");
        }
    }

    // MODIFIERS
    modifier onlyVaults() {
        require(vaults[msg.sender] != address(0), "this vault has not been initialized");
        _;
    }

    //PUBLIC

    //todo: check all incoming obligations for validity
    function commitToLoans(IAstariaRouter.Commitment[] calldata commitments)
        external
        whenNotPaused
        returns (uint256 totalBorrowed)
    {
        totalBorrowed = 0;
        for (uint256 i = 0; i < commitments.length; ++i) {
            _transferAndDepositAsset(commitments[i].tokenContract, commitments[i].tokenId);
            totalBorrowed += _executeCommitment(commitments[i]);

            uint256 collateralId = commitments[i].tokenContract.computeId(commitments[i].tokenId);
            _returnCollateral(collateralId, address(msg.sender));
        }
        WETH.safeApprove(address(TRANSFER_PROXY), totalBorrowed);
        TRANSFER_PROXY.tokenTransferFrom(address(WETH), address(this), address(msg.sender), totalBorrowed);
    }

    // verifies the signature on the root of the merkle tree to be the appraiser
    // we need an additional method to prevent a griefing attack where the signature is stripped off and reserrved by an attacker

    function newVault() external whenNotPaused returns (address) {
        return _newBondVault(uint256(0));
    }

    function newPublicVault(uint256 epochLength) external whenNotPaused returns (address) {
        return _newBondVault(epochLength);
    }

    //    function borrowAndBuy(BorrowAndBuyParams memory params) external {
    //        uint256 spendableBalance;
    //        for (uint256 i = 0; i < params.commitments.length; ++i) {
    //            _executeCommitment(params.commitments[i]);
    //            spendableBalance += params.commitments[i].amount; //amount borrowed
    //        }
    //        require(
    //            params.purchasePrice <= spendableBalance,
    //            "purchase price cannot be for more than your aggregate loan"
    //        );
    //
    //        WETH.safeApprove(params.invoker, params.purchasePrice);
    //        require(
    //            IInvoker(params.invoker).onBorrowAndBuy(
    //                params.purchaseData, // calldata for the invoker
    //                address(WETH), // token
    //                params.purchasePrice, //max approval
    //                payable(msg.sender) // recipient
    //            ),
    //            "borrow and buy failed"
    //        );
    //        if (spendableBalance - params.purchasePrice > uint256(0)) {
    //            WETH.safeTransfer(
    //                msg.sender,
    //                spendableBalance - params.purchasePrice
    //            );
    //        }
    //    }

    function buyoutLien(
        uint256 position,
        IAstariaRouter.Commitment memory incomingTerms //        onlyNetworkBrokers( //            outgoingTerms.collateralId, //            outgoingTerms.position //        )
    )
        external
        whenNotPaused
    {
        VaultImplementation(incomingTerms.nor.strategy.vault).buyoutLien(
            incomingTerms.tokenContract.computeId(incomingTerms.tokenId), position, incomingTerms
        );
    }

    function requestLienPosition(ILienBase.LienActionEncumber calldata params)
        external
        whenNotPaused
        onlyVaults
        returns (uint256)
    {
        return LIEN_TOKEN.createLien(params);
    }

    function lendToVault(address vault, uint256 amount) external whenNotPaused {
        TRANSFER_PROXY.tokenTransferFrom(address(WETH), address(msg.sender), address(this), amount);

        require(vaults[vault] != address(0), "lendToVault: vault doesn't exist");
        WETH.safeApprove(vault, amount);
        IVault(vault).deposit(amount, address(msg.sender));
    }

    function canLiquidate(uint256 collateralId, uint256 position) public view whenNotPaused returns (bool) {
        ILienToken.Lien memory lien = LIEN_TOKEN.getLien(collateralId, position);

        uint256 interestAccrued = LIEN_TOKEN.getInterest(collateralId, position);
        // uint256 maxInterest = (lien.amount * lien.schedule) / 100

        return (lien.start + lien.duration <= block.timestamp && lien.amount > 0);
    }

    // person calling liquidate should get some incentive from the auction
    function liquidate(uint256 collateralId, uint256 position) external whenNotPaused returns (uint256 reserve) {
        require(canLiquidate(collateralId, position), "liquidate: borrow is healthy");

        // 0x

        reserve = COLLATERAL_TOKEN.auctionVault(collateralId, address(msg.sender), LIQUIDATION_FEE_PERCENT);

        emit Liquidation(collateralId, position, reserve);
    }

    function getStrategistFee() external view returns (uint256, uint256) {
        return (STRATEGIST_ORIGINATION_FEE_NUMERATOR, STRATEGIST_ORIGINATION_FEE_BASE);
    }

    function isValidVault(address vault) external view returns (bool) {
        return vaults[vault] != address(0);
    }

    //    function isValidRefinance(IAstariaRouter.RefinanceCheckParams memory params)
    //        external
    //        view
    //        returns (bool)
    //    {
    //        ILienToken.Lien memory lien = LIEN_TOKEN.getLien(
    //            params.incoming.tokenContract.compute(params.incoming.tokenId),
    //            params.position
    //        );
    //        // uint256 minNewRate = (((lien.rate * MIN_INTEREST_BPS) / 1000));
    //        uint256 minNewRate = uint256(lien.rate).mulDivDown(
    //            MIN_INTEREST_BPS,
    //            1000
    //        );
    //
    //        if (params.incoming.rate > minNewRate) {
    //            revert InvalidRefinanceRate(params.incoming.rate);
    //        }
    //
    //        if (
    //            (block.timestamp + params.incoming.duration) -
    //                (lien.start + lien.duration) <
    //            MIN_DURATION_INCREASE
    //        ) {
    //            revert InvalidRefinanceDuration(params.incoming.duration);
    //        }
    //
    //        return true;
    //    }

    //INTERNAL FUNCS

    function _newBondVault(uint256 epochLength) internal returns (address) {
        uint256 brokerType;

        address implementation;
        if (epochLength > uint256(0)) {
            require(
                epochLength >= MIN_EPOCH_LENGTH || epochLength <= MAX_EPOCH_LENGTH,
                "epochLength must be greater than or equal to MIN_EPOCH_LENGTH and less than MAX_EPOCH_LENGTH"
            );
            implementation = VAULT_IMPLEMENTATION;
            brokerType = 2;
        } else {
            implementation = SOLO_IMPLEMENTATION;
            brokerType = 1;
        }

        address vaultAddr = ClonesWithImmutableArgs.clone(
            implementation,
            abi.encodePacked(
                address(msg.sender),
                address(WETH),
                address(COLLATERAL_TOKEN),
                address(this),
                address(COLLATERAL_TOKEN.AUCTION_HOUSE()),
                block.timestamp,
                epochLength,
                brokerType
            )
        );

        vaults[vaultAddr] = msg.sender;

        emit NewVault(msg.sender, vaultAddr);

        return vaultAddr;
    }

    function _executeCommitment(IAstariaRouter.Commitment memory c) internal returns (uint256) {
        uint256 collateralId = c.tokenContract.computeId(c.tokenId);
        require(msg.sender == COLLATERAL_TOKEN.ownerOf(collateralId), "invalid sender for collateralId");
        return _borrow(c, address(this));
    }

    function _borrow(IAstariaRouter.Commitment memory c, address receiver) internal returns (uint256) {
        //router must be approved for the star nft to take a loan,
        VaultImplementation(c.nor.strategy.vault).commitToLoan(c, receiver);
        if (receiver == address(this)) {
            return c.nor.amount;
        }
        return uint256(0);
    }

    function _transferAndDepositAsset(address tokenContract, uint256 tokenId) internal {
        IERC721(tokenContract).transferFrom(address(msg.sender), address(this), tokenId);

        IERC721(tokenContract).approve(address(COLLATERAL_TOKEN), tokenId);

        COLLATERAL_TOKEN.depositERC721(address(this), tokenContract, tokenId);
    }

    function _returnCollateral(uint256 collateralId, address receiver) internal {
        COLLATERAL_TOKEN.transferFrom(address(this), receiver, collateralId);
    }

    function _addLien(ILienBase.LienActionEncumber memory params) internal {
        LIEN_TOKEN.createLien(params);
    }
}
