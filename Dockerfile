# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Stage 1 — build the Yellowstone gRPC geyser plugin (.so).
#
# rust:bookworm => glibc 2.36, matching surfpool 1.6.0's debian:bookworm-slim
# runtime so the .so loads without a glibc mismatch. (1.5.0 was bullseye.)
#
# The plugin is loaded as a `dyn GeyserPlugin` trait object via _create_plugin,
# so the agave-geyser-plugin-interface MINOR version must match surfpool's or
# the vtable layout differs and calls land on the wrong method:
#   surfpool 1.6.0 -> agave-geyser-plugin-interface 4.2.1
#   yellowstone v15.2.1+solana.4.2.2 -> 4.2.2 (interface file identical to 4.2.1)
# Do NOT use yellowstone v16 (agave 4.3.0): it inserts Alpenglow methods into
# the middle of the trait.
# Bump YELLOWSTONE_TAG and the surfpool base tag together.
# ---------------------------------------------------------------------------
FROM rust:bookworm AS geyser

RUN apt-get update && apt-get install -y --no-install-recommends \
      protobuf-compiler \
      pkg-config \
      libssl-dev \
      git \
    && rm -rf /var/lib/apt/lists/*

ARG YELLOWSTONE_TAG=v15.2.1+solana.4.2.2

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
FROM surfpool/surfpool:1.6.0

COPY --from=geyser /src/target/release/libyellowstone_grpc_geyser.so /plugins/plugin.so
COPY geyser-config.json /plugins/geyser-config.json
COPY airdrop-wallets.txt /plugins/airdrop-wallets.txt
COPY entrypoint.sh /usr/local/bin/surfpool-grpc-entrypoint.sh
RUN chmod +x /usr/local/bin/surfpool-grpc-entrypoint.sh

# gRPC (10000) + prometheus (8999) come from the plugin;
# 8899/8900/18488 are surfpool's own (already EXPOSEd by the base image).
EXPOSE 10000 8999

# Replaces the base entrypoint: appends --airdrop flags from
# /plugins/airdrop-wallets.txt and $AIRDROP_PUBKEYS, then execs surfpool.
# Custom args MUST include --no-tui.
ENTRYPOINT ["/usr/local/bin/surfpool-grpc-entrypoint.sh"]
CMD ["start", "--no-tui", "-g", "/plugins/geyser-config.json"]
