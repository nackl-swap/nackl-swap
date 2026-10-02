// NACKL-Swap web app: reads lots straight from the chain (no backend) and guides pay-to-take.
// The page never asks for keys or seed phrases and never holds coins.
import {
  NETWORKS, DEFAULT_NETWORK, CURRENCIES, PAIRS, FEE_BPS, MAX_TTL_SECONDS, EVENTS_TO_SCAN, POLL_MS, ABI,
} from "./config.js";
import { decodeEvent, encodeCallBody, functionSignature, eventSignature } from "./boc.js";

const net = NETWORKS[DEFAULT_NETWORK];
const HEX64 = /^[0-9a-f]{64}$/;
// ?factory=<hex64> previews another test factory (e.g. right after a test-suite run); otherwise config.js.
const override = (new URLSearchParams(location.search).get("factory") || "").toLowerCase();
const F = HEX64.test(override) ? override : net.factory;
const TEST = !!net.test;              // test network: banner, "test" labels, no real-wallet instructions

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

let IDS = {};
let lots = [];
let loaded = false;
let pairIdx = 0;
let tab = "asks";

// ---------- storage (per-viewer convenience only) ----------
const store = {
  get(k) { try { return localStorage.getItem("ns:" + k) || ""; } catch { return ""; } },
  set(k, v) { try { localStorage.setItem("ns:" + k, v); } catch { /* private mode */ } },
};

// ---------- chain ----------
async function abiId(sig) {
  const h = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(sig));
  return new DataView(h).getUint32(0) & 0x7fffffff;
}
async function gql(query) {
  const r = await fetch(net.graphql, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ query }) });
  if (!r.ok) throw new Error("network error " + r.status);
  const j = await r.json();
  if (j.errors) throw new Error(j.errors[0].message);
  return j.data;
}
async function fetchLots() {
  const d = await gql(`{ blockchain { account(account_id:"${F}", dapp_id:"${F}") {
    messages(msg_type:[ExtOut], last:${EVENTS_TO_SCAN}) { edges { node { body created_at } } } } } }`);
  const out = [];
  for (const { node } of d?.blockchain?.account?.messages?.edges || []) {
    if (!node.body) continue;
    let e;
    try { e = decodeEvent(node.body, ABI.LotCreated, IDS.LotCreated); } catch { continue; }
    if (!e) continue;                                   // other factory events (Refunded)
    const lot = e.lot.split(":")[1];
    if (!HEX64.test(lot)) continue;
    out.push({
      lot, maker: e.maker, giveId: Number(e.giveId), giveAmount: e.giveAmount, wantId: Number(e.wantId),
      wantAmount: e.wantAmount, deadline: Number(e.deadline), createdAt: node.created_at, status: "…", held: 0n,
    });
  }
  return out;
}
async function fetchStatuses(list) {
  for (let i = 0; i < list.length; i += 40) {
    const chunk = list.slice(i, i + 40);
    const q = chunk.map((l, k) => `a${k}: account(account_id:"${l.lot}", dapp_id:"${F}") {
      info { acc_type balance_other { currency value(format:DEC) } } }`).join("\n");
    const d = await gql(`{ blockchain { ${q} } }`);
    const now = Date.now() / 1000;
    chunk.forEach((l, k) => {
      const info = d.blockchain[`a${k}`]?.info;
      if (!info || info.acc_type !== 1) { l.status = "closed"; return; }
      const bal = (info.balance_other || []).find((x) => Number(x.currency) === l.giveId);
      l.held = bal ? BigInt(bal.value) : 0n;
      l.status = l.held >= l.giveAmount ? (now < l.deadline ? "open" : "expired") : "settled";
    });
  }
}

