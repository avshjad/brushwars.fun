/*
 * BrushWars operator
 * ==================
 * Off-chain authority for everything too expensive or too fast for the chain:
 *   - the live canvas bitmap + REAL-TIME pixel broadcast (websocket)
 *   - per-brush cooldown drip enforcement
 *   - tile rules (normal=empty only; golden=anywhere, counts)
 *   - TERRITORIES: noise/Voronoi regions, redrawn hourly, contested-hold check,
 *     >=20 paid-pixel gate, +1 free px/min bonus, capped +50 pot-pixels/terr/round
 *   - the build-idea POLL (vote this round for next round's theme)
 * Settles money-relevant state to BrushWars.sol:
 *   - settle(): per-player TOTALS (paid + capped bonus) + last-painter + ts
 *   - closeRound() when a close condition is met
 *
 * Holds no funds, cannot pay itself. Back maps with a DB for real use.
 *   npm i express ws ethers
 *   OPERATOR_PK=0x.. CONTRACT=0x.. node operator.js
 */
import express from "express";
import { WebSocketServer } from "ws";
import { ethers } from "ethers";
import { readFileSync, writeFileSync, existsSync } from "fs";

const RPC=process.env.MONAD_TESTNET_RPC||process.env.RPC||"https://testnet-rpc.monad.xyz";
const CONTRACT=process.env.CONTRACT, PK=process.env.PRIVATE_KEY||process.env.OPERATOR_PK;
// fail fast with a clear message if required config is missing (e.g. a Railway
// env var wasn't set) instead of crashing with a cryptic ethers error later.
if(!CONTRACT){ console.error("FATAL: CONTRACT env var is not set (the deployed contract address)."); process.exit(1); }
if(!PK){ console.error("FATAL: OPERATOR_PK (or PRIVATE_KEY) env var is not set (the operator wallet key)."); process.exit(1); }
if(!/^0x[0-9a-fA-F]{40}$/.test(CONTRACT)){ console.error("FATAL: CONTRACT is not a valid address:",CONTRACT); process.exit(1); }
const GRID=64, EMPTY="empty"; // sentinel: never a real palette color, always maps to background

// 64-color palette — MUST be byte-identical to CanvasArt.sol palette() and the
// frontend PALETTE. index 0 = background (#000000). A pixel painted with the
// index-0 color still registers as "painted" (EMPTY is a separate sentinel).
const PALETTE=["#000000","#222034","#45283c","#663931","#8f563b","#df7126","#d9a066","#eec39a","#fbf236","#99e550","#6abe30","#37946e","#4b692f","#524b24","#323c39","#3f3f74","#306082","#5b6ee1","#639bff","#5fcde4","#cbdbfc","#ffffff","#9badb7","#847e87","#696a6a","#595652","#76428a","#ac3232","#d95763","#d77bba","#8f974a","#8a6f30","#0a0a0a","#3b3b3b","#5c5c5c","#7d7d7d","#a0a0a0","#c4c4c4","#e0e0e0","#f5f5f5","#5a1e0a","#7a2d10","#a83b1e","#cf5a2e","#e88a4d","#f2b079","#f7d2a8","#fce8cf","#1a3a1a","#2d5e2d","#3f8a3f","#5cb85c","#8ad98a","#1a2a4a","#2d4a7a","#3f6aad","#5c8ad9","#8ab0e8","#2a1a3a","#4a2d6a","#6a3f9a","#9a5cc8","#c08ae0","#e0c0f0"];
const COLOR_IDX=Object.fromEntries(PALETTE.map((c,i)=>[c.toLowerCase(),i]));
// pack the 64x64 canvas into 4096 bytes, 1 byte per pixel (palette index 0-63).
// EMPTY sentinel -> index 0 (background). Unknown colors -> 0 too.
function packCanvas(){
  const out=Buffer.alloc(4096);
  for(let p=0;p<GRID*GRID;p++){
    const c=canvas[p];
    if(!c||c===EMPTY){ out[p]=0; continue; }
    out[p]=COLOR_IDX[c.toLowerCase()]??0;
  }
  return "0x"+out.toString("hex");
}
// TESTNET timing — match the contract. Revert for mainnet:
// PRODUCTION timings — MUST match the contract (INACTIVITY_WINDOW=30min, HARD_CAP=12h).
const SETTLE_MS=20_000, INACTIVITY_MS=30*60_000, HARD_CAP_MS=12*3_600_000;
const TERR_COUNT=9, COMMONS_RADIUS=9;          // central neutral zone
const BONUS_GATE=20, BONUS_CAP=50;             // >=20 paid to unlock; <=50 bonus pot-pixels/terr
const REDRAW_MS=60*60_000;                     // territories redrawn hourly

