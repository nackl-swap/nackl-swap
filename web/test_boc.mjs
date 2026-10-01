// Node test for boc.js against real Shellnet LotCreated events (run 7, lots #40 and #41).
//   node web/test_boc.mjs
import { createHash } from "node:crypto";
import { parseBoc, Slice, decodeEvent } from "./boc.js";
import { ABI } from "./config.js";

// ABI fragment from config.js (same as contracts/SwapFactory.abi.json, which is build output and not committed).
const ev = ABI.LotCreated;
const sig = `${ev.name}(${ev.inputs.map((i) => i.type).join(",")})v2`;
const id = createHash("sha256").update(sig).digest().readUInt32BE(0) & 0x7fffffff;

const bodies = [
  "te6ccgEBAwEAqAABWygsbM8AAAAAAAAAKIACa8/VzV5KbgIqJ9eQRpzi4izbzfBGGSL8mbhxIkJE8/ABAauAGTWj1uggTL3YVdqGmN+1vP6KA/kVQa6SSC9DGC5sXG85NaPW6CBMvdhV2oaY37W8/ooD+RVBrpJIL0MYLmxcbyAAAAAgAAAAAAAAAAAAAB0alKIAEAIAOAAAAAIAAAAAAAAAAAAAAAEqBfIAAAAAAGq89s0=",
  "te6ccgEBAwEAqAABWygsbM8AAAAAAAAAKYAeHX51Hb6qKHw1fjFYg/wOV6221SgcGovJphKAg8dh5RABAauAGTWj1uggTL3YVdqGmN+1vP6KA/kVQa6SSC9DGC5sXG85NaPW6CBMvdhV2oaY37W8/ooD+RVBrpJIL0MYLmxcbyAAAAAgAAAAAAAAAAAAAB0alKIAEAIAOAAAAAIAAAAAAAAAAAAAAAEqBfIAAAAAAGq9BUU=",
];

let fail = 0;
const eq = (name, want, got) => {
  const ok = String(want) === String(got);
  if (!ok) fail++;
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}  ${ok ? got : `want=${want} got=${got}`}`);
};

const first = new Slice(parseBoc(bodies[0]));
const raw = Number(first.uint(32));
console.log(`signature ${sig}\n  computed id 0x${id.toString(16)}  body id 0x${raw.toString(16)}`);
eq("event id matches", id, raw);

const MAKER = "0:c9ad1eb7410265eec2aed434c6fdade7f4501fc8aa0d7492417a18c17362e379";
const N = 1000000000n;
bodies.forEach((b, k) => {
  const e = decodeEvent(b, ev, id);
  if (!e) { fail++; console.log("FAIL  decode returned null"); return; }
  console.log(JSON.stringify(e, (_, v) => (typeof v === "bigint" ? v.toString() : v)));
  eq(`#${40 + k} nonce`, 40 + k, e.nonce);
  eq(`#${40 + k} maker`, MAKER, e.maker);
  eq(`#${40 + k} makerDapp`, MAKER.slice(2), e.makerDapp.toString(16).padStart(64, "0"));
  eq(`#${40 + k} give NACKL`, "1:" + 1000n * N, `${e.giveId}:${e.giveAmount}`);
  eq(`#${40 + k} want SHELL`, "2:" + 5n * N, `${e.wantId}:${e.wantAmount}`);
  eq(`#${40 + k} lot address is 0:hex64`, true, /^0:[0-9a-f]{64}$/.test(e.lot));
  eq(`#${40 + k} deadline is plausible`, true, e.deadline > 1790000000n && e.deadline < 1800000000n);
});
// Encoder vs `tvm-cli body` (reference bodies produced locally by tvm-cli 3.0.6, 2026-09-30).
import { encodeCallBody, functionSignature } from "./boc.js";
const fid = (fn) => createHash("sha256").update(functionSignature(fn)).digest().readUInt32BE(0) & 0x7fffffff;
eq("createLot body #1 == tvm-cli",
  "te6ccgEBAQEARgAAiGH0YGgAAAABAAAAAgAAAAAAAAAAAAAAASoF8gAAAAAAar0FRcmtHrdBAmXuwq7UNMb9ref0UB/Iqg10kkF6GMFzYuN5",
  encodeCallBody(fid(ABI.createLot), ABI.createLot.inputs, { giveId: 1, wantId: 2, wantAmount: 5000000000n,
    deadline: 1790772549n, makerDapp: BigInt("0x" + MAKER.slice(2)) }));
eq("createLot body #2 == tvm-cli",
  "te6ccgEBAQEARgAAiGH0YGgAAAACAAAAAQAAAAAAAAAAAABwSIYN33kAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB",
  encodeCallBody(fid(ABI.createLot), ABI.createLot.inputs, { giveId: 2, wantId: 1, wantAmount: 123456789012345n,
    deadline: 1n, makerDapp: 1n }));
eq("reclaim body == tvm-cli", "te6ccgEBAQEABgAACH8a7W8=", encodeCallBody(fid(ABI.reclaim), [], {}));

console.log(fail ? `\n${fail} FAILED` : "\nall passed");
process.exit(fail ? 1 : 0);
