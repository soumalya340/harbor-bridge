# Smart Contract Engineer Take-Home Assignment — Inherit and Harden a Bridge

## Overview

You have inherited **Harbor Bridge**, which moves the HBR token between **Chain A** and **Chain B**. The Chain A contract was built quickly by a previous developer. It appears to work at first glance, but it was rushed and is not safe to run in production. The Chain B bridge was never built. On Chain B, users stake wHBR and earn wHBR in a staking contract run by another team.

Your job is to **audit, fix, harden, and complete the bridge, and let users bridge and stake in one step**.

- **Stack**: Solidity 0.8.28 + Foundry. OpenZeppelin Contracts v5 is installed. You may add other libraries.
- **AI tools**: Allowed. Use them as you would in real work.
- **Timebox**: 3 days. Submit what you complete within that time.

---

## The System

| Where | What | Status |
|---|---|---|
| Chain A | `HarborToken` (HBR) — `src/token/HarborToken.sol` | Final — you cannot change it. Deployed and operated by the Harbor token team, not by the bridge team. |
| Chain A | `NativeBridgeV0` — `src/NativeBridgeV0.sol` | Written by the previous developer. Locks HBR and is supposed to unlock it again. |
| Chain B | `WrappedHarbor` (wHBR) — `src/token/WrappedHarbor.sol` | Final — you cannot change it. Only the bridge can mint and burn. |
| Chain B | Bridge | Does not exist yet. |
| Chain B | `HarborStaking` — `src/staking/HarborStaking.sol` | Final — you cannot change it. Deployed and operated by the Harbor staking team. Users stake wHBR and earn wHBR rewards. The staking team will approve your `StakeOnArrival` as an operator. |
| Off-chain | M-of-N validators | Watch `MessageSent` events and sign messages for the other chain. |
| Off-chain | Relayers | Permissionless: anyone may submit a message with at least `threshold` validator signatures. |

Flow: users lock HBR on Chain A and receive wHBR on Chain B; they burn wHBR on Chain B to unlock HBR on Chain A.

---

## Tasks

### A. Audit — Required
Start as if this code was handed over to you on a real team. Find the issues in `NativeBridgeV0` and explain, in `docs/REPORT.md` section 1, where each issue is, how severe it is, how it can be exploited or fail, and how you fixed it.

### B. Fix and Harden — Required
Write `src/NativeBridge.sol` to replace V0. It is a **fresh deployment**, not an upgrade. Fix the issues you found and make the bridge safe to run in production. Explain what you added and why in `docs/REPORT.md` section 2.

### C. Build the Chain B Bridge — Required
Write `src/WrappedBridge.sol`, the Chain B side, so that the whole round trip works: lock on A → mint on B → burn on B → unlock on A.

### D. Bridge and Stake — Required
Users on Chain A must be able to bridge HBR and stake it on Chain B in one transaction, with `lockWithHook`.

- Write `src/StakeOnArrival.sol`, the hook receiver on Chain B that stakes the bridged wHBR in `HarborStaking` for the beneficiary.
- If staking is not possible, the user must still receive their wHBR.
- No user may lose funds, or be kept from withdrawing them, because of bridge-and-stake.
- In `docs/REPORT.md` section 3, explain your Chain B design: how `WrappedBridge` and `StakeOnArrival` are structured, how a bridge-and-stake message flows from `lockWithHook` to `HarborStaking`, and why you designed it that way. Include a diagram (ASCII or Mermaid is fine).

### E. Tests — Required
Write the Foundry tests you consider necessary to show that `NativeBridgeV0` is broken and that your `NativeBridge`, `WrappedBridge` and `StakeOnArrival` are not: the attacks and failures you found should fail against your contracts. Write them against the fixed interface where possible — we may run your tests against other bridge implementations.

---

## Fixed Interface

