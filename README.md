# BrushWars 🎨

A paid collaborative pixel canvas on [Monad](https://monad.xyz). Buy brushes, paint
pixels, fight for the board. Every round mints the finished canvas as a fully
on-chain NFT and pays out a pot — winner takes most, the rest rolls into the next
round.

**Play:** [brushwars.fun](https://brushwars.fun)
**Contract (Monad mainnet, chain 143):** [`0x2Ce16B2244D26Faa8aad1aFc5988d73aa5bba3Da`](https://monadexplorer.com/address/0x2Ce16B2244D26Faa8aad1aFc5988d73aa5bba3Da)

---

## How it works

- **Brushes** drip 1 pixel per minute from the moment you buy them until the round ends.
  - *Normal brush* — paints empty tiles only.
  - *Golden brush* — paints anywhere (overpaint included).
- **Painting is gasless** — pixel placements are reported off-chain by an operator.
  The only on-chain transaction a player signs is buying brushes.
- **70%** of every brush purchase goes to the project; **30%** feeds the round **pot**.
- **Two prizes per round:**
  - 🖼 **NFT** — the finished canvas mints to whoever placed the **last pixel**.
  - 💰 **Pot** — goes to whoever placed the **most pixels** (90% to winner, 10% rolls
    into the next round).
- A round closes after **30 minutes of inactivity**, or a **12-hour hard cap** from
  start, whichever comes first.

## Trust model (read this)

BrushWars uses a **trusted-operator** design, and we'd rather be upfront about exactly
what that means than have you discover it:

- **The smart contract holds and distributes all funds.** It controls brush payments,
  the pot, and prize payouts. The operator **cannot** withdraw funds, pay itself, or
  move money — those paths simply don't exist in the contract.
- **The operator reports game results** — who painted which pixel, who placed the last
  one, who has the most. It is a server we run.
- This means the operator's only power is over **fairness of reported results**, not
  custody of funds. It is **not** a fully trustless system. We keep early pots small
  while the project proves itself.
- The finished **artwork and its attributes are stored fully on-chain** and rendered
  by the contract — no IPFS, no external dependency, permanent and verifiable.

If you want to verify any of this, the contract source is in this repo and deployed at
the address above — read it.

## Architecture

| Piece | What it does | Where it runs |
|-------|--------------|---------------|
| `contracts/BrushWars.sol` | Brushes, pot, rounds, payouts, on-chain NFT | Monad mainnet |
| `contracts/CanvasArt.sol` | On-chain SVG + JSON metadata renderer | Monad mainnet |
| `operator/operator.js` | Reports pixels, settles results, closes/starts rounds | Always-on server |
| `web/index.html` | The game UI | Static host |

The contract inherits OpenZeppelin's audited `ERC721`, `Ownable`, and
`ReentrancyGuard`. The NFTs are real ERC-721 tokens minted at round close.

## Running the operator yourself

The operator reads all config from environment variables — no secrets in the code:

```
CONTRACT     = <deployed contract address>
OPERATOR_PK  = <private key of a dedicated, gas-only operator wallet>
RPC          = https://rpc.monad.xyz
CHAIN_ID     = 143
PORT         = 8080
STATE_FILE   = /data/state.json   # optional, for persistence across restarts
```

```bash
cd operator
npm install
npm start
```

> ⚠️ The operator wallet should be a dedicated wallet holding only enough MON for gas
> — never your main wallet. It cannot touch contract funds, but treat its key as a
> secret regardless.

## License

MIT — see [LICENSE](LICENSE).

## Disclaimer

This project is **not audited**. The smart contract is built on OpenZeppelin
components but the game logic is custom. Play with amounts you're comfortable risking,
especially in early rounds. Nothing here is financial advice.