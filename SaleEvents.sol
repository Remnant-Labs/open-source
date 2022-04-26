// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

interface RemnantBadges {
    function mintBadges(address, uint256, uint256) external;
}

contract SaleEvents is Ownable {

    bool public globalSaleIsActive = false;   // Global sale toggle
    bool public blockBots = false;       // Block bots?
    IERC20 public remnToken;            // For potentially processing badge sales in REMN token
    bytes32 public merkleRoot;          // Generate off-chain and update to whitelist, currently merkle whitelist gives access to ALL sales events under the merkle root type

    address public REMNANT_BADGES_CONTRACT;
    RemnantBadges private RemnBadgeContract = RemnantBadges(REMNANT_BADGES_CONTRACT);

    /** 
     * Each sale event has an Id.
     * This represents current active ongoing sales
     * Example: ongoingSaleIds can be: [0,1,3], meaning there are 3 types of Badge sales currently active of Id 0, 1, 3
     * Consequently, multiple types of sales can be active at once and previous sales can be reactivated
     */
    uint256[] public ongoingSaleIds;


    /**
     * Nested mapping of addresses to number of purchases that address made, with respect to the sale ID in the array index
     * Allows tracking and limiting number of purchases for each address per sale type
     * Example: _userMintCounts[0x000123][0] = 5 means that address 0x000123 has bought 5 badges for the sale event ID 0
     * If website needs to display, array index may be an additional parameter
     */
    mapping (address => mapping(uint256 => uint256)) public _userMintCounts;


    /**
     * Nested mapping of addresses to whitelists available, with respect to the sale ID in the array index
     * Allows whitelisted sale events
     * Example: _whitelistAvailable[0x000123][2] = 3 means that address 0x000123 has 3 whitelist mints available for the sale event ID 2
     * If website needs to display, array index may be an additional parameter
     * Merkle proof alternative does NOT require this, but consequently has NO control over per wallet NUMBER of whitelist mints (only global)
     */
    mapping (address => mapping(uint256 => uint256)) public _whitelistAvailable;


    /**
     * Push a new SaleEvent for each new sale event, packed in 256 bytes
     * Can have multiple ongoing sales, tracked with ongoingSaleIds
     */
    struct SaleEvent {
       uint32 saleIdType;               // Type of sale for event. 1 = Normal (ETH), 2 = Normal (REMN), 3 = Whitelist (ETH), 4 = Whitelist (REMN), 5 = Whitelist MERKLE (ETH), 6 = Whitelike MERKLE (REMN)
       uint32 maxMintCountTotal;        // Max global total mints allowed for sale
       uint32 maxMintCountPerWallet;    // Max mints allowed per wallet for sale
       uint32 currentMintCountTotal;    // Current mints for sale
       uint128 mintPrice;               // In ETHER or REMN (18 decimals)
    }

    /**
     * All sale events (whether active or inactive)
     */
    SaleEvent[] public saleEvents; 

    /**
     * Events for transparency or dynamic game metadata backend functionality
     */
    event WithdrawEthFromContract(address to, uint256 amount);                      // For transparency
    event WithdrawERC20FromContract(address to, uint256 amount, address token);     // For transparency
    event NewSaleEventStarted(uint32 saleIdType, uint32 maxMintCountTotal, uint32 maxMintCountPerWallet, uint128 mintPrice);

    /**
     * Sets the REMN token Address (for purchases in REMN)
     */
    function setRemnTokenAddress(address _addr) external onlyOwner {
        remnToken = IERC20(_addr);
    }

    /**
     * Toggles global sale state affecting all sales
     */
    function toggleGlobalSaleState() external onlyOwner {
        globalSaleIsActive = !globalSaleIsActive;
    }

    /**
     * Toggles global sale state affecting all sales
     */
    function toggleBlockBot() external onlyOwner {
        blockBots = !blockBots;
    }

    /**
     * Create a new sale event
     */
    function createNewSaleEvent (
        // Type of sale for event. 1 = Normal (ETH), 2 = Normal (REMN), 3 = Whitelist NAIVE (ETH), 4 = Whitelist NAIVE (REMN), 5 = Whitelist MERKLE (ETH), 6 = Whitelist MERKLE (REMN)
        uint32 _saleIdType,
        uint32 _maxMintCountTotal, 
        uint32 _maxMintCountPerWallet, 
        uint128 _mintPrice
    ) external onlyOwner {
        SaleEvent memory saleEvent;

        saleEvent.saleIdType = _saleIdType;
        saleEvent.maxMintCountTotal = _maxMintCountTotal;
        saleEvent.maxMintCountPerWallet = _maxMintCountPerWallet;
        saleEvent.currentMintCountTotal = 0;
        saleEvent.mintPrice = _mintPrice;

        saleEvents.push(saleEvent);

        emit NewSaleEventStarted(_saleIdType, _maxMintCountTotal, _maxMintCountPerWallet, _mintPrice);
    }

    /**
     * Use to adjust max mint global of any sale event
     */
    function setMaxMintTotal(uint256 _saleEventIndex, uint32 _value) external onlyOwner {
        saleEvents[_saleEventIndex].maxMintCountTotal = _value;
    }

    /**
     * Use to adjust max mint per wallet of any sale event
     */
    function setMaxMintPerWallet(uint256 _saleEventIndex, uint32 _value) external onlyOwner {
        saleEvents[_saleEventIndex].maxMintCountPerWallet = _value;
    }

    /**
     * Use to adjust mint price (ETH or REMN) of any sale event
     */
    function setMintPrice(uint256 _saleEventIndex, uint32 _valueInEther) external onlyOwner {
        saleEvents[_saleEventIndex].mintPrice = _valueInEther;
    }

    /**
     * Set the Remnant Badges smart contract address to connect minting
     */
    function setProxyMintAddress(address _addr) external onlyOwner {
        REMNANT_BADGES_CONTRACT = _addr;
        RemnBadgeContract = RemnantBadges(_addr);
    }

    /**
     * Deactivate an ongoing sale event by INDEX (data of sales still remain, can be reactivated by addSaleEventById)
     */
    function deactivateSaleEventByIndex(uint _index) external onlyOwner {
        if (_index >= ongoingSaleIds.length) return;
        for (uint i = _index; i < ongoingSaleIds.length-1; i++) {
            ongoingSaleIds[i] = ongoingSaleIds[i+1];
        }
        ongoingSaleIds.pop();
    }

    /**
     * Activate an ongoing sale event by ID (use this in addition to createNewSaleEvent to create and activate sale event)
     */
    function activateSaleEventById(uint _id) external onlyOwner {
        ongoingSaleIds.push(_id);
    }

    /**
     * Check that sale is in ongoingSaleIds. If ongoingSaleIds = [1,3,5], it means sale events 1,3,5 are active
     */  
    function isSaleInOngoingList(uint _saleEventIndex) internal view returns(bool) {
        for (uint256 i; i < ongoingSaleIds.length; i++) {
            if (ongoingSaleIds[i] == _saleEventIndex) {
                return true;
            }
        }
        return false;
    }


    // DELEGATE CALL - TELL THE MAIN CONTRACT AFTER THIS PAYMENT PROCESSED TO GO MINT THE NFT FOR THE BUYER
    // THIS IS A PROXY MINT
    function callProxyBadgeMint(uint256 _saleType, uint256 _saleEventIndex, uint256 _count) public payable {
        
        // CHECK ALL CONDITIONS HERE SINCE IT CAN'T BE CHECKED ON THE MAIN FUNCTION NOW THAT WE SEPARATE IT
        require(globalSaleIsActive, "Sale off");
        require(isSaleInOngoingList(_saleEventIndex), "Event off");
        require(_count > 0, "Must buy 1+");

        // Check the user mint count mapping (total minted per wallet for this sale event)
        require(_userMintCounts[msg.sender][_saleEventIndex] + _count <= saleEvents[_saleEventIndex].maxMintCountPerWallet, "Max exceeded");

        // Check the total amount allowed to be minted for this sale event)
        require(saleEvents[_saleEventIndex].currentMintCountTotal + _count <= saleEvents[_saleEventIndex].maxMintCountTotal, "Exceeded remaining");

        // Block other smart contracts from interacting with this if blockBots is enabled
        if (blockBots) require(tx.origin == msg.sender, "Bot block");

        // For ETH sales, check the sent ETH is correct amount
        if (_saleType == 1 || _saleType == 3) { // see SaleEvents.sol for _saleTypes
            require(saleEvents[_saleEventIndex].mintPrice * _count <= msg.value, "Incorrect ether");
        }

        // For REMN sales, calculate REMN price and process payment (REMN must be proapproved by website first)
        if (_saleType == 2 || _saleType == 4) {
            require(MakeRemnPayment(saleEvents[_saleEventIndex].mintPrice * _count), "Not enough REMN");
        }

        // Increment mints of the sale index to track user mint counts (for limit per wallet per sale event)
        _userMintCounts[msg.sender][_saleEventIndex] += _count;

        // For normal Whitelist sale (ETH or REMN) decrement whitelists of this sale event available to user
        if (_saleType == 3 || _saleType == 4) {
            _whitelistAvailable[msg.sender][_saleEventIndex] -= _count;
        }

        // Call RemnantBadges.sol!
        RemnBadgeContract.mintBadges(msg.sender, _saleEventIndex, _count);
    }


    function callProxyBadgeMintMerkle(uint256 _saleType, uint256 _saleEventIndex, uint256 _count, bytes32[] calldata _merkleProof) public payable {
        
        // CHECK ALL CONDITIONS HERE SINCE IT CAN'T BE CHECKED ON THE MAIN FUNCTION NOW THAT WE SEPARATE IT
        require(globalSaleIsActive, "Sale off");
        require(isSaleInOngoingList(_saleEventIndex), "Event off");
        require(_count > 0);
        
        // For MERKLE whitelists (ETH or REMN sale), check the Merkle proof that address exists in whitelist
        if (_saleType == 5 || _saleType == 6) // see SaleEvents.sol for _saleTypes
        {
            bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
            require(MerkleProof.verify(_merkleProof, merkleRoot, leaf), "Invalid proof");
        }

        // Check the user mint count mapping (total minted per wallet for this sale event)
        require(_userMintCounts[msg.sender][_saleEventIndex] + _count <= saleEvents[_saleEventIndex].maxMintCountPerWallet, "Max exceeded");

        // Check the total amount allowed to be minted for this sale event)
        require(saleEvents[_saleEventIndex].currentMintCountTotal + _count <= saleEvents[_saleEventIndex].maxMintCountTotal, "Exceeded remaining");

        // Block other smart contracts from interacting with this if blockBots is enabled
        if (blockBots) require(tx.origin == msg.sender);

        // For ETH sales, check the sent ETH is correct amount
        if (_saleType == 5) {
            require(saleEvents[_saleEventIndex].mintPrice * _count <= msg.value, "Incorrect ether");
        }

        // For REMN sales, calculate REMN price and process payment (REMN must be proapproved by website first)
        if (_saleType == 6) {
            require(MakeRemnPayment(saleEvents[_saleEventIndex].mintPrice * _count), "Not enough REMN");
        }

        // Increment mints of the sale index to track user mint counts (for limit per wallet per sale event)
        _userMintCounts[msg.sender][_saleEventIndex] += _count;

        // Call RemnantBadges.sol!
        RemnBadgeContract.mintBadges(msg.sender, _saleEventIndex, _count);
    }


    /* ================================================ *
     * Whitelist Related Functions                      *
     * ================================================ */
    /**
     * Naive method of whitelists (use to quickly whitelist some addresses for minting [1-200], use max batches of 20)
     * Use Merkle Tree method for whitelisting >200 addresses
     */
    function addWhitelistQuantityNaive(address _addr, uint32 _idType, uint256 _quantity) external onlyOwner {
        _whitelistAvailable[_addr][_idType] += _quantity;
    }

    function _addBatchWhitelistQuantityNaive(address[] memory _addr, uint32 _idType, uint256[] memory _quantity) external onlyOwner {
        uint256 i;
        while (i < _addr.length) {
            _whitelistAvailable[_addr[i]][_idType] += _quantity[i];
            i++;
        }
    }

    /**
     * To whitelist merkle addresses, just regenerate merkle tree based on addresses (off-chain) and update merkle root accordingly
     */
    function updateMerkleRoot(bytes32 _merkleRoot) external onlyOwner {
        merkleRoot = _merkleRoot;
    }
    // ===== END OF [Whitelist Related Functions] =====


    /* ================================================ *
     * Payment Related Functions                        *
     * ================================================ */
   
    /**
     * Makes a payment in REMN token for badge mints (the website must ensure REMN spending is approved first which is not part of this contract)
     */
    function MakeRemnPayment(uint256 _tokenAmount) internal returns(bool) {
        require(_tokenAmount > remnToken.allowance(msg.sender, address(this)), "Approve tokens first");
        return remnToken.transfer(address(this), _tokenAmount);
    }

    /**
     * Withdraws ETH from this smart contract to specified wallet
     */
    function withdrawEth(uint256 _amount, address payable _to) external onlyOwner {
        Address.sendValue(_to, _amount);
        emit WithdrawEthFromContract(_to, _amount); // For transparency
    }

    /**
     * Withdraws REMN or other ERC20 tokens
     */
    function withdrawERC20(address _tokenAddress, uint256 _tokenAmount) external onlyOwner {
        IERC20(_tokenAddress).transfer(msg.sender, _tokenAmount);
        emit WithdrawERC20FromContract(msg.sender, _tokenAmount, _tokenAddress);
    }
    // ===== END OF [Payment Related Functions] =====

}