// ---------- numbers ----------
function fmt(v, dec, maxFrac = 4) {
  const base = 10n ** BigInt(dec);
  const int = (v / base).toLocaleString("en-US");
  const frac = (v % base).toString().padStart(dec, "0").slice(0, maxFrac).replace(/0+$/, "");
  return int + (frac ? "." + frac : "");
}
function parseUnits(str, dec) {
  const s = String(str).trim().replace(/,/g, "");
  if (!/^\d+(\.\d+)?$/.test(s)) throw new Error("Enter a number");
  const [i, f = ""] = s.split(".");
  if (f.length > dec) throw new Error(`At most ${dec} decimals`);
  return BigInt(i) * 10n ** BigInt(dec) + BigInt((f + "0".repeat(dec)).slice(0, dec));
}
const sym = (id) => CURRENCIES[id]?.sym || `#${id}`;
const dec = (id) => CURRENCIES[id]?.dec ?? 9;
const amt = (v, id) => `${fmt(v, dec(id))} ${sym(id)}`;
const pair = () => PAIRS[pairIdx];
const onPair = (p = pair()) => lots.filter((l) => (l.giveId === p.base && l.wantId === p.quote) || (l.giveId === p.quote && l.wantId === p.base));
function priceOf(l, p = pair()) {
  const b = 10n ** BigInt(dec(p.base));
  return l.giveId === p.base ? (l.wantAmount * b) / l.giveAmount : (l.giveAmount * b) / l.wantAmount;
}
const asksOf = (p = pair()) => onPair(p).filter((l) => l.status === "open" && l.giveId === p.base).sort((a, b) => (priceOf(a, p) < priceOf(b, p) ? -1 : 1));
const bidsOf = (p = pair()) => onPair(p).filter((l) => l.status === "open" && l.giveId === p.quote).sort((a, b) => (priceOf(a, p) > priceOf(b, p) ? -1 : 1));
function timeLeft(deadline) {
  const s = Math.floor(deadline - Date.now() / 1000);
  if (s <= 0) return "expired";
  if (s < 3600) return `${Math.ceil(s / 60)} min left`;
  if (s < 86400) return `${Math.floor(s / 3600)} h left`;
  return `${Math.floor(s / 86400)} d ${Math.floor((s % 86400) / 3600)} h left`;
}
function ago(ts) {
  const s = Math.floor(Date.now() / 1000 - ts);
  if (s < 60) return "just now"; if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  if (s < 86400) return `${Math.floor(s / 3600)} h ago`; return `${Math.floor(s / 86400)} d ago`;
}
const short = (hex) => `${hex.slice(0, 6)}…${hex.slice(-4)}`;
const coin = (id, cls = "") => `<span class="coin c${id} ${cls}">${esc(sym(id)[0])}</span>`;

// ---------- icons ----------
const ICON = {
  chev: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="m6 9 6 6 6-6"/></svg>`,
  right: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="m9 6 6 6-6 6"/></svg>`,
  check: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5 10 17 19 7"/></svg>`,
  shield: `<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" style="flex:none;margin-top:1px"><path d="M12 3 4 6v6c0 4.5 3.4 8.3 8 9 4.6-.7 8-4.5 8-9V6l-8-3Z"/><path d="M12 8v4M12 16h.01"/></svg>`,
};

// ---------- home ----------
function renderHome() {
  const p = pair();
  const asks = asksOf(p), bids = bidsOf(p);
  $("#pair-chip").innerHTML = `<span class="chip-coins">${coin(p.base)}${coin(p.quote)}</span>${sym(p.base)} / ${sym(p.quote)} ${ICON.chev}`;
  $("#buy-sub").textContent = sym(p.base);
  $("#sell-sub").textContent = sym(p.base);
  $("#hero-unit").textContent = `${sym(p.quote)} / ${sym(p.base)}`;
  if (!loaded) return;
  if (asks.length) {
    $("#hero-label").textContent = `Best price to buy ${sym(p.base)}`;
    $("#hero-price").textContent = fmt(priceOf(asks[0], p), dec(p.quote), 6);
  } else if (bids.length) {
    $("#hero-label").textContent = `Best price to sell ${sym(p.base)}`;
    $("#hero-price").textContent = fmt(priceOf(bids[0], p), dec(p.quote), 6);
  } else {
    $("#hero-label").textContent = "No open offers yet";
    $("#hero-price").textContent = "—";
  }
  const forSale = asks.reduce((a, l) => a + l.giveAmount, 0n);
  $("#hero-sub").innerHTML = asks.length || bids.length
    ? `<b>${fmt(forSale, dec(p.base), 0)} ${sym(p.base)}</b> for sale in ${asks.length} offer${asks.length === 1 ? "" : "s"} · ${bids.length} buyer${bids.length === 1 ? "" : "s"}`
    : `Be the first: tap <b>List</b> to set your price.`;

  // other markets peek out behind the card
  const others = PAIRS.map((q, i) => ({ q, i })).filter(({ i }) => i !== pairIdx).slice(0, 2);
  $("#stack").innerHTML = others.map(({ q, i }) => {
    const a = asksOf(q)[0];
    return `<button data-i="${i}" aria-label="Switch to ${sym(q.base)} / ${sym(q.quote)}"><span>${sym(q.base)} / ${sym(q.quote)}</span><b>${a ? fmt(priceOf(a, q), dec(q.quote), 6) : "no offers"}</b></button>`;
  }).join("");
  if (others.length === 1) $("#stack").insertAdjacentHTML("afterbegin", `<button tabindex="-1" aria-hidden="true" style="pointer-events:none"></button>`);
  $$("#stack button[data-i]").forEach((b) => b.addEventListener("click", () => setPair(Number(b.dataset.i))));
  renderRows();
}

function setPair(i) { pairIdx = i; renderHome(); }

