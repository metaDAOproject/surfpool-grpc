# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Stage 1 — build the Yellowstone gRPC geyser plugin (.so).
#
# rust:bullseye => glibc 2.31, matching surfpool's debian:bullseye-slim runtime
# so the .so loads without a glibc mismatch.
#
# Pinned to the yellowstone-grpc release whose agave-geyser-plugin-interface
# matches surfpool's geyser ABI. The 4.0.2 plugin loads and streams account
# snapshots against surfpool 1.5.0, but ABORTS (exit 133, bogus alloc) when it
# encodes a live transaction — verified against the futarchy integration tests.
# The 4.1.0 plugin (v14.x) handles the live-tx path cleanly on the same base.
# Bump YELLOWSTONE_TAG and the surfpool base tag together — a major-version
# drift breaks plugin loading.
# ---------------------------------------------------------------------------
FROM rust:bullseye AS geyser

RUN apt-get update && apt-get install -y --no-install-recommends \
      protobuf-compiler \
      pkg-config \
      libssl-dev \
      git \
    && rm -rf /var/lib/apt/lists/*

ARG YELLOWSTONE_TAG=v14.1.1+solana.4.1.0

WORKDIR /src
RUN git clone --depth 1 --branch "${YELLOWSTONE_TAG}" \
      https://github.com/rpcpool/yellowstone-grpc .
RUN cargo build --release -p yellowstone-grpc-geyser
# produces /src/target/release/libyellowstone_grpc_geyser.so

# ---------------------------------------------------------------------------
# Stage 2 — overlay the plugin onto the published surfpool image.
# We do NOT rebuild surfpool; geyser support ships in the stock image since
# v1.4.0 (PR #639 removed the geyser feature gate).
# ---------------------------------------------------------------------------
FROM surfpool/surfpool:1.5.0

COPY --from=geyser /src/target/release/libyellowstone_grpc_geyser.so /plugins/plugin.so
COPY geyser-config.json /plugins/geyser-config.json

# gRPC (10000) + prometheus (8999) come from the plugin;
# 8899/8900/18488 are surfpool's own (already EXPOSEd by the base image).
EXPOSE 10000 8999

# The base entrypoint runs `surfpool "$@"`; custom args MUST include --no-tui.
CMD ["start", "--no-tui", "-g", "/plugins/geyser-config.json"]
