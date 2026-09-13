#!/usr/bin/env bash
# Provision a dedicated, per-rig SSH deploy key for pushing to the private
# keyorixhq/fuzz-corpus repo, isolated behind an SSH host alias so it never
# interferes with the rig's existing (HTTPS) git usage. Idempotent.
# Run on the rig as the SERVICE USER (so $HOME is that user's home).
set -euo pipefail
SSHDIR="$HOME/.ssh"; mkdir -p "$SSHDIR"; chmod 700 "$SSHDIR"
KEY="$SSHDIR/fuzz_corpus_ed25519"
[ -f "$KEY" ] || ssh-keygen -t ed25519 -f "$KEY" -N "" -C "fuzz-corpus-deploy-$(hostname)" >/dev/null
chmod 600 "$KEY"
ssh-keyscan -t ed25519,rsa github.com >> "$SSHDIR/known_hosts" 2>/dev/null || true
if ! grep -q "Host github-fuzzcorpus" "$SSHDIR/config" 2>/dev/null; then
  cat >> "$SSHDIR/config" <<EOF

Host github-fuzzcorpus
  HostName github.com
  User git
  IdentityFile $KEY
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
EOF
  chmod 600 "$SSHDIR/config"
fi
echo "PUBKEY[$(hostname)]: $(cat "$KEY.pub")"