const ABI=[
  "function roundId() view returns (uint256)",
  "function roundState(uint256) view returns (uint64,uint64,address,address,uint256,uint256,bool,bool)",
  "function pixelsPlaced(uint256,address) view returns (uint256)",
  "function brushes(uint256,address) view returns (uint64 normalCount,uint64 goldenCount,uint64 firstPurchaseTime)",
  "function settle(uint256 r,address[] players,uint256[] totals,address lastPainter,uint64 lastPixelTime)",
  "function commitArtwork(uint256 r,bytes packed,uint256 totalPixels,uint256 painters)",
  "function closeRound(uint256 r)"
];
const CHAIN_ID=Number(process.env.CHAIN_ID||10143); // 10143 testnet, 143 mainnet
const provider=new ethers.JsonRpcProvider(RPC,CHAIN_ID);
const wallet=new ethers.Wallet(PK,provider);
const contract=new ethers.Contract(CONTRACT,ABI,wallet);

// ---------- canvas + ledgers ----------
let closing=false;            // guard so we only close a round once
const canvas=new Array(GRID*GRID).fill(EMPTY);
const ownerOf=new Array(GRID*GRID).fill(null);     // addr who owns each tile
const paidByTerr=new Map();   // `${addr}:${terr}` -> paid pixels in that territory
const bonusByTerr=new Map();  // `${addr}:${terr}` -> bonus pot-pixels credited (<=CAP)
const paidTotal=new Map();    // addr -> paid pixels (whole round)
const spent=new Map();        // addr -> charges consumed (cooldown math)
const brushCache=new Map();
let lastPainter=ethers.ZeroAddress, lastPixelMs=Date.now(), roundStartMs=Date.now(), activeRound=0;

// ---------- territory map (Voronoi from hourly-seeded jittered points) ----------
let territory=new Array(GRID*GRID).fill(0);        // tile -> territory id (0 = commons)
let terrEpoch=0;

// ---------- persistence ----------
// The operator's game state is in RAM; without this, restarting wipes the live
// canvas mid-round. We snapshot to a JSON file (keyed by round) and reload it on
// boot if the round still matches. Maps/Sets are converted to arrays for JSON.
// Persistence: locally this is ./state.json. On Railway, set STATE_FILE to a
// path inside an attached VOLUME (e.g. /data/state.json) so the canvas survives
// not just restarts but redeploys. Without a volume, state survives restarts
// within a deployment but resets when you push new code (fine if you redeploy
// only between rounds).
const STATE_FILE = process.env.STATE_FILE || "./state.json";
let saveTimer = null;
function saveState(){
  // debounce: collapse rapid changes into one write per ~2s
  if (saveTimer) return;
  saveTimer = setTimeout(() => {
    saveTimer = null;
    try {
      const snap = {
        round: activeRound,
        canvas, ownerOf, territory, terrEpoch,
        lastPainter, lastPixelMs, roundStartMs, closing,
        paidByTerr: [...paidByTerr], bonusByTerr: [...bonusByTerr],
        paidTotal: [...paidTotal], spent: [...spent],
        poll: [...poll].map(([idea, voters]) => [idea, [...voters]]),
      };
      writeFileSync(STATE_FILE, JSON.stringify(snap));
    } catch (e) { console.error("saveState:", e.message); }
  }, 2000);
}
function loadState(forRound){
  try {
    if (!existsSync(STATE_FILE)) return false;
    const s = JSON.parse(readFileSync(STATE_FILE, "utf8"));
    // only restore if the saved state is for the round we're actually on,
    // otherwise it's stale (round advanced while we were down) — start fresh.
    if (s.round !== forRound) { console.log(`saved state was round ${s.round}, now ${forRound} — starting fresh`); return false; }
    for (let i = 0; i < canvas.length; i++) { canvas[i] = s.canvas[i]; ownerOf[i] = s.ownerOf[i]; }
    if (s.territory) { for (let i = 0; i < territory.length; i++) territory[i] = s.territory[i]; terrEpoch = s.terrEpoch || 0; }
    lastPainter = s.lastPainter || ethers.ZeroAddress;
    lastPixelMs = s.lastPixelMs || Date.now();
    roundStartMs = s.roundStartMs || roundStartMs;
    closing = !!s.closing;
    paidByTerr.clear(); (s.paidByTerr||[]).forEach(([k,v]) => paidByTerr.set(k, v));
    bonusByTerr.clear(); (s.bonusByTerr||[]).forEach(([k,v]) => bonusByTerr.set(k, v));
    paidTotal.clear(); (s.paidTotal||[]).forEach(([k,v]) => paidTotal.set(k, v));
    spent.clear(); (s.spent||[]).forEach(([k,v]) => spent.set(k, v));
    poll.clear(); (s.poll||[]).forEach(([idea, voters]) => poll.set(idea, new Set(voters)));
    const painted = canvas.filter(c => c && c !== EMPTY).length;
    console.log(`restored state for round ${forRound}: ${painted} pixels, ${paidTotal.size} painters`);
    return true;
  } catch (e) { console.error("loadState:", e.message); return false; }
}