function renderRows() {
  const p = pair();
  const el = $("#rows");
  let list;
  if (tab === "asks") list = asksOf(p);
  else if (tab === "bids") list = bidsOf(p);
  else list = [...onPair(p)].sort((a, b) => b.createdAt - a.createdAt).slice(0, 20);
  if (!list.length) {
    const msg = {
      asks: [`No ${sym(p.base)} for sale right now`, `List yours and set the price.`, "List an offer"],
      bids: [`No one is buying ${sym(p.base)} right now`, `Create a buy offer with ${sym(p.quote)}.`, "Create a buy offer"],
      recent: ["Nothing here yet", "Offers appear here as soon as they are on chain.", "List an offer"],
    }[tab];
    el.innerHTML = `<li class="empty-state"><b>${esc(msg[0])}</b>${esc(msg[1])}<br><button class="btn ghost" id="empty-cta">${esc(msg[2])}</button></li>`;
    $("#empty-cta").addEventListener("click", () => openSheet(viewList({ side: tab === "bids" ? "buy" : "sell" })));
    return;
  }
  el.innerHTML = list.map((l, k) => rowHtml(l, p, k === 0 && tab !== "recent")).join("");
  $$(".row", el).forEach((r) => r.addEventListener("click", () => openSheet(viewTake(r.dataset.lot))));
}

function rowHtml(l, p, best) {
  const sellsBase = l.giveId === p.base;
  const baseAmt = sellsBase ? l.giveAmount : l.wantAmount;
  const quoteAmt = sellsBase ? l.wantAmount : l.giveAmount;
  const statusTag = {
    open: sellsBase ? `<span class="tag buy">Buy</span>` : `<span class="tag sell">Sell</span>`,
    expired: `<span class="tag exp">Expired</span>`, settled: `<span class="tag done">Filled</span>`, closed: `<span class="tag done">Done</span>`,
  }[l.status] || "";
  const sub = l.status === "open"
    ? `${sellsBase ? "for" : "wants"} ${amt(quoteAmt, p.quote)} · ${timeLeft(l.deadline)}`
    : `${amt(quoteAmt, p.quote)} · ${ago(l.createdAt)}`;
  return `<li class="row" data-lot="${l.lot}" tabindex="0" role="button" aria-label="${sellsBase ? "Buy" : "Sell"} ${fmt(baseAmt, dec(p.base))} ${sym(p.base)}">
    <span class="coins">${coin(sellsBase ? p.base : p.quote)}${coin(sellsBase ? p.quote : p.base)}</span>
    <span class="row-main"><b>${fmt(baseAmt, dec(p.base))} ${sym(p.base)}${best ? `<span class="best">Best</span>` : ""}</b><span>${esc(sub)}</span></span>
    <span class="row-end"><b>${fmt(priceOf(l, p), dec(p.quote), 6)}</b><small>${sym(p.quote)} each</small><br>${statusTag}</span></li>`;
}

// ---------- sheet navigation ----------
const views = [];
let current = null;
function openSheet(view) {
  views.length = 0;
  show(view);
  if (!$("#sheet").open) $("#sheet").showModal();
}
function push(view) { if (current) views.push(current); show(view); }
function back() { const v = views.pop(); if (v) show(v); }
function show(view) {
  current = view;
  $("#sheet-title").textContent = view.title;
  $("#sheet-back").hidden = views.length === 0;
  $("#sheet-body").innerHTML = view.html();
  view.bind?.($("#sheet-body"));
}
function closeSheet() { $("#sheet").close(); current = null; views.length = 0; }
function refreshSheet() { if (current?.live && $("#sheet").open) current.live($("#sheet-body")); }

function toast(msg) {
  const t = $("#toast"); t.textContent = msg; t.classList.add("on");
  clearTimeout(toast.t); toast.t = setTimeout(() => t.classList.remove("on"), 1600);
}
function bindCopy(root) {
  $$("[data-copy]", root).forEach((b) => b.addEventListener("click", async (e) => {
    e.stopPropagation();
    try { await navigator.clipboard.writeText(b.dataset.copy); toast("Copied"); }
    catch { toast("Couldn't copy: select it and copy by hand"); }
  }));
  // Shortened ids expand on tap (Copy always copies the full value).
  $$("code.tap", root).forEach((c) => c.addEventListener("click", (e) => {
    e.stopPropagation();
    const full = c.dataset.open !== "1";
    c.textContent = full ? c.dataset.full : c.dataset.short;
    c.dataset.open = full ? "1" : "0";
  }));
}

/** Long id/payload shown as "start…end"; tap to see it all. */
const mid = (s, a = 10, b = 8) => (s.length > a + b + 3 ? `${s.slice(0, a)}…${s.slice(-b)}` : s);
const tapCode = (full, a, b) =>
  `<code class="tap" data-full="${esc(full)}" data-short="${esc(mid(full, a, b))}" title="Tap to show all">${esc(mid(full, a, b))}</code>`;

