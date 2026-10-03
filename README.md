# surfpool-grpc

Builds a [surfpool](https://github.com/solana-foundation/surfpool) Docker image
with a **Yellowstone gRPC (Dragon's Mouth) geyser plugin** baked in, so our
indexer can stream from a surfnet over gRPC on staging instead of RPC logs.

## Why this repo exists

- The stock `surfpool/surfpool` image ships geyser support (since v1.4.0, PR
  #639) but **does not** include any geyser plugin and exposes no gRPC port.
- gRPC = load a `yellowstone-grpc` geyser `.so` via `surfpool start -g <config>`.
  The plugin, its config, and the port are what this image adds.
- We consume surfpool as a published image — no surfpool source build here. A
  two-stage Dockerfile builds only the plugin `.so` and layers it on top.

## How it works

`Dockerfile`:
1. Stage 1 (`rust:bookworm`) builds `libyellowstone_grpc_geyser.so`.
2. Stage 2 (`surfpool/surfpool:1.6.0`) copies the `.so` + `geyser-config.json`
   in, exposes gRPC `10000`, and starts surfpool with `-g`.

`geyser-config.json`: plugin config. gRPC on `0.0.0.0:10000`, no `x_token`
(open — staging only), permissive filter limits so the indexer can subscribe
broadly. Prometheus metrics on `8999`.

## Version pins (keep in lockstep)

| Component | Pin | Why |
|-----------|-----|-----|
| surfpool base image | `surfpool/surfpool:1.6.0` (Docker tags drop the `v`) | geyser plugin support |
| yellowstone-grpc | `v15.2.1+solana.4.2.2` (`YELLOWSTONE_TAG` ARG) | its `agave-geyser-plugin-interface` 4.2.2 matches surfpool 1.6.0's 4.2.1 |
| builder base | `rust:bookworm` | glibc 2.36, matching surfpool 1.6.0's `debian:bookworm-slim` runtime |

**Why the agave version must match.** surfpool loads the `.so` through
`_create_plugin` as a `dyn GeyserPlugin` trait object
(`crates/core/src/runloops/mod.rs`), so the vtable layout must be identical on
both sides. The interface file is byte-identical across agave 4.2.0 / 4.2.1 /
4.2.2 (20 trait methods), so yellowstone v15.x is safe against surfpool 1.6.0.

- agave **4.1.0** (yellowstone v14.x) has 17 trait methods — mismatched.
- agave **4.3.0** (yellowstone v16.x) inserts Alpenglow methods (`update_bank_status`,
  `notify_transaction_for_bank`, `notify_block_footer`, …) into the *middle* of
  the trait — every later vtable index shifts. Do not use v16 until surfpool
  moves to agave 4.3.

**Bumping:** move both together. Read surfpool's `Cargo.lock` for its
`agave-geyser-plugin-interface` version, then pick the yellowstone tag whose
lock has the same minor.

## Build & run locally

```bash
docker build -t surfpool-grpc .
docker run --rm -p 8899:8899 -p 8900:8900 -p 10000:10000 surfpool-grpc
# gRPC (Dragon's Mouth) is now on localhost:10000
```

Override the yellowstone pin without editing the Dockerfile:

```bash
docker build --build-arg YELLOWSTONE_TAG=v15.2.1+solana.4.2.2 -t surfpool-grpc .
```

## Airdropping wallets at startup

`entrypoint.sh` turns a wallet list into surfpool's repeatable `--airdrop` flag,
so the pubkeys live in config rather than in the `CMD`.

- **Baked in:** add pubkeys to `airdrop-wallets.txt`, one per line (`#` comments
  and blank lines ignored). Copied to `/plugins/airdrop-wallets.txt`.
- **At runtime:** `AIRDROP_PUBKEYS` — comma- or space-separated pubkeys, added to
  whatever the file holds.
- **Amount:** `AIRDROP_LAMPORTS`. Defaults to surfpool's 10000000000000 (10,000
  SOL) per address. Must be at or above the rent-exempt minimum or surfpool
  skips the airdrop and logs an error.
- **Different file:** `AIRDROP_WALLET_FILE`.

Duplicates are dropped — surfpool airdrops once per `--airdrop` occurrence, so a
repeated pubkey would otherwise get funded twice.

```bash
docker run --rm -p 8899:8899 -p 10000:10000 \
  -e AIRDROP_PUBKEYS="Pubkey1,Pubkey2" \
  -e AIRDROP_LAMPORTS=2500000000 \
  surfpool-grpc
```

These are genesis airdrops through the same cheatcode path as `requestAirdrop`,
so they fund the accounts but **emit nothing over gRPC**.

## Deploy (Northflank, staging)

- Service build: **Dockerfile**, context = repo root, path = `./Dockerfile`.
- Expose port **10000** (gRPC). Optionally 8899/8900 if clients need RPC/WS.
- Point the indexer's `GRPC_ENDPOINT` at the service's `10000` address.

## Notes

- No auth on the gRPC port (`x_token: null`) — staging only. Set `x_token` before
  any exposure beyond the staging network.
- `rust:bookworm` tracks latest stable Rust; pin `rust:<version>-bookworm` in the
  Dockerfile if you need reproducible plugin builds.

## Gotchas (verified at build/run time)

- **Subscribe with `commitment: PROCESSED`. `CONFIRMED` and `FINALIZED` deliver
  nothing.** Verified on both yellowstone v14.1.1/surfpool 1.5.0 and
  v15.2.1/surfpool 1.6.0: an identical account+transaction subscription returns
  2 account updates and the exact transfer signature at `PROCESSED`, and zero
  messages at `CONFIRMED` (waited 20s). **Cause, read in source:** the geyser
  loop broadcasts every message straight to the `Processed` ring
  (`yellowstone-grpc-geyser/src/grpc.rs:1322`), while the `Confirmed` and
  `Finalized` rings are fed only from `block_machine.pop_ready_block()` in
  `block_reconstruction_loop` — i.e. only once a block fully reconstructs. No
  block ever reconstructs on surfpool (see below), so those two rings stay
  empty forever.
- **`grpc.listen` is now the field to use** (`[{"address": "0.0.0.0:10000"}]`).
  On yellowstone `v13.3.1+solana.4.0.2` it crashed surfpool at plugin load
  (`free(): invalid pointer`, exit 133); on `v15.2.1` it loads, binds, and
  streams cleanly, while `address` logs a deprecation warning.
- **Streaming on surfpool 1.6.0 — verified with a real submitted tx:**
  - ✅ **Account subscriptions work** (payer+recipient, correct post-balances/slot).
  - ✅ **Transaction subscriptions work** — a real non-vote transfer streamed at
    the exact transfer slot. Note yellowstone's `failed:true` filter means
    *only-failed* txs; leave `failed` unset to get all.
  - ❌ **Slot (`slots`) and block (`blocks`) subscriptions get ~nothing** — the
    plugin drops the events (`geyser_untrack_slot_event_dropped_total` climbs ~1
    per slot; observed 202 over one test run).
  - Note: `requestAirdrop` uses a surfpool cheatcode that BYPASSES geyser — funds
    accounts but emits nothing. Test streaming with real submitted txs only.
  - **Root cause (confirmed on both sides in source):** yellowstone begins
    *tracking* a slot only on a **lifecycle** status — `FirstShredReceived` /
    `Completed` / `CreatedBank` (`yellowstone-grpc-geyser/src/block_reconstruction.rs:305`). The
    **commitment** statuses `Processed`/`Confirmed`/`Finalized` only advance an
    already-tracked slot. surfpool emits ONLY `Confirmed` + `Rooted` and its
    `GeyserSlotStatus` enum has no lifecycle variants at all
    (`crates/core/src/surfnet/mod.rs:46`, unchanged in 1.6.0). So no slot is ever
    tracked → block reconstruction drops all block_data → no block ever
    assembles → the synthetic slot-status broadcast that feeds `slots`/`blocks`
    subscribers never fires. Account/transaction subscriptions at `PROCESSED` are
    unaffected because those are broadcast directly on arrival.
  - **Why it's by design, not a fixable omission:** surfpool has no gossip layer
    and a manipulable clock (time travel) — slots are non-contiguous (getSlot
    jumped 16 in ~6s in testing; slot number ≠ one block each). Its own comment
    (`crates/core/src/surfnet/svm.rs:2744`) states the lifecycle statuses are "intentionally not produced."
    yellowstone's block state machine assumes contiguous slots with lifecycle
    events and skip-detection; a jumpy/time-traveling clock is fundamentally
    incompatible.
  - **Impact:** build the indexer on `accounts` + `transactions` at `PROCESSED`.
    Do NOT rely on `slots`/`blocks` streams, or on `CONFIRMED`/`FINALIZED`
    commitment, for progress — unsupported on surfpool.