function rng(seed){ let s=seed>>>0; return ()=>{ s=(s*1664525+1013904223)>>>0; return s/4294967296; }; }
function buildTerritories(epoch){
  const rnd=rng((activeRound*100003)^(epoch*7919));
  const seeds=[];
  for(let i=0;i<TERR_COUNT;i++) seeds.push({x:rnd()*GRID,y:rnd()*GRID,id:i+1});
  const cx=GRID/2, cy=GRID/2;
  for(let y=0;y<GRID;y++) for(let x=0;x<GRID;x++){
    const idx=y*GRID+x;
    if(Math.hypot(x-cx,y-cy)<COMMONS_RADIUS){ territory[idx]=0; continue; } // commons
    let best=1e9, id=0;
    for(const s of seeds){ const d=Math.hypot(x-s.x,y-s.y)+(rnd()-0.5)*3; if(d<best){best=d;id=s.id;} }
    territory[idx]=id;
  }
  terrEpoch=epoch;
  // hourly redraw resets territory-scoped progress (holds must be re-earned)
  paidByTerr.clear(); bonusByTerr.clear();
  broadcast({type:"territories",map:territory,epoch});
}

// who holds territory t? the sole owner of ALL painted tiles in it, if any
function holderOf(t){
  let holder=null;
  for(let i=0;i<territory.length;i++) if(territory[i]===t && ownerOf[i]){
    if(holder===null) holder=ownerOf[i];
    else if(holder!==ownerOf[i]) return null;   // contested
  }
  return holder;
}

// richer per-territory status for the UI: open / contested / held + progress
function territoryStatus(){
  const out=[];
  for(let t=1;t<=TERR_COUNT;t++){
    // count painted tiles + distinct owners in this territory
    let painted=0, sole=null, contested=false;
    for(let i=0;i<territory.length;i++) if(territory[i]===t && ownerOf[i]){
      painted++;
      if(sole===null) sole=ownerOf[i];
      else if(sole!==ownerOf[i]) contested=true;
    }
    let state, holder=null, paidHere=0, bonus=0, earning=false;
    if(painted===0){ state="open"; }
    else if(contested){ state="contested"; }
    else {
      state="held"; holder=sole;
      paidHere=paidByTerr.get(`${sole}:${t}`)||0;
      bonus=bonusByTerr.get(`${sole}:${t}`)||0;
      earning = paidHere>=BONUS_GATE && bonus<BONUS_CAP;
    }
    out.push({t,state,holder,paidHere,gate:BONUS_GATE,bonus,cap:BONUS_CAP,earning});
  }
  return out;
}

