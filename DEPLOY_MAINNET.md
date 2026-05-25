# BrushWars — Mainnet Launch Guide

Three pieces go live: the **contract** (Monad mainnet, chain 143), the **operator**
(Railway, always-on), and the **frontend** (Vercel, static).

Wallet roles (already decided):
- **Owner / fees:** `0x083a790158E979e45f7395d44cD2E6fd5D6C2571` — deploy FROM this
  wallet (owner = deployer). Receives 70% of sales, controls the game. Keep safe.
- **Operator:** `0x156af9B749d5b68E9786CDB1E5bE797538cc9fD8` — gas-only, runs the
  server. Can only report results, never touches funds.

Prices (locked): 40 MON normal, 190 MON golden (~$1 / ~$5 at ~$0.025/MON).
- NORMAL_PRICE_WEI = 40000000000000000000
- GOLDEN_PRICE_WEI = 190000000000000000000

---

## ⚠️ BEFORE YOU DEPLOY — revert test timings to production

In `contracts/BrushWars.sol`:
    INACTIVITY_WINDOW = 30 minutes;   // was 5 minutes
    HARD_CAP          = 12 hours;     // was 1 hours

In `operator/operator.js` (search SETTLE_MS / INACTIVITY_MS / HARD_CAP_MS):
    INACTIVITY_MS = 30*60_000;        // was 5*60_000
    HARD_CAP_MS   = 12*3_600_000;     // was 60*60_000
    SETTLE_MS     = 20_000;           // was 10_000 (less gas on mainnet)

Frontend clock (brushwars.html, search capEnd / inactEnd): match 12h / 30m.

---

## 1. Deploy the contract

Fund `0x083a…` with a little MON for deploy gas. Then:

```bash
cd ~/Brushgame/files
export OWNER_PK=<private key of 0x083a790158E979e45f7395d44cD2E6fd5D6C2571>
export OPERATOR_ADDRESS=0x156af9B749d5b68E9786CDB1E5bE797538cc9fD8
export NORMAL_PRICE_WEI=40000000000000000000
export GOLDEN_PRICE_WEI=190000000000000000000

forge build
forge script script/DeployMainnet.s.sol:DeployMainnet \
  --rpc-url https://monad-mainnet.drpc.org --broadcast
```

Note the deployed address it prints — call it `MAINNET_CONTRACT`.

Do NOT start a round yet (the script doesn't auto-start). Start it once the
operator and frontend are live (step 4).

## 2. Deploy the operator to Railway

Push the `operator/` folder to a GitHub repo (or use Railway's CLI). In Railway:
- New Project → Deploy from repo (point at the operator folder).
- It runs `npm install` then `npm start` (package.json already has the start script).
- Set environment variables:
    CONTRACT      = <MAINNET_CONTRACT from step 1>
    OPERATOR_PK   = <private key of 0x156af9…>   (the gas-only wallet)
    RPC           = https://monad-mainnet.drpc.org
    CHAIN_ID      = 143
    STATE_FILE    = /data/state.json   (only if you attach a volume — see below)
- (Recommended) Add a Volume mounted at `/data` so the canvas survives redeploys.
- Deploy. Logs should show `operator on :<port>, round 0` (round 0 until you start one).

Fund `0x156af9…` with a small amount of MON for ongoing settlement gas.

Railway gives the service a public URL like `https://brushwars-operator.up.railway.app`.
Note it. The websocket URL is the same host with `wss://`.

## 3. Deploy the frontend to Vercel

In `web/brushwars.html`, update the CONFIG block (near the top of the script):
    CHAIN_ID_HEX : "0x8f",                       // 143
    RPC          : "https://monad-mainnet.drpc.org",
    EXPLORER     : "https://monadexplorer.com",
    CONTRACT     : "<MAINNET_CONTRACT>",
    OPERATOR_API : "https://brushwars-operator.up.railway.app",
    OPERATOR_WS  : "wss://brushwars-operator.up.railway.app",
    ADMIN        : "0x083a790158E979e45f7395d44cD2E6fd5D6C2571",  // gates Fund Pot UI

Then deploy to Vercel (drag-drop the file, or connect a repo). Vercel serves it
over https, which is required for the wss:// websocket to work.

## 4. Go live

```bash
cast send <MAINNET_CONTRACT> "startRound()" \
  --rpc-url https://monad-mainnet.drpc.org --private-key $OWNER_PK
```

Restart the operator (or it'll pick up the new round within a settle tick).
Open the Vercel URL, connect MetaMask on Monad mainnet, and play.

## Sanity checks
- `cast call <C> "owner()(address)" --rpc-url <rpc>` → should be 0x083a…
- `cast call <C> "operator()(address)" --rpc-url <rpc>` → should be 0x156af9…
- Operator `/charges/<addr>` returns JSON, `/canvas` returns the board.
- Frontend "HOW IT WORKS" shows the trusted-operator disclosure.

## Trust posture (keep early pots small)
The operator reports results; the contract guards funds. This is disclosed in the
UI. Keep early rounds low-volume while the system proves itself in the wild.
