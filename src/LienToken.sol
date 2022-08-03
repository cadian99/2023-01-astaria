// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

pragma experimental ABIEncoderV2;

import {Auth, Authority} from "solmate/auth/Auth.sol";
//import {ERC721} from "solmate/tokens/ERC721.sol";
import {ERC721} from "openzeppelin/token/ERC721/ERC721.sol";
import {MerkleProof} from "openzeppelin/utils/cryptography/MerkleProof.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {ITransferProxy} from "gpl/interfaces/ITransferProxy.sol";
import {ILienToken, IERC721, IERC165} from "./interfaces/ILienToken.sol";
import {ICollateralVault} from "./interfaces/ICollateralVault.sol";
import {IBrokerRouter} from "./interfaces/IBrokerRouter.sol";
import {BrokerImplementation} from "./BrokerImplementation.sol";
import {ValidateTerms} from "./libraries/ValidateTerms.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

contract TransferAgent {
    address public immutable WETH;
    ITransferProxy public immutable TRANSFER_PROXY;

    constructor(address _TRANSFER_PROXY, address _WETH) {
        TRANSFER_PROXY = ITransferProxy(_TRANSFER_PROXY);
        WETH = _WETH;
    }
}

contract LienToken is ILienToken, Auth, TransferAgent, ERC721 {
    using ValidateTerms for IBrokerRouter.NewObligationRequest;
    using FixedPointMathLib for uint256;

    IAuctionHouse public AUCTION_HOUSE;
    ICollateralVault public COLLATERAL_VAULT;

    bytes32 public immutable DOMAIN_SEPARATOR;

    string private constant EIP191_PREFIX_FOR_EIP712_STRUCTURED_DATA =
        "\x19\x01";
    bytes32 private constant NEW_SUBJUGATION_OFFER =
        keccak256(
            "NewSubjugationOffer(uint256 collateralVault,uint256 lienId,uint256 currentPosition,uint256 lowestPosition,uint256 price,uint256 deadline)"
        );

    uint256 public lienCounter;
    uint256 public buyoutNumerator;
    uint256 public buyoutDenominator;

    //    mapping(address => bool) public validatorAssets;
    mapping(uint256 => Lien) public lienData;
    mapping(uint256 => uint256[]) public liens;

    event NewLien(uint256 lienId, bytes32 rootHash);
    event RemovedLiens(uint256 lienId);
    event BuyoutLien(address indexed buyer, uint256 lienId, uint256 buyout);

    constructor(
        Authority _AUTHORITY,
        address _TRANSFER_PROXY,
        address _WETH
    )
        Auth(address(msg.sender), _AUTHORITY)
        TransferAgent(_TRANSFER_PROXY, _WETH)
        ERC721("Astaria Lien Token", "Lien")
    {
        lienCounter = 1;
        buyoutNumerator = 10;
        buyoutDenominator = 100;
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("LienToken"),
                keccak256("1"),
                chainId,
                address(this)
            )
        );
    }

    function file(bytes32 what, bytes calldata data) external requiresAuth {
        if (what == "setAuctionHouse") {
            address addr = abi.decode(data, (address));
            AUCTION_HOUSE = IAuctionHouse(addr);
        } else if (what == "setCollateralVault") {
            address addr = abi.decode(data, (address));
            COLLATERAL_VAULT = ICollateralVault(addr);
        } else {
            revert("unsupported/file");
        }
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, IERC165)
        returns (bool)
    {
        return
            interfaceId == type(IERC721).interfaceId ||
            interfaceId == type(ILienToken).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    function buyoutLien(ILienToken.LienActionBuyout calldata params) external {
        uint256 collateralVault = uint256(
            keccak256(
                abi.encode(
                    params.incoming.tokenContract,
                    params.incoming.tokenId
                )
            )
        );
        (uint256 owed, uint256 buyout) = getBuyout(
            collateralVault,
            params.position
        );

        uint256 lienId = liens[collateralVault][params.position];
        TRANSFER_PROXY.tokenTransferFrom(
            lienData[lienId].token,
            address(msg.sender),
            ownerOf(lienId),
            uint256(buyout)
        );

        (bool valid, IBrokerRouter.LienDetails memory ld) = params
            .incoming
            .nor
            .validateTerms();

        //todo: ensure rates and duration is better;

        uint256 currentRate = lienData[lienId].rate == uint256(0)
            ? BrokerImplementation(lienData[lienId].vault).getRate()
            : lienData[lienId].rate;

        uint256 incomingRate = ld.rate == uint256(0)
            ? BrokerImplementation(lienData[lienId].vault).getRate()
            : ld.rate;
        require(incomingRate <= currentRate, "Invalid Rate");
        require(ld.duration <= type(uint256).max, "Invalid Duration"); //TODO: set this check to be proper with a min DURATION
        lienData[lienId].last = uint32(block.timestamp);
        lienData[lienId].rate = uint32(ld.rate);
        lienData[lienId].duration = uint32(ld.duration);
        //so, something about brokers
        lienData[lienId].vault = params.incoming.nor.strategy.vault;

        //TODO: emit event, should we send to sender or broker on buyout?
        super.safeTransferFrom(
            ownerOf(lienId),
            address(params.receiver),
            lienId
        );
    }

    //    function validateTerms(IBrokerRouter.Terms memory params)
    //        public
    //        view
    //        returns (bool)
    //    {
    //        uint256 lienId = liens[params.collateralVault][params.position];
    //
    //        return
    //            params.validateTerms(
    //                BrokerImplementation(lienData[lienId].broker).vaultHash()
    //            );
    //    }

    function getInterest(uint256 collateralVault, uint256 position)
        public
        view
        returns (uint256)
    {
        uint256 lien = liens[collateralVault][position];
        if (!lienData[lien].active) return uint256(0);
        return _getInterest(lienData[lien], block.timestamp);
    }

    function _getInterest(Lien memory lien, uint256 timestamp)
        internal
        view
        returns (uint256)
    {
        uint256 delta_t = uint256(uint32(timestamp) - lien.last);

        // return (delta_t * uint256(lien.rate) * lien.amount);
        uint256 rate = lien.rate == uint32(0)
            ? BrokerImplementation(lien.vault).getRate()
            : lien.rate;
        return delta_t.mulDivDown(rate, 1).mulDivDown(lien.amount, 1);
    }

    function stopLiens(uint256 collateralVault)
        external
        requiresAuth
        returns (
            uint256 reserve,
            uint256[] memory amounts,
            uint256[] memory lienIds
        )
    {
        reserve = 0;
        lienIds = liens[collateralVault];
        amounts = new uint256[](liens[collateralVault].length);
        for (uint256 i = 0; i < lienIds.length; ++i) {
            ILienToken.Lien storage lien = lienData[lienIds[i]];
            unchecked {
                lien.amount += _getInterest(lien, block.timestamp);
                reserve += lien.amount;
            }
            amounts[i] = lien.amount;
            lien.active = false;
        }
    }

    //undo solmate change for now

    function tokenURI(uint256) public view override returns (string memory) {
        return "";
    }

    function encodeSubjugationOffer(
        uint256 collateralVault,
        uint256 lien,
        uint256 currentPosition,
        uint256 lowestPosition,
        uint256 price,
        uint256 deadline
    ) public view returns (bytes memory) {
        return
            abi.encodePacked(
                EIP191_PREFIX_FOR_EIP712_STRUCTURED_DATA,
                DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(
                        NEW_SUBJUGATION_OFFER,
                        collateralVault,
                        lien,
                        currentPosition,
                        lowestPosition,
                        price,
                        deadline
                    )
                )
            );
    }

    //    function takeSubjugationOffer(ILienToken.LienActionSwap calldata params)
    //        external
    //    {
    //        require(block.timestamp <= params.offer.deadline, "offer has expired");
    //        require(
    //            msg.sender == ownerOf(params.replacementLien),
    //            "only the holder of the replacement lien can call this"
    //        );
    //        require(
    //            liens[params.offer.collateralVault][params.replacementPosition] ==
    //                params.replacementLien,
    //            "invalid swap criteria"
    //        );
    //        require(
    //            params.replacementPosition <= params.offer.lowestPosition,
    //            "your lien is too low to swap with this holder"
    //        );
    //        //validate signer of the swap terms is the holder of the lien you are swapping
    //
    //        bytes32 digest = keccak256(
    //            encodeSubjugationOffer(
    //                params.offer.collateralVault,
    //                params.offer.lien,
    //                params.offer.currentPosition,
    //                params.offer.lowestPosition,
    //                params.offer.price,
    //                params.offer.deadline
    //            )
    //        );
    //
    //        address recoveredAddress = ecrecover(
    //            digest,
    //            params.offer.v,
    //            params.offer.r,
    //            params.offer.s
    //        );
    //
    //        require(
    //            recoveredAddress ==
    //                ownerOf(
    //                    liens[params.offer.collateralVault][
    //                        params.offer.currentPosition
    //                    ]
    //                ),
    //            "invalid owner sig for lien"
    //        );
    //
    //        TRANSFER_PROXY.tokenTransferFrom(
    //            params.offer.token,
    //            address(msg.sender),
    //            ownerOf(params.offer.lien),
    //            params.offer.price
    //        );
    //
    //        //swap positions in the queue
    //        liens[params.offer.collateralVault][
    //            params.offer.currentPosition
    //        ] = params.replacementLien;
    //
    //        liens[params.offer.collateralVault][params.replacementPosition] = params
    //            .offer
    //            .lien;
    //    }

    function createLien(ILienToken.LienActionEncumber memory params)
        external
        requiresAuth
        returns (uint256 lienId)
    {
        // require that the auction is not under way

        uint256 collateralVault = uint256(
            bytes32(
                keccak256(
                    abi.encodePacked(params.tokenContract, params.tokenId)
                )
            )
        );
        require(
            !AUCTION_HOUSE.auctionExists(collateralVault),
            "collateralVault is being liquidated, cannot open new liens"
        );
        (address tokenContract, ) = COLLATERAL_VAULT.getUnderlying(
            collateralVault
        );

        if (params.borrowAndBuy != true) {
            require(
                tokenContract != address(0),
                "Collateral must be deposited before you can request a lien"
            );
        }

        uint256 totalDebt = getTotalDebtForCollateralVault(collateralVault);

        require(
            params.terms.maxSeniorDebt >= totalDebt,
            "too much debt to take this loan"
        );

        lienId = uint256(
            keccak256(
                abi.encodePacked(
                    abi.encode(
                        bytes32(collateralVault),
                        params.vault,
                        WETH,
                        params.terms.maxAmount,
                        params.terms.maxSeniorDebt,
                        params.terms.duration,
                        params.terms.schedule
                    ),
                    params.obligationRoot
                )
            )
        );

        _mint(BrokerImplementation(params.vault).recipient(), lienId);
        lienData[lienId] = Lien({
            token: WETH,
            amount: params.amount,
            maxSeniorDebt: params.terms.maxSeniorDebt,
            active: true,
            rate: uint32(params.terms.rate),
            vault: params.vault,
            last: uint32(block.timestamp),
            start: uint32(block.timestamp),
            duration: uint32(params.terms.duration),
            schedule: uint32(params.terms.schedule)
        });

        liens[collateralVault].push(lienId);

        emit NewLien(lienId, params.obligationRoot);
    }

    function removeLiens(uint256 collateralVault) external requiresAuth {
        delete liens[collateralVault];
        emit RemovedLiens(collateralVault);
    }

    //    function isValidatorAsset(address incomingAsset) public returns (bool) {
    //        return validatorAssets[incomingAsset];
    //    }

    //    function onERC1155Received(
    //        address operator,
    //        address from,
    //        uint256 id,
    //        uint256 value,
    //        bytes calldata data
    //    ) external returns (bytes4) {
    //        require(
    //            isValidatorAsset(msg.sender),
    //            "address must be from a validator contract we care about"
    //        );
    //        require(
    //            WETH.balanceOf(address(this) >= value),
    //            "not enough balance to make this payment"
    //        );
    //        makePayment(id, value);
    //
    //        return IERC1155Receiver.onERC1155Received.selector;
    //    }

    function getLiens(uint256 collateralVault)
        public
        view
        returns (uint256[] memory)
    {
        return liens[collateralVault];
    }

    function getLien(uint256 lienId) external view returns (Lien memory) {
        return lienData[lienId];
    }

    function getLien(uint256 collateralVault, uint256 position)
        public
        view
        returns (Lien memory)
    {
        uint256 lienId = liens[collateralVault][position];
        return lienData[lienId];
    }

    function getBuyout(uint256 collateralVault, uint256 index)
        public
        view
        returns (uint256, uint256)
    {
        Lien memory lien = getLien(collateralVault, index);
        uint256 owed = _getOwed(lien);
        uint256 remainingInterest = _getRemainingInterest(lien);
        return (
            owed,
            // owed + (remainingInterest * buyoutNumerator) / buyoutDenominator
            owed +
                remainingInterest.mulDivDown(buyoutNumerator, buyoutDenominator)
        );
    }

    function makePayment(uint256 collateralVault, uint256 paymentAmount)
        public
    {
        uint256[] memory openLiens = liens[collateralVault];
        for (uint256 i = 0; i < openLiens.length; ++i) {
            paymentAmount = _payment(collateralVault, i, paymentAmount);
        }
    }

    function makePayment(
        uint256 collateralVault,
        uint256 paymentAmount,
        uint256 index
    ) external {
        _payment(collateralVault, index, paymentAmount);
    }

    function getTotalDebtForCollateralVault(uint256 collateralVault)
        public
        view
        returns (uint256 totalDebt)
    {
        uint256[] memory openLiens = getLiens(collateralVault);

        for (uint256 i = 0; i < openLiens.length; ++i) {
            totalDebt += _getOwed(lienData[openLiens[i]]);
        }
    }

    function getTotalDebtForCollateralVault(
        uint256 collateralVault,
        uint256 timestamp
    ) public view returns (uint256 totalDebt) {
        uint256[] memory openLiens = getLiens(collateralVault);

        for (uint256 i = 0; i < openLiens.length; ++i) {
            totalDebt += _getOwed(lienData[openLiens[i]], timestamp);
        }
    }

    function getImpliedRate(uint256 collateralVault)
        public
        view
        returns (uint256 impliedRate)
    {
        uint256 totalDebt = getTotalDebtForCollateralVault(collateralVault);
        uint256[] memory openLiens = getLiens(collateralVault);

        for (uint256 i = 0; i < openLiens.length; ++i) {
            Lien storage lien = lienData[openLiens[i]];

            // impliedRate += (lien.amount / totalDebt) * lien.rate;

            impliedRate += uint256(lien.rate).mulDivDown(
                lien.amount,
                totalDebt
            );
        }
    }

    function _getOwed(Lien memory lien) internal view returns (uint256) {
        return lien.amount += _getInterest(lien, block.timestamp);
    }

    function _getOwed(Lien memory lien, uint256 timestamp)
        internal
        view
        returns (uint256)
    {
        return lien.amount += _getInterest(lien, timestamp);
    }

    function _getRemainingInterest(Lien memory lien)
        internal
        pure
        returns (uint256)
    {
        uint256 delta_t = uint256(
            uint32(lien.start + lien.duration) - lien.last
        );

        // return (delta_t * uint256(lien.rate) * lien.amount);

        return delta_t.mulDivDown(lien.rate, 1).mulDivDown(lien.amount, 1);
    }

    function _payment(
        uint256 collateralVault,
        uint256 position,
        uint256 paymentAmount
    ) internal returns (uint256) {
        if (paymentAmount == uint256(0)) return uint256(0);
        Lien storage lien = lienData[liens[collateralVault][position]];
        uint256 maxPayment = _getOwed(lien);
        address owner = ownerOf(liens[collateralVault][position]);

        if (maxPayment < paymentAmount) {
            lien.amount -= paymentAmount;
            lien.last = uint32(block.timestamp);
        } else {
            paymentAmount = maxPayment;
            delete liens[collateralVault][position];
        }
        TRANSFER_PROXY.tokenTransferFrom(
            address(WETH),
            address(msg.sender),
            owner,
            paymentAmount
        );

        return paymentAmount;
    }
}