// ---------- views ----------
function viewPairs() {
  return {
    title: "Choose market",
    html: () => `<div class="choice">${PAIRS.map((p, i) => {
      const a = asksOf(p)[0];
      return `<button data-i="${i}"><b>${sym(p.base)} / ${sym(p.quote)}</b><span>${a ? `from ${fmt(priceOf(a, p), dec(p.quote), 6)} ${sym(p.quote)} per ${sym(p.base)}` : "no offers yet"} · ${asksOf(p).length + bidsOf(p).length} open</span>${ICON.right}</button>`;
    }).join("")}</div>`,
    bind: (r) => $$("button[data-i]", r).forEach((b) => b.addEventListener("click", () => { setPair(Number(b.dataset.i)); closeSheet(); })),
  };
}

function viewOffers(kind) {           // kind: "asks" (buy from sellers) | "bids" (sell to buyers)
  const p = pair();
  return {
    title: kind === "asks" ? `Buy ${sym(p.base)}` : `Sell ${sym(p.base)} now`,
    html: () => {
      const list = kind === "asks" ? asksOf(p) : bidsOf(p);
      if (!list.length) {
        return `<div class="empty-state"><b>${kind === "asks" ? `No ${sym(p.base)} for sale right now` : `No buyers right now`}</b>
          ${kind === "asks" ? "Create a buy offer and let sellers come to you." : "List your NACKL at your own price."}<br>
          <button class="btn light" id="to-list">${kind === "asks" ? "Create a buy offer" : "List at my price"}</button></div>`;
      }
      return `<p class="note" style="margin:0 0 10px">${kind === "asks" ? "Cheapest first. Each offer is a fixed amount at a fixed price." : "Best price first. You sell the whole amount shown."}</p>
        <ul class="rows">${list.map((l, k) => rowHtml(l, p, k === 0)).join("")}</ul>`;
    },
    bind: (r) => {
      $$(".row", r).forEach((row) => row.addEventListener("click", () => push(viewTake(row.dataset.lot))));
      $("#to-list", r)?.addEventListener("click", () => push(viewList({ side: kind === "asks" ? "buy" : "sell" })));
    },
  };
}

function viewSellChoice() {
  const p = pair();
  const best = bidsOf(p)[0];
  return {
    title: `Sell ${sym(p.base)}`,
    html: () => `<div class="choice">
      <button id="c-now"><b>Sell now to a buyer</b><span>${best ? `Best offer: ${fmt(priceOf(best, p), dec(p.quote), 6)} ${sym(p.quote)} per ${sym(p.base)}` : "No buyers at the moment"}</span>${ICON.right}</button>
      <button id="c-list"><b>List at my own price</b><span>Your ${sym(p.base)} waits in its own contract until someone buys. Cancel any time.</span>${ICON.right}</button></div>`,
    bind: (r) => {
      $("#c-now", r).addEventListener("click", () => push(viewOffers("bids")));
      $("#c-list", r).addEventListener("click", () => push(viewList({ side: "sell" })));
    },
  };
}