// ---------- websocket broadcast ----------
let wss=null;
function broadcast(obj){ if(!wss) return; const m=JSON.stringify(obj); wss.clients.forEach(c=>{ if(c.readyState===1) c.send(m); }); }

// ---------- chain sync ----------
async function syncRound(boot){
  activeRound=Number(await contract.roundId());
  const s=await contract.roundState(activeRound);
  roundStartMs=Number(s[0])*1000;
  lastPixelMs=Math.max(lastPixelMs,Number(s[1])*1000);
  // at startup, try to restore the saved canvas/ledgers for this exact round.
  // if it restores, keep its territory map; otherwise generate fresh.
  if(boot && loadState(activeRound)) { await floorTalliesToChain(); return; }
  buildTerritories(Math.floor((Date.now()-roundStartMs)/REDRAW_MS));
  await floorTalliesToChain();
}

// The contract's settle() rejects any tally lower than what it already recorded
// ("tally regress"). After a restart/resync our in-memory paidTotal can come back
// LOWER than what's already on-chain (stale state, a reset, etc.), which would make
// every settle revert forever and freeze the round. So whenever we (re)sync, read
// the chain's recorded tally for each known painter and never let our number be
// below it. Chain truth wins.
async function floorTalliesToChain(){
  try{
    const addrs=new Set([...paidTotal.keys()]);
    // also include anyone who currently owns a tile (they painted this round)
    for(const o of ownerOf){ if(o) addrs.add(o); }
    for(const a of addrs){
      const onChain=Number(await contract.pixelsPlaced(activeRound,a));
      if(onChain>(paidTotal.get(a)||0)) paidTotal.set(a,onChain);
    }
    if(addrs.size) console.log(`floored tallies to chain for ${addrs.size} painters`);
  }catch(e){ console.error("floorTalliesToChain:",e.message); }
}
async function charges(addr){
  if(!brushCache.has(addr)){
    const b=await contract.brushes(activeRound,addr);
    brushCache.set(addr,{total:Number(b.normalCount)+Number(b.goldenCount),golden:Number(b.goldenCount),firstTs:Number(b.firstPurchaseTime)});
  }
  const b=brushCache.get(addr);
  if(!b.firstTs||b.total===0) return {charges:0,golden:0};
  const mins=Math.floor((Date.now()/1000-b.firstTs)/60);
  return {charges:Math.max(0,mins*b.total-(spent.get(addr)||0)),golden:b.golden};
}

// ---------- HTTP ----------
const app=express(); app.use(express.json());
// CORS: allow the frontend (served from a different port) to call the operator.
// Permissive is fine for local testing; tighten the origin for production.
app.use((req,res,next)=>{
  res.header("Access-Control-Allow-Origin","*");
  res.header("Access-Control-Allow-Methods","GET,POST,OPTIONS");
  res.header("Access-Control-Allow-Headers","Content-Type");
  if(req.method==="OPTIONS") return res.sendStatus(204);
  next();
});

// place a PAID pixel (drip charge). gasless — no tx.
app.post("/place",async(req,res)=>{
  const {addr,x,y,color,gold}=req.body||{};
  if(!ethers.isAddress(addr)||x<0||x>=GRID||y<0||y>=GRID) return res.status(400).end();
  const {charges:ch,golden}=await charges(addr);
  if(ch<1) return res.status(402).json({error:"no charges (cooldown)"});
  const idx=y*GRID+x, occupied=canvas[idx]!==EMPTY, t=territory[idx];
  if(occupied&&!gold) return res.status(403).json({error:"occupied: needs golden"});
  if(gold&&golden<1) return res.status(403).json({error:"no golden brushes"});

  canvas[idx]=color; ownerOf[idx]=addr;
  spent.set(addr,(spent.get(addr)||0)+1);
  paidTotal.set(addr,(paidTotal.get(addr)||0)+1);
  if(t!==0){ const k=`${addr}:${t}`; paidByTerr.set(k,(paidByTerr.get(k)||0)+1); }
  lastPainter=addr; lastPixelMs=Date.now();
  saveState();
  broadcast({type:"pixel",x,y,color,addr,last:true});
  res.json({ok:true,paid:paidTotal.get(addr)});
});

