#!/bin/bash
# PostToolUse hook: typecheck after every .ml/.mli edit (see CLAUDE.md).
# Exit 2 feeds compiler errors back to Claude; exit 0 is silent success.
export PATH="/opt/homebrew/bin:$PATH"

file=$(jq -r '.tool_input.file_path // empty')
case "$file" in
  *.ml | *.mli) ;;
  *) exit 0 ;;
esac

# Silently no-op while the toolchain is still being installed.
command -v opam >/dev/null 2>&1 || exit 0
opam exec -- dune --version >/dev/null 2>&1 || exit 0

cd "$CLAUDE_PROJECT_DIR" || exit 0
out=$(opam exec -- dune build @check 2>&1)
if [ $? -ne 0 ]; then
  printf '%s\n' "$out" | head -80 >&2
  exit 2
fi
exit 0
