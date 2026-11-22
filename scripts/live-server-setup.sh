#!/bin/bash
# Start a disposable SSH test host (dropbear, user-mode) for the SecureRemoteAgent
# live-host validation (scripts/live-validation.py). No system sshd or ~/.ssh
# changes: own host key, own authorized_keys dir, listens on 127.0.0.1:<port>.
#
# Usage: scripts/live-server-setup.sh [port] [scratch-dir]
#   default port: 23456   default dir: /Users/mbt/.hermes/cache/scratch/sra-live
set -euo pipefail

PORT="${1:-23456}"
SCR="${2:-/Users/mbt/.hermes/cache/scratch/sra-live}"
DROPBEAR="/opt/homebrew/sbin/dropbear"
DROPBEARKEY="$(brew --prefix dropbear)/bin/dropbearkey"

[ -x "$DROPBEAR" ] || { echo "install dropbear first: brew install dropbear" >&2; exit 1; }

mkdir -p "$SCR/server/auth" "$SCR/client" "$SCR/home"

if [ ! -f "$SCR/server/host_ed25519" ]; then
    "$DROPBEARKEY" -t ed25519 -f "$SCR/server/host_ed25519" 2>/dev/null
fi
if [ ! -f "$SCR/client/id_ed25519" ]; then
    ssh-keygen -t ed25519 -N '' -C sra-live-validation -f "$SCR/client/id_ed25519" -q
fi
cat "$SCR/client/id_ed25519.pub" > "$SCR/server/auth/authorized_keys"
chmod -R go-rwx "$SCR/server" "$SCR/client"

echo "listening on 127.0.0.1:$PORT  (scratch: $SCR)"
echo "fingerprint of the real host key is pinned on first connect (see phase 4)"
exec "$DROPBEAR" -F -E -s -m \
    -r "$SCR/server/host_ed25519" \
    -D "$SCR/server/auth" \
    -p "127.0.0.1:$PORT"
