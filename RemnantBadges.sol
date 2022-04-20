// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;
import "./ERC721A.sol";
// import "./SaleEvents.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./extensions/ERC721AQueryable.sol";

contract RemnantBadges is Ownable, ERC721AQueryable {

    string public baseURI;  // Metadata
    address public MINTER_ROLE; // The SaleEvents.sol contract

    event MintedBadge(address to, uint256 eventIndex, uint256 amount, uint256 currentIndex);    // For backend hook to update dynamic metadata if needed
    event BatchMintEvent(uint256 currentIndex);                                                 // For upcoming airdrops/events (owner mint)

    constructor() ERC721A("RTestBadges6", "RTB6") {
        setBaseURI("https://remnantdev-523be.web.app/nft/badges/");
    }

    /**
     * Batch mint to potentially many different addresses, for owner only (used for events/contests/rewards/airdrops)
     */
    function _batchMint(address[] memory to, uint256[] memory quantity, bytes memory _data) external onlyOwner {
        uint i;
        while (i < to.length) {
            _mint(to[i], quantity[i], _data, true);
            i++;
        }

        emit BatchMintEvent(currentIndex()); // For backend hook to update dynamic metadata
    }

    /**
     * Public mint badge function (can be free, paid in ETH, or REMN, includes normal and whitelist mints), calls internal mint
     */
    function mintBadges(address _to, uint256 _saleEventIndex, uint256 _amount) external {

        // Only the minter from SaleEvents.sol can mint (user calls this function from SaleEvents contract)
        require (msg.sender == MINTER_ROLE, "No mint permission");

        _safeMint(_to, _amount);

        // For backend to populate dynamic metadata
        emit MintedBadge(_to, _saleEventIndex, _amount, currentIndex()); 
    }

    /**
     * Get the base URI
     */
    function _baseURI() internal view virtual override returns (string memory) {
        return baseURI;
    }

    /**
     * Use to change the base URI
     */
    function setBaseURI(string memory _newBaseURI) public onlyOwner {
        baseURI = _newBaseURI;
    }

    /**
     * Set the minter contract
     */
    function setMinterRole(address _addr) public onlyOwner {
        MINTER_ROLE = _addr;
    }

}