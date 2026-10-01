// Minimal TVM bag-of-cells reader + ABI 2.4 decoders for the events and data this app needs.
// No dependencies; runs in the browser and in Node (tests: web/test_boc.mjs).

export class Cell {
  constructor(bits, bitLen, refs) { this.bits = bits; this.bitLen = bitLen; this.refs = refs; }
}

function b64ToBytes(b64) {
  if (typeof atob === "function") {
    const s = atob(b64); const out = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
    return out;
  }
  return new Uint8Array(Buffer.from(b64, "base64"));
}

/** Parse a base64 BOC; returns the root cell. */
export function parseBoc(b64) {
  const d = b64ToBytes(b64);
  let p = 0;
  const u = (n) => { let v = 0; for (let i = 0; i < n; i++) v = v * 256 + d[p++]; return v; };
  const magic = u(4);
  if (magic !== 0xb5ee9c72) throw new Error("not a BOC");
  const flags = d[p++];
  const hasIdx = (flags & 0x80) !== 0;
  const size = flags & 0x07;
  const offBytes = d[p++];
  const cellsN = u(size), rootsN = u(size); u(size); /* absent */ u(offBytes); /* total size */
  const roots = []; for (let i = 0; i < rootsN; i++) roots.push(u(size));
  if (hasIdx) p += cellsN * offBytes;
  const raw = [];
  for (let i = 0; i < cellsN; i++) {
    const d1 = d[p++], d2 = d[p++];
    const refsN = d1 & 7;
    const dataLen = Math.ceil(d2 / 2);
    const data = d.slice(p, p + dataLen); p += dataLen;
    let bitLen = dataLen * 8;
    if (d2 & 1) {                       // completion tag: strip trailing 1 and zeros
      const last = data[dataLen - 1];
      let t = 0; while (t < 8 && ((last >> t) & 1) === 0) t++;
      bitLen -= t + 1;
    }
    const refs = []; for (let r = 0; r < refsN; r++) refs.push(u(size));
    raw.push({ data, bitLen, refs });
  }
  const cells = new Array(cellsN);
  for (let i = cellsN - 1; i >= 0; i--) {
    cells[i] = new Cell(raw[i].data, raw[i].bitLen, raw[i].refs.map((r) => cells[r]));
  }
  return cells[roots[0]];
}

export class Slice {
  constructor(cell) { this.cell = cell; this.pos = 0; this.ref = 0; }
  bitsLeft() { return this.cell.bitLen - this.pos; }
  bit() {
    if (this.pos >= this.cell.bitLen) throw new Error("slice underflow");
    const b = (this.cell.bits[this.pos >> 3] >> (7 - (this.pos & 7))) & 1; this.pos++; return b;
  }
  uint(n) { let v = 0n; for (let i = 0; i < n; i++) v = (v << 1n) | BigInt(this.bit()); return v; }
  int(n) { const v = this.uint(n); return v >= (1n << BigInt(n - 1)) ? v - (1n << BigInt(n)) : v; }
  loadRef() { return new Slice(this.cell.refs[this.ref++]); }
  /** MsgAddressInt addr_std -> "wc:hex64"; addr_none -> "" */
  address() {
    const tag = Number(this.uint(2));
    if (tag === 0) return "";
    if (tag !== 2) throw new Error("unsupported address tag " + tag);
    if (this.bit()) throw new Error("anycast not supported");
    const wc = this.int(8);
    return wc + ":" + this.uint(256).toString(16).padStart(64, "0");
  }
}

const BITS = { uint16: 16, uint32: 32, uint64: 64, uint128: 128, uint256: 256, address: 267 };

/**
 * ABI 2.4 decode of a flat parameter list (uint*, address): values are packed in order and a value
 * that does not fit in the current cell continues in the next cell, referenced from the current one.
 * `skip` = bits already consumed (function/event id).
 */
export function decodeParams(slice, params) {
  let s = slice;
  const out = {};
  for (const { name, type } of params) {
    const need = BITS[type];
    if (need === undefined) throw new Error("unsupported type " + type);
    if (s.bitsLeft() < need) s = s.loadRef();
    out[name] = type === "address" ? s.address() : s.uint(need);
  }
  return out;
}

/** Decode an event body (base64 BOC) against an ABI event; returns null if the id does not match. */
export function decodeEvent(b64, eventAbi, eventId) {
  const s = new Slice(parseBoc(b64));
  const id = Number(s.uint(32));
  if (id !== eventId) return null;
  return decodeParams(s, eventAbi.inputs);
}

// ---- encoding (internal-message bodies for wallet calls) ----

function concatBits(chunks) {           // chunks: [value BigInt, bitCount]
  const total = chunks.reduce((a, [, n]) => a + n, 0);
  if (total > 1023) throw new Error("body does not fit in one cell");
  const bytes = new Uint8Array(Math.ceil(total / 8));
  let pos = 0;
  for (const [v, n] of chunks) {
    for (let i = n - 1; i >= 0; i--) {
      if ((v >> BigInt(i)) & 1n) bytes[pos >> 3] |= 0x80 >> (pos & 7);
      pos++;
    }
  }
  return { bytes, bits: total };
}

/** Serialize ONE cell without refs as a base64 BOC (same layout tvm-cli prints). */
export function serializeSingleCell({ bytes, bits }) {
  const data = Uint8Array.from(bytes);
  if (bits % 8 !== 0) data[data.length - 1] |= 0x80 >> (bits % 8);   // completion tag
  const d2 = Math.floor(bits / 8) + Math.ceil(bits / 8);
  const cellLen = 2 + data.length;
  const offBytes = cellLen < 256 ? 1 : 2;
  const head = [0xb5, 0xee, 0x9c, 0x72, 0x01, offBytes, 1, 1, 0];
  const tot = offBytes === 1 ? [cellLen] : [cellLen >> 8, cellLen & 255];
  const out = Uint8Array.from([...head, ...tot, 0, 0x00, d2, ...data]);
  let s = ""; for (const b of out) s += String.fromCharCode(b);
  return typeof btoa === "function" ? btoa(s) : Buffer.from(out).toString("base64");
}

/** ABI 2.4 internal call body: function id + params (uint* only), single cell. */
export function encodeCallBody(funcId, params, values) {
  const chunks = [[BigInt(funcId), 32]];
  for (const { name, type } of params) {
    const n = BITS[type];
    if (n === undefined || type === "address") throw new Error("unsupported type " + type);
    const v = BigInt(values[name]);
    if (v < 0n || v >= 1n << BigInt(n)) throw new Error(`${name} out of range for ${type}`);
    chunks.push([v, n]);
  }
  return serializeSingleCell(concatBits(chunks));
}

/** ABI 2.x function id: first 32 bits of sha256("name(inputs)(outputs)v2"), high bit cleared for calls. */
export function functionSignature(fn) {
  return `${fn.name}(${fn.inputs.map((i) => i.type).join(",")})(${(fn.outputs || []).map((o) => o.type).join(",")})v2`;
}
export function eventSignature(ev) {
  return `${ev.name}(${ev.inputs.map((i) => i.type).join(",")})v2`;
}
