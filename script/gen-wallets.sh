#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_KEYS="$REPO_ROOT/.env.multisig.local"
ENV_ADDRS="$REPO_ROOT/.env.multisig.addresses"
GITIGNORE="$REPO_ROOT/.gitignore"

if ! command -v cast >/dev/null 2>&1; then
  echo "ERROR: foundry's 'cast' is required. Install: https://book.getfoundry.sh/getting-started/installation" >&2
  exit 1
fi

if [[ -e "$ENV_KEYS" ]]; then
  echo "ERROR: $ENV_KEYS already exists. Refusing to overwrite existing private keys." >&2
  echo "       Move or delete it manually if you really want to regenerate." >&2
  exit 1
fi

GITIGNORE_PATTERNS=(
  ".env"
  ".env.*"
  "!.env.example"
  "!.env.multisig.example"
  "*.key"
  "*.wallet"
  "*.dwallet"
  "*.keystore"
  "*.pem"
  "private-keys.txt"
  "generated-wallets.json"
  "secrets/"
  ".secrets/"
)
mkdir -p "$REPO_ROOT"
touch "$GITIGNORE"
ADDED_HEADER=0
for pat in "${GITIGNORE_PATTERNS[@]}"; do
  if ! grep -qxF "$pat" "$GITIGNORE"; then
    if [[ $ADDED_HEADER -eq 0 ]]; then
      printf '\n' >> "$GITIGNORE"
      ADDED_HEADER=1
    fi
    echo "$pat" >> "$GITIGNORE"
  fi
done

ROLES=(
  "NOX_SAFE_SIGNER_1_OWNER"
  "NOX_SAFE_SIGNER_2_SECURITY"
  "NOX_SAFE_SIGNER_3_TREASURY"
  "NOX_SAFE_SIGNER_4_OPERATIONS"
  "NOX_SAFE_SIGNER_5_RECOVERY"
)

umask 077

{
  echo "NOX Safe owner private keys"
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "DO NOT COMMIT. DO NOT SHARE. DO NOT ECHO."
  echo ""
} > "$ENV_KEYS"

{
  echo "NOX Safe owner public addresses"
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""
} > "$ENV_ADDRS"

__NEW_ADDR=""
__NEW_PRIV=""

gen_one() {
  __NEW_ADDR=""
  __NEW_PRIV=""
  local out
  if command -v jq >/dev/null 2>&1 && out=$(cast wallet new --json 2>/dev/null); then
    __NEW_ADDR=$(echo "$out" | jq -r '.[0].address // empty')
    __NEW_PRIV=$(echo "$out" | jq -r '.[0].private_key // .[0].privateKey // empty')
  else
    out=$(cast wallet new)
    __NEW_ADDR=$(echo "$out" | awk -F': *' '/^Address:/ {print $2; exit}')
    __NEW_PRIV=$(echo "$out" | awk -F': *' '/^Private [Kk]ey:/ {print $2; exit}')
  fi
  if [[ -z "$__NEW_ADDR" || -z "$__NEW_PRIV" ]]; then
    echo "ERROR: failed to parse cast wallet new output" >&2
    return 1
  fi
}

echo ""
echo "Generating 5 Safe signer wallets..."
echo ""
for role in "${ROLES[@]}"; do
  gen_one || exit 1
  addr="$__NEW_ADDR"
  priv="$__NEW_PRIV"
  __NEW_ADDR=""
  __NEW_PRIV=""

  printf '%s_PRIVATE_KEY=%s\n' "$role" "$priv" >> "$ENV_KEYS"
  printf '%s_ADDRESS=%s\n'     "$role" "$addr" >> "$ENV_KEYS"
  printf '\n'                                  >> "$ENV_KEYS"

  printf '%s_ADDRESS=%s\n' "$role" "$addr" >> "$ENV_ADDRS"

  printf '  %-32s %s\n' "$role" "$addr"
  unset priv
done

chmod 600 "$ENV_KEYS"

cat <<EOF

----------------------------------------------------------------------------
Generated 5 Safe signer wallets locally.

  Private keys:    $ENV_KEYS              (mode 600 - never commit)
  Addresses only:  $ENV_ADDRS             (safe to share)

The .gitignore was updated to protect:
$(printf '   - %s\n' "${GITIGNORE_PATTERNS[@]}")

Next:
  1. Open .env.multisig.local and confirm the 5 entries before doing anything.
  2. Fund each signer with a small amount of ETH (~0.01 ETH each) for Safe
     ownership signature flows.
  3. Deploy the Safe via https://app.safe.global on Ethereum Mainnet:
       - Owners: the 5 addresses listed above
       - Threshold: 3 of 5
  4. Capture the deployed Safe address and add it to your .env as:
       NOX_MULTISIG_ADDRESS=0x...
  5. When ready to migrate roles:
       forge script script/MigrateRolesNOX.s.sol --rpc-url \$ETH_RPC_URL
     and follow the printed calldata sequence.

REMINDER:
  - .env.multisig.local is mode 600 (owner-only) and gitignored.
  - Do NOT paste the contents into chat, screenshots, or shared logs.
  - Back up this file to a hardware-encrypted device or a paper wallet split.
----------------------------------------------------------------------------
EOF
