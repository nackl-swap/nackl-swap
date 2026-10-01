# Security policy

NACKL-Swap holds user funds in smart contracts, so security reports are the most valuable contribution you can make.

## Status

- **Shellnet (test network) only.** The contracts pass 89 on-chain checks with exact coin conservation
  (`tests/RESULTS.md`), but have **not** yet had an independent audit. Mainnet launches only after one.
- Self-review findings and fixes: [`docs/SECURITY_REVIEW.md`](docs/SECURITY_REVIEW.md) (F1–F13).
- Design invariants: [`docs/CONTRACT_PLAN.md`](docs/CONTRACT_PLAN.md) (I1–I6).

## Reporting a vulnerability

Please **do not open a public issue** for a vulnerability. Use GitHub's private reporting instead:
**Security → Report a vulnerability** on this repository. Include the contract, the function, and the
steps or transaction sequence that shows the problem. You'll get an acknowledgement, and fixes are
credited unless you'd rather stay anonymous.

Most wanted: any way for coins to leave a lot other than to its maker, its taker, or the capped fee; any
way to strand coins (including action-phase failures); and any way to block lots or drain sponsored gas.

## What this repository never contains

- No private keys or seed phrases, test keys included (`.gitignore`, `tools/hooks/pre-commit`, CI gitleaks scan).
- No API keys: the web app reads the public Acki Nacki GraphQL endpoint directly and has no backend.
- The web app never asks users for keys or seed phrases. Anyone who does is not us.
