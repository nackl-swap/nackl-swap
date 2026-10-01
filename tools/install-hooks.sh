#!/usr/bin/env bash
# Installs the repo's git hooks (run once per clone):  bash tools/install-hooks.sh
set -eu
cd "$(git rev-parse --show-toplevel)"
cp tools/hooks/pre-commit .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
pp=.git/info/private-patterns
if [ ! -f "$pp" ]; then
  mkdir -p .git/info
  cat > "$pp" <<'EOF'
# One extended regex per line: personal names, emails, usernames, wallet ids you never want committed.
# This file lives inside .git/ and is never committed or pushed.
EOF
  echo "created $pp: add your personal identifiers to it"
fi
echo "pre-commit guard installed"