`src/interfaces/` is fixed: `IHarborBridge.sol` is the protocol shared with the validator nodes, `IHarborStaking.sol` is the staking contract's interface, and `IStakeOnArrival.sol` defines your hook receiver. **They are not part of V0 — do not change them.** That includes the `Message` struct. Fix or replace anything in `NativeBridgeV0`, but keep the interfaces as they are.

We run our own test suite against your contracts through this interface. To make that possible:

- `src/NativeBridge.sol` implements `INativeBridge`; `src/WrappedBridge.sol` implements `IWrappedBridge`; `src/StakeOnArrival.sol` implements `IStakeOnArrival`.
- Constructors (fixed):
  - `NativeBridge`, `WrappedBridge`: `constructor(address token, uint256 remoteChainId, address[] memory validators, uint256 threshold, address admin)`
  - `StakeOnArrival`: `constructor(address bridge, address wrappedToken, address staking, uint256 pid)`
- You may add functions, including overloads with extra parameters, but the fixed signatures must not change and must keep working with sensible defaults.
- Your contracts must work right after the constructor — no extra setup calls.

Messages and signatures:

- `Message` is the wire format shared with the validator nodes. Bridges emit `MessageSent` for every outbound transfer; validators watch it. How `messageId` is derived is your decision.
- `Message.amount` is the amount the destination bridge releases to the recipient — minted on Chain B, transferred on Chain A — in HBR base units (18 decimals), in both directions.
- Validators sign exactly the digest returned by `messageDigest(message)` of the destination bridge: raw ECDSA over that digest, 65 bytes (r ‖ s ‖ v), no prefix. How you build the digest is your decision.
- Relayers submit at least `threshold` signatures, ordered by signer address, ascending.

Hooks (Chain A → Chain B only):

- `lockWithHook` sends a message with `hookData`. On Chain B the bridge mints to `recipient` and then calls `IBridgeHookReceiver(recipient).onBridgeReceived(srcChainId, sender, amount, hookData)`, where `amount` is the wHBR minted to the receiver.
- `hookGasLimit` is the gas budget the sender requests for the hook.
- Messages from Chain B to Chain A always have empty `hookData` and `hookGasLimit` 0.
- `StakeOnArrival` hook data is `abi.encode(address beneficiary)` — the account the stake belongs to.

Admin and errors:

- Admin functions take effect immediately when called by `admin`.
- Unauthorized calls, and invalid calls to the bridges, must revert. We do not check revert messages or error types.

Beyond that, the design is yours.

---

## Getting Started

```bash
npm install
forge build
forge test   # the public tests fail until src/NativeBridge.sol, src/WrappedBridge.sol and src/StakeOnArrival.sol exist
```

`test/Public.t.sol` shows how both chains are simulated in one EVM and how validator signatures are produced. It only covers the happy path; passing it says nothing about security.

---

## Submission

1. Complete the assignment.
2. Push your solution to **the repository we share with you** (`main` branch). You will be added as a collaborator. Ping us if you don't have write access.

Your repository should look like this when you submit:

```
src/
  NativeBridgeV0.sol             given — audit target
  interfaces/                    given — do not modify
  token/HarborToken.sol          given — do not modify
  token/WrappedHarbor.sol        given — do not modify
  staking/HarborStaking.sol      given — do not modify
  NativeBridge.sol               ← you write (Chain A)
  WrappedBridge.sol              ← you write (Chain B)
  StakeOnArrival.sol             ← you write (Chain B)
  ...                            ← any helper contracts you need
test/
  Public.t.sol                   given — do not modify
  ...                            ← your tests
docs/
  REPORT.md                      ← you write — sections 1 (Task A), 2 (Task B) and 3 (Task D), all required
foundry.toml                     given — keep the compiler settings; we build your contracts with them
```

`forge build` and `forge test` must pass.

---

## Notes

- In the interview you will walk us through your decisions. Make sure you understand and can defend every line you submit.
- We value judgment, trade-offs, and reasoning as much as raw completion.
