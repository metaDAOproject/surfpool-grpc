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
1. Stage 1 (`rust:bullseye`) builds `libyellowstone_grpc_geyser.so`.
2. Stage 2 (`surfpool/surfpool:1.4.0`) copies the `.so` + `geyser-config.json`
   in, exposes gRPC `10000`, and starts surfpool with `-g`.

`geyser-config.json`: plugin config. gRPC on `0.0.0.0:10000`, no `x_token`
(open — staging only), permissive filter limits so the indexer can subscribe
broadly. Prometheus metrics on `8999`.

## Version pins (keep in lockstep)

| Component | Pin | Why |
|-----------|-----|-----|
| surfpool base image | `surfpool/surfpool:1.4.0` (Docker tags drop the `v`) | `agave-geyser-plugin-interface = "4.0"` |
| yellowstone-grpc | `v13.3.1+solana.4.0.2` (`YELLOWSTONE_TAG` ARG) | pins `agave-geyser-plugin-interface = "=4.0.2"` — same 4.0.x ABI |

**Bumping:** move both together. If you bump surfpool to a base built against a
new agave-geyser-plugin-interface major, pick the yellowstone tag pinning the
matching major, or the plugin fails to load at startup.

## Build & run locally

```bash
docker build -t surfpool-grpc .
docker run --rm -p 8899:8899 -p 8900:8900 -p 10000:10000 surfpool-grpc
# gRPC (Dragon's Mouth) is now on localhost:10000
```

Override the yellowstone pin without editing the Dockerfile:

```bash
docker build --build-arg YELLOWSTONE_TAG=v14.1.1+solana.4.1.0 -t surfpool-grpc .
```

## Deploy (Northflank, staging)

- Service build: **Dockerfile**, context = repo root, path = `./Dockerfile`.
- Expose port **10000** (gRPC). Optionally 8899/8900 if clients need RPC/WS.
- Point the indexer's `GRPC_ENDPOINT` at the service's `10000` address.

## Notes

- No auth on the gRPC port (`x_token: null`) — staging only. Set `x_token` before
  any exposure beyond the staging network.
- `rust:bullseye` tracks latest stable Rust; pin `rust:<version>-bullseye` in the
  Dockerfile if you need reproducible plugin builds.

## Gotchas (verified at build/run time)

- **Keep `grpc.address`, do NOT switch to `grpc.listen`.** The plugin logs a
  deprecation warning recommending `listen: ["0.0.0.0:10000"]`, but on
  yellowstone `v13.3.1+solana.4.0.2` that field crashes surfpool at plugin load
  (`free(): invalid pointer`, exit 133) — deterministic, 3/3. The `address`
  field works; the warning is cosmetic. Revisit only when bumping yellowstone.
- **Streaming on surfpool 1.4.0/1.5.0 — verified with a real submitted tx:**
  - ✅ **Account subscriptions work** (payer+recipient, correct post-balances/slot).
  - ✅ **Transaction subscriptions work** — a real non-vote transfer streamed at
    the exact transfer slot. (Earlier "broken" was a test error: yellowstone's
    `failed:true` filter means *only-failed* txs, so it excluded the successful
    transfer. Use `failed` unset to get all.)
  - ❌ **Slot (`slots`) and block (`blocks`) subscriptions get ~nothing** — the
    plugin drops the events (`geyser_untrack_slot_event_dropped_total` climbs ~1
    per slot).
  - Note: `requestAirdrop` uses a surfpool cheatcode that BYPASSES geyser — funds
    accounts but emits nothing. Test streaming with real submitted txs only.
  - **Root cause (confirmed on both sides in source):** yellowstone begins
    *tracking* a slot only on a **lifecycle** status — `FirstShredReceived` /
    `Completed` / `CreatedBank` (`block_reconstruction.rs::on_message_slot`). The
    **commitment** statuses `Processed`/`Confirmed`/`Finalized` only advance an
    already-tracked slot. surfpool emits ONLY `Confirmed` + `Rooted` and its
    `GeyserSlotStatus` enum has no lifecycle variants at all (`surfnet/mod.rs`;
    `svm.rs` comment says lifecycle statuses are "intentionally not produced").
    So no slot is ever tracked → block reconstruction drops all block_data
    (`handle_block_data` → untrack counter) → no block ever assembles → the
    synthetic slot-status broadcast that feeds `slots`/`blocks` subscribers never
    fires. Account/transaction subscriptions are unaffected because those are
    broadcast directly on arrival.
  - **Why it's by design, not a fixable omission:** surfpool has no gossip layer
    and a manipulable clock (time travel) — slots are non-contiguous (getSlot
    jumped 16 in ~6s in testing; slot number ≠ one block each). Its own comment
    (`svm.rs:2457`) states the lifecycle statuses are "intentionally not produced."
    yellowstone's block state machine assumes contiguous slots with lifecycle
    events and skip-detection; a jumpy/time-traveling clock is fundamentally
    incompatible. Synthesizing `FirstShredReceived` would fight yellowstone's
    skipped-slot logic. So this is a design mismatch, not a missing line.
  - **Impact:** build the indexer on `accounts` + `transactions` (work today). Do
    NOT rely on `slots`/`blocks` streams for progress/commitment — unsupported on
    surfpool.