// full state for new clients (used to restore the UI after a reload)
app.get("/canvas",async(_q,res)=>{
  let potWei="0";
  try{ const s=await contract.roundState(activeRound); potWei=s[5].toString(); }catch(e){}
  res.json({grid:GRID,pixels:canvas,territory,lastPainter,
    status:territoryStatus(),
    board:[...paidTotal].map(([addr,px])=>({addr,px})),
    roundStartMs, lastPixelMs, potWei,
    hasPainted: lastPainter && lastPainter !== ethers.ZeroAddress,
    endsAt:Math.min(roundStartMs+HARD_CAP_MS,lastPixelMs+INACTIVITY_MS)});
});

// authoritative charge count for one address (chain-derived, bypasses cache)
app.get("/charges/:addr",async(req,res)=>{
  const addr=req.params.addr;
  if(!ethers.isAddress(addr)) return res.status(400).json({error:"bad addr"});
  brushCache.delete(addr);          // force a fresh chain read
  try{ const c=await charges(addr); res.json(c); }
  catch(e){ res.status(500).json({error:e.shortMessage||e.message}); }
});

// ---------- POLL (off-chain coordination) ----------
// ideas + votes for the NEXT round's theme. wiped at round close.
const poll=new Map();            // idea -> Set(addr)
app.post("/poll/add",(req,res)=>{ const {idea}=req.body||{}; if(idea&&!poll.has(idea)) poll.set(idea,new Set()); saveState(); res.json({ok:true}); });
app.post("/poll/vote",(req,res)=>{ const {addr,idea}=req.body||{}; if(poll.has(idea)){ for(const s of poll.values()) s.delete(addr); poll.get(idea).add(addr);} saveState(); broadcast(pollState()); res.json({ok:true}); });
app.get("/poll",(_q,res)=>res.json(pollState()));
function pollState(){ return {type:"poll",ideas:[...poll].map(([idea,v])=>({idea,votes:v.size})).sort((a,b)=>b.votes-a.votes)}; }

// ---------- total each player gets credited toward the pot ----------
// = paid pixels + capped territory bonus. Bonus is accrued each settle tick
// for territories the player holds uncontested with >=BONUS_GATE paid pixels.
function accrueBonusAndTotals(){
  // grant +1 bonus pot-pixel per held, gated, uncapped territory, per tick
  // (a tick is ~SETTLE_MS; for true per-minute, scale by elapsed minutes)
  for(let t=1;t<=TERR_COUNT;t++){
    const h=holderOf(t); if(!h) continue;
    const k=`${h}:${t}`;
    if((paidByTerr.get(k)||0)<BONUS_GATE) continue;        // >=20 paid gate
    const cur=bonusByTerr.get(k)||0;
    if(cur>=BONUS_CAP) continue;                            // +50 cap
    bonusByTerr.set(k,cur+1);
  }
  const totals=new Map();
  for(const [a,p] of paidTotal) totals.set(a,p);
  for(const [k,b] of bonusByTerr){ const a=k.split(":")[0]; totals.set(a,(totals.get(a)||0)+b); }
  return totals;
}

