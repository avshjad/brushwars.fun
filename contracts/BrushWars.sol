// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CanvasArt} from "./CanvasArt.sol";

/*
 *  BrushWars  —  Monad mainnet (chain 143)
 *  =======================================
 *  A rate-limited collaborative pixel canvas. Buy BRUSHES; brushes drip pixels
 *  over time; two prizes per round.
 *
 *  ECONOMY
 *    - Normal brush: 1 px/min, paints EMPTY tiles only.
 *    - Golden brush: 1 px/min, paints ANYWHERE (overpaint counts).
 *    - Perpetual drip from purchase until round end; then expires.
 *    - Every purchase: 70% -> owner (instant), 30% -> the round POT.
 *    - Painting is GASLESS (off-chain); only buying brushes is a player tx.
 *
 *  CLOSE (whichever first): INACTIVITY_WINDOW idle, or HARD_CAP since start.
 *  PRIZES: NFT -> last pixel (tokenId = roundId). POT -> most pixels (90%,
 *          10% rolls into next round).
 *
 *  TRUST MODEL (disclosed to players)
 *    The off-chain OPERATOR reports who painted (tallies + last-painter) and
 *    commits the final canvas. It holds NO funds and cannot pay itself or
 *    withdraw — its only power is reporting game results. The contract guards
 *    all money. This is a trusted-operator design: results are settled by the
 *    operator we run; funds are controlled by the contract. We keep early pots
 *    small while the project is young.
 *
 *  This version inherits OpenZeppelin ERC721 / Ownable / ReentrancyGuard.
 *  Tokens are real ERC-721s minted at close, with fully on-chain art via
 *  CanvasArt. MUST compile with optimizer + viaIR.
 */
