#!/bin/bash
set -euo pipefail

WALLET_FILE="${AIRDROP_WALLET_FILE:-/plugins/airdrop-wallets.txt}"

args=("$@")
if [ ${#args[@]} -eq 0 ]; then
  args=(start --no-tui -g /plugins/geyser-config.json)
fi

pubkeys=()

if [ -f "$WALLET_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    if [ -n "$line" ]; then
      pubkeys+=("$line")
    fi
  done < "$WALLET_FILE"
fi

if [ -n "${AIRDROP_PUBKEYS:-}" ]; then
  IFS=', ' read -r -a from_env <<< "$AIRDROP_PUBKEYS"
  for pk in "${from_env[@]}"; do
    if [ -n "$pk" ]; then
      pubkeys+=("$pk")
    fi
  done
fi

# surfpool airdrops per occurrence, so a repeat would double the balance
declare -A seen=()
for pk in "${pubkeys[@]}"; do
  if [ -z "${seen[$pk]:-}" ]; then
    seen[$pk]=1
    args+=(--airdrop "$pk")
    echo "airdrop at startup: $pk"
  fi
done

if [ -n "${AIRDROP_LAMPORTS:-}" ]; then
  args+=(--airdrop-amount "$AIRDROP_LAMPORTS")
  echo "airdrop amount: ${AIRDROP_LAMPORTS} lamports"
fi

exec surfpool "${args[@]}"