function viewTake(lotHex) {
  let watchedOpen = false;
  const find = () => lots.find((x) => x.lot === lotHex);
  const view = {
    title: "",
    html: () => {
      const l = find();
      if (!l) return `<p class="err">This offer is no longer listed.</p>`;
      const p = pair();
      const addr = `0:${l.lot}`;
      view.title = l.giveId === p.base ? `Buy ${amt(l.giveAmount, l.giveId)}` : `Sell ${amt(l.wantAmount, l.wantId)}`;
      return `
        <div class="sum">
          <div class="sum-row"><span>${coin(l.wantId)}You pay</span><b>${amt(l.wantAmount, l.wantId)}</b></div>
          <div class="sum-row"><span>${coin(l.giveId)}You get</span><b>${amt(l.giveAmount, l.giveId)}</b></div>
          <div class="sum-row"><span>Price</span><b style="font-size:14px">${fmt(priceOf(l, p), dec(p.quote), 6)} ${sym(p.quote)} per ${sym(p.base)}</b></div>
        </div>
        <div id="take-live"></div>
        <details class="more"><summary>Offer details</summary><dl>
          <dt>Offer</dt><dd><code>${F}::${l.lot}</code></dd>
          <dt>Seller</dt><dd><code>${esc(l.maker)}</code></dd>
          <dt>Expires</dt><dd>${new Date(l.deadline * 1000).toLocaleString()}</dd>
          <dt>Fee</dt><dd>${Number(FEE_BPS) / 100}%, taken from what the offer's creator receives. You pay exactly the price.</dd>
          <dt>Verified</dt><dd>Read from the factory's own on-chain events (<code>${short(F)}</code>).</dd>
        </dl></details>`;
    },
    bind: (r) => { view.live(r); },
    live: (r) => {
      const l = find(); const box = $("#take-live", r);
      if (!l || !box) return;
      const addr = `0:${l.lot}`;
      if (l.status === "open") {
        watchedOpen = true;
        if (box.dataset.state === "open") { $(".live span", box).textContent = `Waiting for your payment · ${timeLeft(l.deadline)}`; return; }
        box.dataset.state = "open";
        box.innerHTML = `
          ${TEST ? `<div class="danger">${ICON.shield}<span><b>Test offer: test coins only.</b> Don't pay it from the Acki Nacki Wallet app or any real wallet. That would send <b>real</b> ${sym(l.wantId)} to an address that doesn't exist on mainnet, and it could be lost.</span></div>` : ""}
          <div class="pay"${TEST ? ' style="margin-top:12px"' : ""}>
            <div class="k">Send exactly</div>
            <div class="amount">${fmt(l.wantAmount, dec(l.wantId), 9)} <small>${TEST ? "test " : ""}${sym(l.wantId)}</small></div>
            <div class="k" style="margin-bottom:6px">to this offer</div>
            <div class="addr">${tapCode(addr, 12, 8)}<button class="btn dark" data-copy="${addr}">Copy</button></div>
            <div class="pay-tools"><button class="btn light" style="border:1px solid #dfe5ef" data-copy="${fmt(l.wantAmount, dec(l.wantId), 9).replace(/,/g, "")}">Copy amount</button>${TEST ? "" : `<button class="btn light" style="border:1px solid #dfe5ef" id="qr-toggle">Show QR</button>`}</div>
            <div id="qr"></div>
          </div>
          <ol class="steps">
            ${TEST
              ? `<li><span>From a <b>Shellnet test wallet</b> (developers: tvm-cli), send <b>${fmt(l.wantAmount, dec(l.wantId))} test ${sym(l.wantId)}</b> to the address above, as a plain transfer.</span></li>
                 <li><span>The test wallet receives <b>${fmt(l.giveAmount, dec(l.giveId))} test ${sym(l.giveId)}</b> within seconds.</span></li>`
              : `<li><span>Open your <b>Acki Nacki Wallet</b> and send <b>${amt(l.wantAmount, l.wantId)}</b> to the address above, as a normal transfer.</span></li>
                 <li><span>Your <b>${amt(l.giveAmount, l.giveId)}</b> arrives in the same wallet within seconds.</span></li>`}
          </ol>
          ${l.wantId === 2 ? `<div class="safe">${ICON.shield}<span>Send SHELL <b>as SHELL</b>. Don't convert it to gas first: converted SHELL can't be refunded.</span></div>` : ""}
          <div class="live"><i></i><span>Waiting for your payment · ${timeLeft(l.deadline)}</span></div>`;
        bindCopy(box);
        $("#qr-toggle", box)?.addEventListener("click", (e) => {
          const q = $("#qr", box);
          if (!q.dataset.made && window.QRCode) { try { new window.QRCode(q, { text: addr, width: 168, height: 168, colorDark: "#0b1224", colorLight: "#ffffff" }); q.dataset.made = 1; } catch { /* optional */ } }
          q.classList.toggle("on"); e.target.textContent = q.classList.contains("on") ? "Hide QR" : "Show QR";
        });
        return;
      }
      if (box.dataset.state === l.status) return;
      box.dataset.state = l.status;
      if ((l.status === "settled" || l.status === "closed") && watchedOpen) {
        box.innerHTML = `<div class="done-card"><div class="check">${ICON.check}</div><h4>Offer filled</h4>
          <p>If that was your payment, <b>${amt(l.giveAmount, l.giveId)}</b> is already in your wallet.<br>If someone was faster, your payment was returned.</p></div>
          <button class="btn light block" style="margin-top:16px" id="done-ok">Done</button>`;
        $("#done-ok", box).addEventListener("click", closeSheet);
        return;
      }
      const msg = {
        expired: "This offer has expired. Don't pay: its coins go back to the seller.",
        settled: "This offer has already been filled. Don't pay.",
        closed: "This offer is finished. Don't pay.",
      }[l.status] || "Checking the offer…";
      box.innerHTML = `<div class="live warn"><i></i><span>${esc(msg)}</span></div>`;
    },
  };
  view.html();                                            // sets the title
  return view;
}