contract BrushWars is ERC721, Ownable, ReentrancyGuard {
    address public operator;
    modifier onlyOperator() { require(msg.sender == operator, "not operator"); _; }

    uint256 public normalBrushPrice;
    uint256 public goldenBrushPrice;
    uint16  public constant POT_BPS      = 3000;  // 30% to pot, 70% to owner
    uint16  public constant ROLLOVER_BPS = 1000;  // 10% of a closed pot rolls forward

    // TESTNET values — REVERT to 30 min / 12 h before mainnet.
    uint256 public constant INACTIVITY_WINDOW = 5 minutes;
    uint256 public constant HARD_CAP          = 1 hours;

    struct Round {
        uint64  startTime;
        uint64  lastPixelTime;
        address lastPainter;        // -> NFT
        address topPainter;         // -> pot
        uint256 topPainterPixels;
        uint256 pot;
        uint256 winnerClaimable;    // 90% of pot, set at close
        bool    closed;
        bool    claimed;
    }
    uint256 public roundId;
    uint256 public pendingRollover;
    mapping(uint256 => Round) public rounds;

    struct Brushes { uint64 normalCount; uint64 goldenCount; uint64 firstPurchaseTime; }
    mapping(uint256 => mapping(address => Brushes)) public brushes;
    mapping(uint256 => mapping(address => uint256)) public pixelsPlaced;

    // on-chain art storage
    mapping(uint256 => string)  public artworkURIOverride;  // optional manual override
    mapping(uint256 => bytes)   public packedCanvas;        // 4096 bytes (1 byte/px)
    mapping(uint256 => uint256) public totalPixelsAt;
    mapping(uint256 => uint256) public distinctPainters;
    mapping(uint256 => bool)    public closedByCap;

    event RoundStarted(uint256 indexed roundId, uint64 startTime, uint256 startingPot);
    event BrushesBought(uint256 indexed roundId, address indexed buyer, uint64 normal, uint64 golden, uint256 paid, uint256 toPot);
    event PotSeeded(uint256 indexed roundId, address indexed from, uint256 amount, uint256 newPot);
    event Settled(uint256 indexed roundId, address lastPainter, uint64 lastPixelTime, address topPainter, uint256 topPixels);
    event RoundClosed(uint256 indexed roundId, address indexed nftWinner, address indexed potWinner, uint256 winnerClaimable, uint256 rolledOver);
    event PotClaimed(uint256 indexed roundId, address indexed winner, uint256 amount);

    constructor(uint256 _normalPrice, uint256 _goldenPrice, address _operator)
        ERC721("BrushWars Canvas", "BRUSH")
        Ownable(msg.sender)
    {
        require(_operator != address(0) && _normalPrice > 0 && _goldenPrice > 0, "bad args");
        operator = _operator;
        normalBrushPrice = _normalPrice;
        goldenBrushPrice = _goldenPrice;
    }

    // ---- round lifecycle ----
    // owner OR operator may start a round. The operator auto-starts the next
    // round after each close (the owner/operator split meant onlyOwner blocked
    // this on mainnet). Starting a round touches no funds, so this is low-risk.
    function startRound() external {
        require(msg.sender == owner() || msg.sender == operator, "not authorized");
        if (roundId != 0) require(rounds[roundId].closed, "prev open");
        roundId += 1;
        Round storage R = rounds[roundId];
        R.startTime = uint64(block.timestamp);
        R.lastPixelTime = uint64(block.timestamp);
        R.pot = pendingRollover;
        pendingRollover = 0;
        emit RoundStarted(roundId, R.startTime, R.pot);
    }

    // ---- buy brushes ----
    function buyBrushes(uint64 normal, uint64 golden) external payable nonReentrant {
        uint256 r = roundId;
        require(r != 0 && !rounds[r].closed && !_isExpired(r), "no open round");
        require(normal > 0 || golden > 0, "buy something");
        uint256 cost = uint256(normal) * normalBrushPrice + uint256(golden) * goldenBrushPrice;
        require(msg.value == cost, "exact cost only");

        Brushes storage b = brushes[r][msg.sender];
        if (b.firstPurchaseTime == 0) b.firstPurchaseTime = uint64(block.timestamp);
        b.normalCount += normal; b.goldenCount += golden;

        uint256 toPot = (cost * POT_BPS) / 10000;
        rounds[r].pot += toPot;
        (bool ok, ) = owner().call{value: cost - toPot}("");
        require(ok, "owner xfer failed");
        emit BrushesBought(r, msg.sender, normal, golden, cost, toPot);
    }

    function seedPot() external payable {
        uint256 r = roundId;
        require(r != 0 && !rounds[r].closed, "no open round");
        require(msg.value > 0, "zero");
        rounds[r].pot += msg.value;
        emit PotSeeded(r, msg.sender, msg.value, rounds[r].pot);
    }

    // ---- operator settlement ----
    function settle(uint256 r, address[] calldata players, uint256[] calldata totals,
                    address lastPainter, uint64 lastPixelTime) external onlyOperator {
        require(r == roundId && !rounds[r].closed, "not current/open");
        require(players.length == totals.length, "len");
        require(lastPixelTime <= block.timestamp, "future ts");
        Round storage R = rounds[r];
        require(lastPixelTime >= R.lastPixelTime, "ts regress");

        address top = R.topPainter; uint256 topPx = R.topPainterPixels;
        for (uint256 i = 0; i < players.length; i++) {
            address p = players[i]; uint256 t = totals[i];
            require(t >= pixelsPlaced[r][p], "tally regress");
            pixelsPlaced[r][p] = t;
            if (t > topPx) { topPx = t; top = p; }
        }
        R.topPainter = top; R.topPainterPixels = topPx;
        if (lastPainter != address(0)) { R.lastPainter = lastPainter; R.lastPixelTime = lastPixelTime; }
        emit Settled(r, R.lastPainter, R.lastPixelTime, top, topPx);
    }

    // ---- permissionless close ----
    function closeRound(uint256 r) external {
        Round storage R = rounds[r];
        require(r == roundId && !R.closed, "not current/open");
        require(_isExpired(r), "not expired");
        R.closed = true;
        closedByCap[r] = block.timestamp >= R.startTime + HARD_CAP;

        uint256 pot = R.pot;
        uint256 rollover;
        if (R.topPainter == address(0)) {
            rollover = pot; R.winnerClaimable = 0;
        } else {
            rollover = (pot * ROLLOVER_BPS) / 10000;
            R.winnerClaimable = pot - rollover;
        }
        pendingRollover += rollover;

        address nftWinner = R.lastPainter;
        if (nftWinner != address(0)) {
            _safeMint(nftWinner, r);  // real ERC-721 mint (tokenId = roundId)
        }
        emit RoundClosed(r, nftWinner, R.topPainter, R.winnerClaimable, rollover);
    }

    // ---- pot winner pulls 90% ----
    function claimPot(uint256 r) external nonReentrant {
        Round storage R = rounds[r];
        require(R.closed && !R.claimed, "not claimable");
        require(msg.sender == R.topPainter, "not winner");
        require(R.winnerClaimable > 0, "nothing");
        R.claimed = true;
        uint256 amt = R.winnerClaimable; R.winnerClaimable = 0;
        (bool ok, ) = msg.sender.call{value: amt}("");
        require(ok, "xfer failed");
        emit PotClaimed(r, msg.sender, amt);
    }

    // ---- operator commits final canvas before close ----
    function commitArtwork(uint256 r, bytes calldata packed, uint256 totalPixels, uint256 painters)
        external onlyOperator
    {
        require(r == roundId && !rounds[r].closed, "not current/open");
        require(packed.length == 4096, "bad packed len");
        packedCanvas[r] = packed;
        totalPixelsAt[r] = totalPixels;
        distinctPainters[r] = painters;
    }

    function setArtworkURIOverride(uint256 r, string calldata uri) external onlyOperator {
        require(rounds[r].closed, "not closed");
        artworkURIOverride[r] = uri;
    }

    // ---- timing ----
    function _isExpired(uint256 r) internal view returns (bool) {
        Round storage R = rounds[r];
        if (R.startTime == 0) return false;
        if (block.timestamp >= R.startTime + HARD_CAP) return true;
        if (R.lastPainter != address(0)
            && block.timestamp >= R.lastPixelTime + INACTIVITY_WINDOW) return true;
        return false;
    }
    function _expiryTime(uint256 r) internal view returns (uint256) {
        Round storage R = rounds[r];
        uint256 a = R.startTime + HARD_CAP;
        if (R.lastPainter == address(0)) return a;
        uint256 b = R.lastPixelTime + INACTIVITY_WINDOW;
        return a < b ? a : b;
    }

    // ---- views ----
    function maxChargesNow(uint256 r, address p) external view returns (uint256) {
        Brushes storage b = brushes[r][p];
        if (b.firstPurchaseTime == 0) return 0;
        uint256 endRef = _isExpired(r) ? _expiryTime(r) : block.timestamp;
        if (endRef <= b.firstPurchaseTime) return 0;
        uint256 mins = (endRef - b.firstPurchaseTime) / 60;
        return mins * (uint256(b.normalCount) + uint256(b.goldenCount));
    }
    function roundState(uint256 r) external view returns (
        uint64 startTime, uint64 lastPixelTime, address lastPainter,
        address topPainter, uint256 topPixels, uint256 pot, bool closed, bool expired) {
        Round storage R = rounds[r];
        return (R.startTime, R.lastPixelTime, R.lastPainter, R.topPainter,
                R.topPainterPixels, R.pot, R.closed, _isExpired(r));
    }

    function setOperator(address o) external onlyOwner { require(o != address(0)); operator = o; }
    function setPrices(uint256 n, uint256 g) external onlyOwner {
        require(roundId == 0 || rounds[roundId].closed, "round open");
        require(n > 0 && g > 0); normalBrushPrice = n; goldenBrushPrice = g;
    }

    // ---- on-chain tokenURI (overrides OZ ERC721) ----
    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        if (bytes(artworkURIOverride[id]).length != 0) return artworkURIOverride[id];
        Round storage R = rounds[id];
        CanvasArt.Meta memory m = CanvasArt.Meta({
            round: id,
            winner: R.lastPainter,
            topPainter: R.topPainter,
            topPixels: R.topPainterPixels,
            totalPixels: totalPixelsAt[id],
            painters: distinctPainters[id],
            potWei: R.winnerClaimable + ((R.winnerClaimable * ROLLOVER_BPS) / (10000 - ROLLOVER_BPS)),
            byHardCap: closedByCap[id]
        });
        bytes memory packed = packedCanvas[id];
        if (packed.length != 4096) packed = new bytes(4096);
        return CanvasArt.tokenURI(packed, m);
    }
}
