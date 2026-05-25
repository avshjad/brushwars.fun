# BrushWars — Testnet Testing Guide (WSL / VS Code)

Goal: deploy BrushWars to **Monad testnet (chain 10143)** from your WSL Ubuntu
box and play the full loop end-to-end before you ever touch mainnet.

Everything is pre-wired for testnet: chain 10143, RPC `https://testnet-rpc.monad.xyz`,
the real function selectors are already filled into the frontend, and prices are
tiny (0.01 / 0.05 MON) so testing is cheap.

> **Note on the test setup:** for simplicity your single dev wallet acts as BOTH
> owner and operator. That's fine for testing. On mainnet you'll use a SEPARATE
> operator key — the README covers why.

---

## 0. What you already have
- WSL Ubuntu + VS Code ✅
- Phantom wallet with testnet MON ✅
- A `.env` with `PRIVATE_KEY`, `MONAD_TESTNET_RPC`, `DEV_ADDRESS` ✅

Put the `brushwars-test/` folder somewhere in your WSL filesystem (NOT under
`/mnt/c/...` — keep it in the Linux fs, e.g. `~/brushwars-test`, it's much
faster). Open it in VS Code with `code .` from inside the folder.

---

## 1. Install the toolchain (one time)

Open the WSL terminal in VS Code (`Ctrl+~`) and run:

```bash
# Node.js 20 (for the operator)
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs

# Foundry (forge — compiles & deploys the contract)
curl -L https://foundry.paradigm.xyz | bash
source ~/.bashrc        # or restart the terminal
foundryup

# verify
node -v        # should print v20.x
forge --version
```

---

## 2. Set up the project

From inside the `brushwars-test/` folder:

```bash
# install Foundry's standard library (forge-std, used by the deploy script)
forge install foundry-rs/forge-std --no-commit

# install operator dependencies
cd operator && npm install && cd ..
```

Now add your real `.env`. You already have one in your format — make sure it
lives in the project root as `.env` and looks like this (PRIVATE_KEY filled in):

```bash
export PRIVATE_KEY=0xYOUR_TESTNET_KEY
export MONAD_TESTNET_RPC=https://testnet-rpc.monad.xyz
export DEV_ADDRESS=0x9e203A97e296A50d8416d00D4d7e5E7582DA48CC
export CONTRACT=          # fill after step 4
export CHAIN_ID=10143
```

Load it into your shell (do this in every new terminal you open):

```bash
source .env
```

> `.gitignore` already excludes `.env` so your key never gets committed.

---

## 3. Compile the contract

```bash
forge build
```

You should see it compile with no errors. (It's set to `via_ir = true` in
`foundry.toml` — required, or you'd hit a "stack too deep" error.)

---

## 4. Deploy to testnet + start round 1

```bash
forge script script/Deploy.s.sol \
  --rpc-url $MONAD_TESTNET_RPC \
  --broadcast
```

This deploys BrushWars, sets your `DEV_ADDRESS` as operator, and calls
`startRound()` — all in one go. At the end it prints:

```
BrushWars deployed at: 0x........................................
```

**Copy that address.** Then:
1. Put it in `.env` as `CONTRACT=0x...` and re-run `source .env`.
2. Open `web/brushwars.html` and set `CONTRACT:"0x..."` in the `CONFIG` block
   near the top of the `<script>` (currently `CONTRACT:""`).

You can check it landed on the explorer:
`https://testnet.monadexplorer.com/address/<your-contract-address>`

---

## 5. Run the operator

The operator enforces cooldowns, territories, the poll, and settles to the
contract. In a terminal (with `.env` sourced so it sees CONTRACT + PRIVATE_KEY):

```bash
cd operator
node operator.js
```

You should see:
```
operator on :8787, round 1
```

Leave this running. Every ~20s it'll print `settled ...` once you've painted.

---

## 6. Open the frontend

The frontend is a single HTML file — no build step. Easiest way to serve it so
the wallet + websocket work:

```bash
# in a SECOND terminal, from the project root
cd web
python3 -m http.server 5500
```

Open **http://localhost:5500/brushwars.html** in the browser where Phantom
lives.

> Opening the file directly (file://) can break wallet/websocket — use the
> http.server URL.

---

## 7. Play the loop

1. **Connect** — Phantom pops up. Approve. It'll offer to add/switch to Monad
   Testnet (chain 10143) automatically. Approve that too.
2. **Buy brushes** — set a quantity, hit BUY. Phantom asks you to sign a real
   testnet tx (pays a sliver of test MON). This is the only tx you sign to play.
3. **Watch the drip** — the charge meter fills 1/min per brush. Wait a minute,
   you get a charge.
4. **Paint** — click the canvas. Gasless (no popup) — it posts to your operator.
5. **Try golden** — toggle "use golden", and you can overpaint occupied tiles.
6. **Fund Pot** — drop some test MON into the pot via `seedPot()` (another
   signed tx).
7. **War room** — propose a theme, vote.
8. **Watch the operator terminal** — you'll see `settled ...` lines and, hourly,
   territory redraws.

### Testing the endgame fast
The real round is 30-min-inactivity / 12-h-cap, which is too long to wait for.
To test close + prize payout quickly, temporarily shrink the windows:
- In `operator/operator.js`, change `INACTIVITY_MS=30*60_000` to e.g.
  `INACTIVITY_MS=60_000` (1 min). Restart the operator.
- Paint once, then stop for a minute. The operator will call `closeRound()`.
- The NFT mints to the last painter; the pot winner can `claimPot()`.
- **Remember to change it back** before mainnet.

> The contract's own `INACTIVITY_WINDOW`/`HARD_CAP` are fixed at 30min/12h, so
> for a *full* close test you'd shorten those constants in `BrushWars.sol` and
> redeploy. For just exercising the operator/settle flow, the operator-side
> change is enough.

---

## 8. Reading what happened on-chain

Everything money-related is verifiable on the explorer:
`https://testnet.monadexplorer.com/address/<contract>` → Transactions / Events.
You'll see `BrushesBought`, `PotSeeded`, `Settled`, `RoundClosed`, `Transfer`
(the NFT mint), `PotClaimed`.

---

## Common snags

- **"insufficient funds" on deploy** → your dev wallet has no testnet MON, or
  `.env` wasn't sourced. `source .env` and check the faucet.
- **Operator: "could not detect network"** → CONTRACT not set in env, or wrong
  RPC. Re-`source .env`, confirm `echo $CONTRACT` prints the address.
- **Wallet won't switch network** → add Monad Testnet manually in Phantom:
  RPC `https://testnet-rpc.monad.xyz`, Chain ID `10143`, symbol `MON`.
- **Painting does nothing** → operator not running, or frontend `OPERATOR_API`
  not pointing at `http://localhost:8787`. Check the operator terminal for
  errors.
- **No real-time pixels from a second browser** → that needs the websocket
  (`OPERATOR_WS=ws://localhost:8787`, already set) and the operator running.
- **Stack too deep on build** → `via_ir` got turned off; it's in `foundry.toml`,
  don't remove it.

---

## When testnet looks good → mainnet checklist
1. Add **signed placements** (the NFT-integrity hardening) — most important.
2. Swap hand-rolled ERC721/Ownable/guard for OpenZeppelin.
3. Use a **separate operator key** (not your owner key).
4. Persist operator state to a DB; run it redundantly.
5. Set real prices to hit ~$1 / ~$5 at the current MON price.
6. Get an audit.
7. Deploy to chain 143 with the mainnet RPC.
```