function viewList(pre = {}) {
  const s = {
    side: pre.side || "sell", quote: pair().quote, amount: "", price: "", hours: 24,
    wallet: store.get("wallet"),
  };
  const view = {
    title: "Create an offer",
    html: () => `
      <div class="toggle" role="group" aria-label="Side">
        <button data-side="sell" aria-pressed="${s.side === "sell"}">Sell NACKL</button>
        <button data-side="buy" aria-pressed="${s.side === "buy"}">Buy NACKL</button>
      </div>
      <div class="field"><span>Paid in</span><div class="chips" id="q-chips">${PAIRS.map((p) => `<button data-q="${p.quote}" aria-pressed="${s.quote === p.quote}">${sym(p.quote)}</button>`).join("")}</div></div>
      <label class="field"><span>Amount of NACKL</span><div class="input"><input id="f-amount" inputmode="decimal" placeholder="1,000" value="${esc(s.amount)}" autocomplete="off"><em>NACKL</em></div></label>
      <label class="field"><span>Price per NACKL <button type="button" id="f-best"></button></span><div class="input"><input id="f-price" inputmode="decimal" placeholder="0.005" value="${esc(s.price)}" autocomplete="off"><em id="f-qsym">${sym(s.quote)}</em></div></label>
      <div class="field"><span>Offer stays open for</span><div class="chips" id="h-chips">${[[1, "1 hour"], [24, "1 day"], [72, "3 days"], [167, "7 days"]].map(([h, t]) => `<button data-h="${h}" aria-pressed="${s.hours === h}">${t}</button>`).join("")}</div></div>
      <label class="field"><span>Your wallet address</span><div class="input"><input class="small" id="f-wallet" placeholder="dapp_id::account_id" value="${esc(s.wallet)}" autocomplete="off" spellcheck="false"></div></label>
      <div class="quote" id="f-quote"></div>
      <p class="err" id="f-err"></p>
      <button class="btn light block" id="f-go">Continue</button>
      <p class="note">You'll get a ready-made message to send from your wallet. Your coins go straight into the new offer's own contract, never to us.</p>`,
    bind: (r) => {
      const recalc = () => {
        s.amount = $("#f-amount", r).value; s.price = $("#f-price", r).value; s.wallet = $("#f-wallet", r).value;
        const p = PAIRS.find((x) => x.quote === s.quote);
        const best = s.side === "sell" ? asksOf(p)[0] : bidsOf(p)[0];
        const bestBtn = $("#f-best", r);
        bestBtn.textContent = best ? `Market: ${fmt(priceOf(best, p), dec(p.quote), 6)}` : "";
        bestBtn.onclick = () => { $("#f-price", r).value = fmt(priceOf(best, p), dec(p.quote), 9).replace(/,/g, ""); recalc(); };
        $("#f-qsym", r).textContent = sym(s.quote);
        const q = computeOffer(s);
        $("#f-quote", r).innerHTML = q.ok ? `
          <div class="sum-row"><span>${coin(q.giveId)}You put in</span><b>${amt(q.giveAmount, q.giveId)}</b></div>
          <div class="sum-row"><span>${coin(q.wantId)}You receive</span><b>${amt(q.wantAmount - q.fee, q.wantId)}</b></div>
          <div class="sum-row"><span>Fee (${Number(FEE_BPS) / 100}%)</span><b style="font-size:14px">${amt(q.fee, q.wantId)}</b></div>`
          : `<div class="sum-row"><span>Enter an amount and a price to see what you'll receive.</span></div>`;
        $("#f-err", r).textContent = q.ok ? "" : (s.amount && s.price ? q.error : "");
        $("#f-go", r).disabled = !q.ok;
      };
      $$("[data-side]", r).forEach((b) => b.addEventListener("click", () => { s.side = b.dataset.side; $$("[data-side]", r).forEach((x) => x.setAttribute("aria-pressed", x === b)); recalc(); }));
      $$("[data-q]", r).forEach((b) => b.addEventListener("click", () => { s.quote = Number(b.dataset.q); $$("[data-q]", r).forEach((x) => x.setAttribute("aria-pressed", x === b)); recalc(); }));
      $$("[data-h]", r).forEach((b) => b.addEventListener("click", () => { s.hours = Number(b.dataset.h); $$("[data-h]", r).forEach((x) => x.setAttribute("aria-pressed", x === b)); recalc(); }));
      ["#f-amount", "#f-price", "#f-wallet"].forEach((id) => $(id, r).addEventListener("input", recalc));
      $("#f-go", r).addEventListener("click", () => {
        const q = computeOffer(s);
        if (!q.ok) { $("#f-err", r).textContent = q.error; return; }
        store.set("wallet", s.wallet.trim());
        push(viewListResult(q));
      });
      recalc();
    },
  };
  return view;
}