// ---------- settle + redraw + close loop ----------
setInterval(async()=>{
  if(!activeRound){ await syncRound().catch(()=>{}); return; }
  // self-heal: if the chain advanced to a new round by ANY means (operator
  // auto-start, manual owner start, permissionless start), notice it and reset
  // to the fresh round instead of serving the old one forever.
  try{
    const chainRound = Number(await contract.roundId());
    if(chainRound !== activeRound && !closing){
      console.log(`round changed on-chain: ${activeRound} -> ${chainRound}, resyncing`);
      canvas.fill(EMPTY); ownerOf.fill(null);
      paidByTerr.clear(); bonusByTerr.clear(); paidTotal.clear(); spent.clear(); brushCache.clear();
      poll.clear(); lastPainter=ethers.ZeroAddress;
      await syncRound(); saveState();
      broadcast({type:"closed",round:activeRound-1,nft:null}); // nudge clients to refresh
      return; // start clean next tick
    }
  }catch(e){ /* RPC hiccup; try again next tick */ }
  brushCache.clear();

  // hourly territory redraw
  const epoch=Math.floor((Date.now()-roundStartMs)/REDRAW_MS);
  if(epoch!==terrEpoch) buildTerritories(epoch);

  const totals=accrueBonusAndTotals();
  saveState();
  broadcast({type:"territoryStatus",status:territoryStatus()});
  const players=[...totals.keys()];
  if(players.length){
    try{
      // Final guard: never send a tally below what the chain already has, or
      // settle() reverts with "tally regress" and the round freezes. Clamp each
      // total up to the on-chain value if ours somehow drifted lower.
      const sendTotals=[];
      for(const p of players){
        let v=totals.get(p);
        try{ const oc=Number(await contract.pixelsPlaced(activeRound,p)); if(oc>v){ v=oc; paidTotal.set(p,oc); } }catch{}
        sendTotals.push(v);
      }
      const tx=await contract.settle(activeRound,players,sendTotals,lastPainter,Math.floor(lastPixelMs/1000));
      await tx.wait();
      const top=[...players.map((p,i)=>[p,sendTotals[i]])].sort((a,b)=>b[1]-a[1])[0];
      broadcast({type:"leaderboard",top:top?{addr:top[0],px:top[1]}:null,lastPainter});
      console.log(`settled ${players.length}, last=${lastPainter.slice(0,8)}`);
    }catch(e){ console.error("settle:",e.shortMessage||e.message); }
  }

  const now=Date.now();
  const hasActivity = lastPainter && lastPainter !== ethers.ZeroAddress;
  const capHit = now >= roundStartMs + HARD_CAP_MS;
  const idleHit = hasActivity && now >= lastPixelMs + INACTIVITY_MS;
  if((capHit || idleHit) && !closing){
    closing=true;
    try{
      // commit the final canvas on-chain FIRST so the minted NFT has real art
      const totalPixels=[...paidTotal.values()].reduce((a,b)=>a+b,0);
      const painters=paidTotal.size;
      try{ await (await contract.commitArtwork(activeRound, packCanvas(), totalPixels, painters)).wait();
        console.log(`committed artwork for round ${activeRound} (${totalPixels}px, ${painters} painters)`);
      }catch(e){ console.error("commitArtwork:",e.shortMessage||e.message); }

      await (await contract.closeRound(activeRound)).wait();
      // read back the recorded winners to tell clients who can claim
      let potWinner=ethers.ZeroAddress, claimable=0n;
      try{ const s=await contract.roundState(activeRound); potWinner=s[3]; }catch(e){}
      broadcast({type:"closed",round:activeRound,nft:lastPainter,potWinner});
      poll.clear();
      console.log(`round ${activeRound} closed, NFT->${lastPainter.slice(0,8)}`);
      console.log("intermission: starting next round in 2 min...");
      setTimeout(async()=>{
        try{
          await (await new ethers.Contract(CONTRACT,["function startRound()"],wallet).startRound()).wait();
          canvas.fill(EMPTY); ownerOf.fill(null);
          paidByTerr.clear(); bonusByTerr.clear(); paidTotal.clear(); spent.clear(); brushCache.clear();
          poll.clear(); lastPainter=ethers.ZeroAddress; await syncRound(); closing=false;
          saveState();
          console.log(`new round ${activeRound} started`);
        }catch(e){ console.error("startRound:",e.shortMessage||e.message); closing=false; }
      }, 2*60_000);
    }catch(e){ console.error("close:",e.shortMessage||e.message); closing=false; }
  }
},SETTLE_MS);

const PORT=Number(process.env.PORT||8787);
const server=app.listen(PORT,async()=>{ await syncRound(true).catch(()=>{}); console.log(`operator on :${PORT}, round`,activeRound); });
wss=new WebSocketServer({server});
wss.on("connection",ws=>{ ws.send(JSON.stringify({type:"territories",map:territory,epoch:terrEpoch})); ws.send(JSON.stringify({type:"territoryStatus",status:territoryStatus()})); ws.send(JSON.stringify(pollState())); });