function computeOffer(s) {
  try {
    const p = PAIRS.find((x) => x.quote === s.quote);
    const baseAmt = parseUnits(s.amount, dec(p.base));
    const price = parseUnits(s.price, dec(p.quote));
    if (baseAmt === 0n) throw new Error("Enter an amount");
    const quoteAmt = (baseAmt * price) / 10n ** BigInt(dec(p.base));
    const [giveId, giveAmount, wantId, wantAmount] = s.side === "sell"
      ? [p.base, baseAmt, p.quote, quoteAmt] : [p.quote, quoteAmt, p.base, baseAmt];
    if (giveAmount < CURRENCIES[giveId].minGive) throw new Error(`The smallest offer is ${amt(CURRENCIES[giveId].minGive, giveId)} (you'd put in ${amt(giveAmount, giveId)}).`);
    if (wantAmount <= 0n) throw new Error("That price is too small");
    if (!(s.hours >= 1 && s.hours * 3600 <= MAX_TTL_SECONDS)) throw new Error("Pick how long the offer stays open");
    const w = parseWallet(s.wallet);
    return { ok: true, giveId, giveAmount, wantId, wantAmount, fee: (wantAmount * FEE_BPS) / 10000n, hours: s.hours, wallet: w };
  } catch (e) { return { ok: false, error: e.message }; }
}

function parseWallet(str) {
  const t = String(str || "").trim().toLowerCase();
  const m = t.match(/^([0-9a-f]{64})::([0-9a-f]{64})$/);
  if (m) return { dapp: m[1], account: m[2] };
  if (!t) throw new Error("Add your wallet address");
  throw new Error("Wallet address should look like dapp_id::account_id (two 64-character codes)");
}

function viewListResult(q) {
  // Deadline slightly inside the chosen window so the message still lands within the 7-day limit.
  const deadline = BigInt(Math.floor(Date.now() / 1000) + q.hours * 3600 - 120);
  const payload = encodeCallBody(IDS.createLot, ABI.createLot.inputs,
    { giveId: q.giveId, wantId: q.wantId, wantAmount: q.wantAmount, deadline, makerDapp: BigInt("0x" + q.wallet.dapp) });
  const args = JSON.stringify({ dest: `0:${F}`, value: "10000000", cc: { [q.giveId]: q.giveAmount.toString() }, bounce: true, flag: 1, payload, dapp_id: `0x${F}` });
  const cmd = `tvm-cli call ${q.wallet.dapp}::${q.wallet.account} submitTransaction '${args}' --abi UpdateCustodianMultisigWallet_v2.abi.json --sign <your-key-file>`;
  return {
    title: "Send to create your offer",
    html: () => `
      <div class="sum">
        <div class="sum-row"><span>${coin(q.giveId)}You put in</span><b>${amt(q.giveAmount, q.giveId)}</b></div>
        <div class="sum-row"><span>${coin(q.wantId)}You receive</span><b>${amt(q.wantAmount - q.fee, q.wantId)}</b></div>
        <div class="sum-row"><span>Open until</span><b style="font-size:14px">${new Date(Number(deadline) * 1000).toLocaleString()}</b></div>
      </div>
      ${TEST ? `<div class="danger">${ICON.shield}<span><b>Test network.</b> Send this only from a Shellnet <b>test</b> wallet. From a real wallet, real coins would go to an address that doesn't exist on mainnet.</span></div>` : ""}
      <ol class="steps">
        <li><span>From a ${TEST ? "Shellnet test wallet" : "wallet"} that can attach a message, send <b>${TEST ? `${fmt(q.giveAmount, dec(q.giveId))} test ${sym(q.giveId)}` : amt(q.giveAmount, q.giveId)}</b> to the NACKL-Swap factory, bounce on:</span></li>
      </ol>
      <div class="codebox">${tapCode(`0:${F}`, 12, 8)}<button class="btn ghost" data-copy="0:${F}">Copy</button></div>
      <ol class="steps" start="2" style="counter-reset:s 1">
        <li><span>Attach this message (it holds your price and expiry):</span></li>
      </ol>
      <div class="codebox">${tapCode(payload, 14, 8)}<button class="btn ghost" data-copy="${payload}">Copy</button></div>
      <ol class="steps" style="counter-reset:s 2">
        <li><span>Your offer appears in the market within seconds. When someone buys, <b>${amt(q.wantAmount - q.fee, q.wantId)}</b> arrives in your wallet automatically.</span></li>
      </ol>
      <details class="more"><summary>Using tvm-cli with a multisig wallet</summary>
        <div class="codebox"><code class="cmd">${esc(cmd)}</code><button class="btn ghost" data-copy="${esc(cmd)}">Copy</button></div>
        <p style="margin:0 0 12px">Destination DApp: <code>${F}</code></p></details>
      <div class="safe">${ICON.shield}<span>NACKL-Swap never asks for your keys or seed phrase. Anyone who does is trying to steal from you.</span></div>`,
    bind: (r) => bindCopy(r),
  };
}

function viewMine() {
  const view = {
    title: "My offers",
    html: () => `
      <label class="field"><span>Your wallet address</span><div class="input"><input class="small" id="m-wallet" placeholder="dapp_id::account_id" value="${esc(store.get("wallet"))}" autocomplete="off" spellcheck="false"></div></label>
      <div id="m-out"></div>`,
    bind: (r) => {
      const run = () => {
        const out = $("#m-out", r);
        const v = $("#m-wallet", r).value.trim().toLowerCase();
        const m = v.match(/^(?:[0-9a-f]{64}::|0:)?([0-9a-f]{64})$/);
        if (!m) { out.innerHTML = v ? `<p class="err">Paste your wallet address (dapp_id::account_id).</p>` : `<p class="note">Your offers from the last ${EVENTS_TO_SCAN} on chain will show here.</p>`; return; }
        store.set("wallet", v);
        const mine = lots.filter((l) => l.maker === `0:${m[1]}`).sort((a, b) => b.createdAt - a.createdAt);
        if (!mine.length) { out.innerHTML = `<div class="empty-state"><b>No offers from this wallet</b>Offers you create will appear here.</div>`; return; }
        const cancel = encodeCallBody(IDS.reclaim, [], {});
        out.innerHTML = `<ul class="rows">${mine.map((l) => {
          const p = PAIRS.find((x) => [x.base, x.quote].includes(l.giveId) && [x.base, x.quote].includes(l.wantId)) || pair();
          return rowHtml(l, p, false) + (l.status === "open" || l.status === "expired" ? `
            <li style="list-style:none;padding:0 12px 12px"><details class="more" style="margin:0"><summary>Cancel and get my ${sym(l.giveId)} back</summary>
              <p style="margin:0 0 8px">Send the offer ${tapCode(`0:${l.lot}`, 12, 8)} (DApp <code>${short(F)}</code>) a message with <b>no coins</b>, bounce on, carrying:</p>
              <div class="codebox"><code>${cancel}</code><button class="btn ghost" data-copy="${cancel}">Copy</button></div>
              ${l.status === "expired" ? `<p style="margin:0 0 12px">It has expired, so anyone can also return it to you.</p>` : ""}</details></li>` : "");
        }).join("")}</ul>`;
        bindCopy(out);
        $$(".row", out).forEach((row) => row.addEventListener("click", () => push(viewTake(row.dataset.lot))));
      };
      $("#m-wallet", r).addEventListener("input", run);
      run();
    },
    live: (r) => { /* list refreshes when reopened */ },
  };
  return view;
}

// ---------- refresh loop ----------
async function refresh() {
  $("#btn-refresh").classList.add("spin");
  try {
    const fresh = await fetchLots();
    await fetchStatuses(fresh);
    lots = fresh; loaded = true;
    $("#net").className = "net glass ok"; $("#net span").textContent = "Shellnet · live";
    renderHome();
    refreshSheet();
  } catch (e) {
    $("#net").className = "net glass bad"; $("#net span").textContent = "Offline";
    $("#net").title = e.message;
    if (!loaded) $("#rows").innerHTML = `<li class="empty-state"><b>Can't reach the chain</b>${esc(e.message)}. Retrying…</li>`;
  } finally {
    $("#btn-refresh").classList.remove("spin");
  }
}

async function main() {
  IDS = {
    LotCreated: await abiId(eventSignature(ABI.LotCreated)),
    createLot: await abiId(functionSignature(ABI.createLot)),
    reclaim: await abiId(functionSignature(ABI.reclaim)),
  };
  $("#factory").textContent = `${F}::${F}`;
  $("#testbar").hidden = !TEST;
  $("#pair-chip").addEventListener("click", () => openSheet(viewPairs()));
  $("#btn-buy").addEventListener("click", () => openSheet(viewOffers("asks")));
  $("#btn-sell").addEventListener("click", () => openSheet(viewSellChoice()));
  $("#btn-list").addEventListener("click", () => openSheet(viewList({ side: "sell" })));
  $("#btn-mine").addEventListener("click", () => openSheet(viewMine()));
  $("#btn-refresh").addEventListener("click", refresh);
  $("#sheet-close").addEventListener("click", closeSheet);
  $("#sheet-back").addEventListener("click", back);
  $("#sheet").addEventListener("click", (e) => { if (e.target.id === "sheet") closeSheet(); });
  $("#sheet").addEventListener("close", () => { current = null; views.length = 0; });
  $$("#tabs button").forEach((b) => b.addEventListener("click", () => {
    tab = b.dataset.tab; $$("#tabs button").forEach((x) => x.setAttribute("aria-selected", x === b)); renderRows();
  }));
  $("#rows").addEventListener("keydown", (e) => { if ((e.key === "Enter" || e.key === " ") && e.target.classList.contains("row")) { e.preventDefault(); e.target.click(); } });
  renderHome();
  await refresh();
  setInterval(refresh, POLL_MS);
}

main();
