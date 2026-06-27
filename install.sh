#!/bin/bash
set -euo pipefail

print_usage() {
  cat <<'EOF'
Claude Code Token Optimization Stack installer

Usage:
  ./install.sh [options]

Power-user default:
  Installs Headroom + lean-ctx, CBM, context-mode, Caveman, hooks, commands,
  statusline, settings, and durable Headroom routing so `claude` auto-routes
  through the proxy (terminal, desktop app, or IDE).

Options:
  --check              Validate repo settings/hooks/commands without installing.
  --no-durable-routing Run the Headroom proxy container, but don't write global
                       routing — start claude with ANTHROPIC_BASE_URL set yourself.
  --no-caveman         Skip Caveman plugin install and omit it from merged settings.
  --sonnet             Use `model: sonnet` and `effortLevel: high` instead of Opus/xhigh.
  -h, --help           Show this help.

Examples:
  ./install.sh
  ./install.sh --no-durable-routing
  ./install.sh --no-caveman --sonnet
  ./install.sh --check --no-caveman --sonnet
EOF
}

CHECK_ONLY=0
INSTALL_CAVEMAN=1
INSTALL_DURABLE_ROUTING=1
MODEL_PROFILE="power"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      CHECK_ONLY=1
      shift
      ;;
    --no-durable-routing)
      INSTALL_DURABLE_ROUTING=0
      shift
      ;;
    --no-caveman)
      INSTALL_CAVEMAN=0
      shift
      ;;
    --sonnet)
      MODEL_PROFILE="sonnet"
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      print_usage >&2
      exit 2
      ;;
  esac
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_SOURCE="$REPO_DIR/settings/settings.json"
export CCT_REPO_DIR="$REPO_DIR"
# Shared registry/primitives, also used by uninstall.sh.
# shellcheck source=lib/cct-lib.sh
. "$REPO_DIR/lib/cct-lib.sh"
SETTINGS_TMP=""

cleanup_tmp() {
  [[ -n "${SETTINGS_TMP:-}" ]] && rm -f "$SETTINGS_TMP"
  return 0
}
trap cleanup_tmp EXIT

prepare_settings_source() {
  local filter='.'

  if [[ "$INSTALL_CAVEMAN" -eq 0 ]]; then
    filter="$filter | del(.enabledPlugins[\"caveman@caveman\"]) | del(.extraKnownMarketplaces.caveman)"
  fi

  if [[ "$MODEL_PROFILE" == "sonnet" ]]; then
    filter="$filter | .model = \"sonnet\" | .effortLevel = \"high\""
  fi

  if [[ "$filter" != "." ]]; then
    SETTINGS_TMP="$(mktemp)"
    jq "$filter" "$REPO_DIR/settings/settings.json" > "$SETTINGS_TMP"
    SETTINGS_SOURCE="$SETTINGS_TMP"
  fi
}

# ── Validator mode ──
if [[ "$CHECK_ONLY" -eq 1 ]]; then
  echo "=== install.sh --check ==="
  fail=0

  # 1. JSON syntax
  if ! command -v jq >/dev/null 2>&1; then
    echo "FAIL: jq not installed (required by hooks + check mode)"; fail=1
  else
    prepare_settings_source
    if ! jq empty "$SETTINGS_SOURCE" 2>/dev/null; then
      echo "FAIL: settings/settings.json is not valid JSON"; fail=1
    fi
  fi

  # 2. Every hook command path in settings resolves to a file in repo hooks/
  if command -v jq >/dev/null 2>&1; then
    while IFS= read -r cmd; do
      [[ -z "$cmd" ]] && continue
      hook_path="${cmd//\~/$HOME}"
      hook_path="${hook_path%% *}"
      [[ "$hook_path" == "$HOME/.claude/hooks/"* ]] || continue
      hook_name="${hook_path##*/}"
      if [[ ! -f "$REPO_DIR/hooks/$hook_name" ]]; then
        echo "FAIL: settings.json references hook '$hook_name' but $REPO_DIR/hooks/$hook_name missing"; fail=1
      fi
    done < <(jq -r '[.. | objects | select(.command? != null) | .command] | .[]' "$SETTINGS_SOURCE")
  fi

  # 3. Every commands/*.md plugin reference resolves to an enabled plugin
  while IFS= read -r f; do
    while IFS= read -r ref; do
      plugin="${ref#mcp__plugin_}"
      plugin="${plugin%%_*}"
      if ! jq -e --arg p "$plugin" '.enabledPlugins | keys[] | select(startswith($p))' "$SETTINGS_SOURCE" >/dev/null 2>&1; then
        echo "FAIL: $f references mcp__plugin_${plugin}_* but no '$plugin@*' enabled in settings"; fail=1
      fi
    done < <(grep -oE 'mcp__plugin_[a-z0-9_-]+' "$f" 2>/dev/null | sort -u)
  done < <(find "$REPO_DIR/commands" -name '*.md' 2>/dev/null)

  # 4. bin/ scripts referenced by hooks must exist
  for script in sync-copilot.mjs sync-runner-tools.mjs; do
    if grep -rqE "bin/$script" "$REPO_DIR/hooks/" 2>/dev/null; then
      [[ -f "$REPO_DIR/bin/$script" ]] || { echo "FAIL: hooks reference bin/$script but $REPO_DIR/bin/$script missing"; fail=1; }
    fi
  done

  if [[ $fail -eq 0 ]]; then
    echo "OK: all hooks, command plugin refs, and bin/ scripts resolve"
    exit 0
  fi
  exit 1
fi

echo "=== Claude Code Token Optimization Stack ==="
echo "Installing: Headroom + lean-ctx + CBM + context-mode + hooks"
if [[ "$INSTALL_CAVEMAN" -eq 1 ]]; then
  echo "Power-user output compression: Caveman enabled"
else
  echo "Power-user output compression: Caveman skipped (--no-caveman)"
fi
if [[ "$INSTALL_DURABLE_ROUTING" -eq 1 ]]; then
  echo "Durable routing: enabled (persistent proxy + claude auto-routes)"
else
  echo "Durable routing: skipped (--no-durable-routing)"
fi
if [[ "$MODEL_PROFILE" == "sonnet" ]]; then
  echo "Model profile: sonnet/high (--sonnet)"
else
  echo "Model profile: opus/xhigh"
fi
echo ""

# ── 0. Sanity-check required tools ──
# Hooks rely on jq; install.sh's --check validator does too. Catch missing
# tools up front with one clear message rather than cryptic errors mid-run.
# NOTE: python3 is intentionally NOT required — the Headroom compression layer
# now runs as a Docker container, so the stack has no host-Python dependency.
# (python3 is still used opportunistically as a `readlink -f` realpath fallback
# in the symlink guards, but its absence is non-fatal.)
missing=""
for cmd in git curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
done
if [[ -n "$missing" ]]; then
  echo "❌ Missing required tools:$missing"
  echo "   macOS:  brew install$missing"
  echo "   Debian: sudo apt-get install -y$missing"
  echo "   Re-run install.sh once they are on PATH."
  exit 1
fi

prepare_settings_source

# Capture a sticky pre-install baseline of ambiguous shared items (plugins,
# marketplaces, MCP servers, env keys, Headroom daemon) BEFORE we mutate anything,
# so uninstall.sh can later prove exactly what THIS repo added. No-op once recorded.
set +e; cct_capture_baseline; set -e

# Upgrade cleanup runs BEFORE step 1: a previous version may have left a
# host-installed Headroom proxy (launchd daemon) holding port 8787, which would
# make the container's `docker run -p 8787` fail. Migrating first frees the port
# and strips deprecated hooks. Idempotent — a no-op on a fresh or current install.
set +e; cct_migrate "$(cct_installed_version)"; set -e

# ── 1. Install / update the Headroom compression proxy (Docker) ──
# Headroom runs as a container — no host Python. The published image's
# ENTRYPOINT is `headroom proxy` and its default CMD binds 0.0.0.0:8787, so we
# run it with no args, publish 8787 on loopback only, and mount a named volume
# at the image's VOLUME (/home/nonroot/.headroom) so savings/stats survive image
# updates. The container's MCP tools (compress/retrieve/stats) are auto-exposed
# at /mcp on the same port and wired up in step 9.
#
# qdrant/neo4j (Headroom's optional "memory-stack" for semantic search) are NOT
# started here — the standalone proxy provides compression + compress/retrieve/
# stats on its own and degrades gracefully without them.
HEADROOM_UP=0
echo "→ Setting up the Headroom compression proxy (Docker)..."
if ! command -v docker >/dev/null 2>&1; then
  echo "  ⚠ docker not found. Headroom now runs as a container — install Docker Desktop"
  echo "    (https://www.docker.com/products/docker-desktop/), make sure it starts at login,"
  echo "    then re-run install.sh. Skipping Headroom for now."
elif ! docker info >/dev/null 2>&1; then
  echo "  ⚠ Docker is installed but its daemon isn't running. Start Docker Desktop and"
  echo "    re-run install.sh. Skipping Headroom for now."
else
  echo "  → Pulling $CCT_HEADROOM_IMAGE ..."
  docker pull "$CCT_HEADROOM_IMAGE" >/dev/null 2>&1 \
    || echo "  ⚠ docker pull failed — falling back to whatever image is already local."
  # A running container keeps the image it was started from, so an image update
  # is only adopted on recreate. Recreate ONLY when the desired image differs
  # from what's running (or the container is down) — repeat installs of an
  # already-current, healthy proxy are a no-op rather than a churn.
  desired_img="$(docker image inspect -f '{{.Id}}' "$CCT_HEADROOM_IMAGE" 2>/dev/null || true)"
  running_img="$(docker inspect -f '{{.Image}}' "$CCT_HEADROOM_CONTAINER" 2>/dev/null || true)"
  running_state="$(docker inspect -f '{{.State.Running}}' "$CCT_HEADROOM_CONTAINER" 2>/dev/null || true)"
  if [[ "$running_state" == "true" && -n "$desired_img" && "$running_img" == "$desired_img" ]]; then
    echo "  ✓ Headroom container already running on the current image."
  else
    docker rm -f "$CCT_HEADROOM_CONTAINER" >/dev/null 2>&1 || true
    if ! docker run -d \
          --name "$CCT_HEADROOM_CONTAINER" \
          --restart unless-stopped \
          -p "127.0.0.1:${CCT_HEADROOM_PORT}:8787" \
          -v "${CCT_HEADROOM_VOLUME}:/home/nonroot/.headroom" \
          "$CCT_HEADROOM_IMAGE" >/dev/null 2>&1; then
      echo "  ⚠ 'docker run' failed. If port ${CCT_HEADROOM_PORT} is already taken by an older"
      echo "    host-installed Headroom proxy, stop it ('headroom install remove') and re-run."
      echo "    Otherwise inspect: docker logs $CCT_HEADROOM_CONTAINER"
    fi
  fi
  # `docker run -d` returns success even if the proxy crash-loops a second later,
  # so poll the same /readyz endpoint the image's HEALTHCHECK uses before trusting it.
  for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${CCT_HEADROOM_PORT}/readyz" >/dev/null 2>&1; then
      HEADROOM_UP=1; break
    fi
    sleep 1
  done
  if [[ "$HEADROOM_UP" == 1 ]]; then
    echo "  ✓ Headroom proxy healthy at http://127.0.0.1:${CCT_HEADROOM_PORT} (restart policy: unless-stopped)"
  else
    echo "  ⚠ Headroom proxy didn't become ready within 30s. Recent logs:"
    docker logs --tail 20 "$CCT_HEADROOM_CONTAINER" 2>&1 | sed 's/^/      /' || true
    echo "    Routing/MCP wiring (step 9) will be skipped until the proxy is healthy."
  fi
fi
export HEADROOM_UP

# ── 1b. Ensure lean-ctx (the command-rewriting context tool) ──
# This stack uses lean-ctx for BOTH Headroom's context layer
# (HEADROOM_CONTEXT_TOOL=lean-ctx) and for the Claude Code PreToolUse hook
# (`lean-ctx hook rewrite` in settings.json). Install lean-ctx and verify it runs
# (its `hook rewrite` entrypoint ships with lean-ctx 3.x).
echo "→ Ensuring lean-ctx (command-rewriting context tool)..."
# `lean-ctx hook --help` exits nonzero (it's a subcommand group), so probe with
# `--version` — exit 0 confirms lean-ctx is installed and runnable.
leanctx_hook_ok() { command -v lean-ctx >/dev/null 2>&1 && lean-ctx --version >/dev/null 2>&1; }
if leanctx_hook_ok; then
  echo "  ✓ lean-ctx present ($(lean-ctx --version 2>/dev/null | head -1))"
else
  if command -v brew >/dev/null 2>&1; then
    # Homebrew gates third-party taps; trust just this formula, not the whole tap.
    brew tap yvgude/lean-ctx 2>/dev/null || true
    brew trust --formula yvgude/lean-ctx/lean-ctx 2>/dev/null || true
    { brew list lean-ctx >/dev/null 2>&1 && brew upgrade lean-ctx 2>/dev/null; } \
      || brew install lean-ctx 2>/dev/null || true
  elif command -v npm >/dev/null 2>&1; then
    npm install -g lean-ctx-bin 2>/dev/null || true
  fi
  hash -r 2>/dev/null || true
  if leanctx_hook_ok; then
    echo "  ✓ lean-ctx installed ($(lean-ctx --version 2>/dev/null | head -1))"
  else
    echo "  ⚠ lean-ctx not on PATH. Install it (https://github.com/yvgude/lean-ctx) —"
    echo "    e.g. 'brew install lean-ctx' or 'npm install -g lean-ctx-bin' — then re-run."
  fi
fi

# ── 2. Install codebase-memory-mcp ──
# Releases ship as <name>-<os>-<arch>.tar.gz. We download, extract the binary,
# and drop it in ~/.local/bin (caller is expected to have ~/.local/bin on PATH).
echo "→ Installing codebase-memory-mcp..."
CBM_OS=""
CBM_ARCH=""
case "$(uname)" in
  Darwin) CBM_OS="darwin" ;;
  Linux)  CBM_OS="linux" ;;
  *) echo "  ⚠ Unsupported OS: $(uname). Skipping CBM install."; CBM_OS="" ;;
esac
case "$(uname -m)" in
  arm64|aarch64)  CBM_ARCH="arm64" ;;
  x86_64|amd64)   CBM_ARCH="amd64" ;;
  *) echo "  ⚠ Unsupported arch: $(uname -m). Skipping CBM install."; CBM_ARCH="" ;;
esac
if [[ -n "$CBM_OS" && -n "$CBM_ARCH" ]]; then
  CBM_URL="https://github.com/DeusData/codebase-memory-mcp/releases/latest/download/codebase-memory-mcp-${CBM_OS}-${CBM_ARCH}.tar.gz"
  mkdir -p "$HOME/.local/bin"
  CBM_TMP="$(mktemp -d)"
  if curl -fsSL "$CBM_URL" -o "$CBM_TMP/cbm.tar.gz"; then
    tar -xzf "$CBM_TMP/cbm.tar.gz" -C "$CBM_TMP"
    if [[ -f "$CBM_TMP/codebase-memory-mcp" ]]; then
      mv "$CBM_TMP/codebase-memory-mcp" "$HOME/.local/bin/codebase-memory-mcp"
      chmod +x "$HOME/.local/bin/codebase-memory-mcp"
      # Register CBM (MCP server + CBM's own hooks) non-interactively. The current
      # CLI uses `install -y`; the old `setup claude-code` no longer exists, and an
      # UNRECOGNIZED subcommand makes the binary fall through to "run MCP server on
      # stdio" — which blocks reading the terminal's stdin and hangs the installer.
      # `</dev/null` is extra insurance against any prompt. (On a CBM index-format
      # change, `-y` auto-confirms rebuilding existing indexes.)
      "$HOME/.local/bin/codebase-memory-mcp" install -y </dev/null >/dev/null 2>&1 || true
      echo "  ✓ CBM installed at ~/.local/bin/codebase-memory-mcp"
    else
      echo "  ⚠ CBM tarball extracted but binary not found — open an issue at the repo"
    fi
  else
    echo "  ⚠ CBM download failed ($CBM_URL). Skip and run manually later."
  fi
  rm -rf "$CBM_TMP"
fi

# ── 3. Install Claude Code plugins (context-mode + optional caveman) ──
# Plugin install (not raw `mcp add`) so context-mode tools resolve under
# `mcp__plugin_context-mode_context-mode__*` — the namespace slash commands
# (/e2e, /unleash) reference. Raw `mcp add` produces `mcp__context-mode__*`
# which the slash commands cannot find. Caveman stays enabled by default for
# the power-user profile, but --no-caveman keeps private style choices out of
# the merged settings.
if [[ "$INSTALL_CAVEMAN" -eq 1 ]]; then
  echo "→ Installing Claude Code plugins (context-mode, caveman)..."
else
  echo "→ Installing Claude Code plugins (context-mode only; Caveman skipped)..."
fi
if ! command -v claude >/dev/null 2>&1; then
  echo "  ⚠ 'claude' CLI not on PATH. Skip plugin install — install Claude Code first, then run:"
  echo "    claude plugin marketplace add mksglu/context-mode && claude plugin install context-mode@context-mode"
  if [[ "$INSTALL_CAVEMAN" -eq 1 ]]; then
    echo "    claude plugin marketplace add JuliusBrussee/caveman && claude plugin install caveman@caveman"
  fi
else
  claude plugin marketplace add mksglu/context-mode 2>/dev/null \
    || echo "  (run 'claude plugin marketplace add mksglu/context-mode' manually if this failed)"
  claude plugin install context-mode@context-mode 2>/dev/null \
    || echo "  (run 'claude plugin install context-mode@context-mode' manually if this failed)"
  if [[ "$INSTALL_CAVEMAN" -eq 1 ]]; then
    claude plugin marketplace add JuliusBrussee/caveman 2>/dev/null \
      || echo "  (run 'claude plugin marketplace add JuliusBrussee/caveman' manually if this failed)"
    claude plugin install caveman@caveman 2>/dev/null \
      || echo "  (run 'claude plugin install caveman@caveman' manually if this failed)"
  fi
fi

# ── 4. Install tvly CLI (Tavily search/extract) ──
echo "→ Installing tvly CLI..."
if command -v npm >/dev/null 2>&1; then
  npm install -g tavily-cli 2>/dev/null \
    || echo "  ⚠ npm install -g tavily-cli failed — run manually after this script."
else
  echo "  ⚠ npm not found — install Node.js (https://nodejs.org), then 'npm install -g tavily-cli'."
fi
echo "  Export TAVILY_API_KEY in your shell rc (get key at tavily.com)."

# ── Helpers for safe install over an existing setup ──
# cp_with_backup: if target file exists AND differs from source, rename target
# to <name>.bak.<ts> before overwrite. No-op when target is missing or already
# identical. Surfaces user customizations as backups instead of silently nuking.
cp_with_backup() {
  local src="$1"; local dst="$2"
  if [[ -f "$dst" ]] && ! cmp -s "$src" "$dst"; then
    cp "$dst" "$dst.bak.$(date +%s).$$"
  fi
  cp "$src" "$dst"
}

# inject_claude_md: prepend our framework content into ~/.claude/CLAUDE.md
# wrapped in <!--cct--> ... <!--/cct--> markers. Re-runs replace the block in
# place — user's content outside the markers is preserved verbatim.
inject_claude_md() {
  local target="$HOME/.claude/CLAUDE.md"
  local source="$REPO_DIR/CLAUDE.md.example"
  local m_start='<!--cct-->'
  local m_end='<!--/cct-->'

  # Helper: write start marker + source body + always-newline + end marker.
  # Forces a newline before $m_end so the marker lives on its own line, even
  # when $source lacks a trailing newline (otherwise re-run awk can't match it).
  _write_block() {
    echo "$m_start"
    cat "$source"
    # `$(tail -c 1)` strips a trailing \n (command substitution always does),
    # so an EMPTY captured string means the file ends in \n (no echo needed).
    # Anything non-empty means the last byte is non-\n (echo to add one).
    [[ -z "$(tail -c 1 "$source" 2>/dev/null)" ]] || echo
    echo "$m_end"
  }

  if [[ ! -f "$target" ]]; then
    _write_block > "$target"
    echo "  ✓ CLAUDE.md created (wrapped in <!--cct--> markers for future updates)"
    return
  fi

  # Symlink guard: if target is a symlink, refuse to stomp it via `mv` (which
  # would replace the symlink with a regular file and orphan whatever it
  # points at — e.g., a dotfiles-repo file). Resolve to the real path first.
  if [[ -L "$target" ]]; then
    local resolved
    resolved="$(readlink -f "$target" 2>/dev/null || python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$target")"
    echo "  ℹ CLAUDE.md is a symlink → $resolved (editing the real file)"
    target="$resolved"
  fi

  # Orphaned-marker guard: if start marker exists but end marker does NOT,
  # awk would silently drop everything after $m_start. Bail loud instead.
  if grep -qF "$m_start" "$target" && ! grep -qF "$m_end" "$target"; then
    echo "  ✗ CLAUDE.md has <!--cct--> start marker but no <!--/cct--> end marker."
    echo "    Refusing to write — fix manually or delete the start marker. Aborting."
    return 1
  fi

  # Per-invocation backup suffix (epoch seconds + PID) — survives concurrent runs.
  local backup_suffix
  backup_suffix="$(date +%s).$$"

  # Build candidate output to .tmp, only swap (+ backup) if content differs.
  if grep -qF "$m_start" "$target"; then
    awk -v ms="$m_start" -v me="$m_end" -v src="$source" '
      $0 == ms {
        print
        while ((getline line < src) > 0) print line
        close(src)
        # If src lacked trailing newline, last line was still printed (awk adds \n).
        # That is fine — print the end marker on its own line next.
        skip=1; next
      }
      $0 == me { print; skip=0; next }
      !skip { print }
    ' "$target" > "$target.tmp"
    if cmp -s "$target" "$target.tmp"; then
      rm -f "$target.tmp"
      echo "  ✓ CLAUDE.md <!--cct--> block already up to date"
    else
      cp "$target" "$target.bak.$backup_suffix"
      mv "$target.tmp" "$target"
      echo "  ✓ CLAUDE.md <!--cct--> block updated (your content outside markers preserved)"
    fi
  else
    { _write_block; echo ""; cat "$target"; } > "$target.tmp"
    if cmp -s "$target" "$target.tmp"; then
      rm -f "$target.tmp"
      echo "  ✓ CLAUDE.md already up to date"
    else
      cp "$target" "$target.bak.$backup_suffix"
      mv "$target.tmp" "$target"
      echo "  ✓ CLAUDE.md prepended (your existing content kept below <!--cct--> block)"
    fi
  fi
}

# merge_settings_json: deep jq merge. Preserves user model/effortLevel/
# permissions/custom env by default. Replaces the hooks block entirely — we own
# it (the Docker proxy needs no self-healing host hooks, and cct_migrate already
# stripped any legacy headroom-init `ensure` hooks before this runs).
# Unions enabledPlugins + extraKnownMarketplaces, with explicit CLI flags allowed
# to remove Caveman or force the sonnet/high model profile.
# Falls back to plain copy if jq fails.
merge_settings_json() {
  local target="$HOME/.claude/settings.json"
  local source="$SETTINGS_SOURCE"
  local skip_caveman=false
  [[ "$INSTALL_CAVEMAN" -eq 0 ]] && skip_caveman=true

  if [[ ! -f "$target" ]]; then
    cp "$source" "$target"
    echo "  ✓ settings.json created"
    return
  fi

  # Symlink guard: resolve before writing so `mv` doesn't destroy the symlink.
  if [[ -L "$target" ]]; then
    local resolved
    resolved="$(readlink -f "$target" 2>/dev/null || python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$target")"
    echo "  ℹ settings.json is a symlink → $resolved (editing the real file)"
    target="$resolved"
  fi

  local backup_suffix
  backup_suffix="$(date +%s).$$"

  if jq -s --argjson skipCaveman "$skip_caveman" --arg modelProfile "$MODEL_PROFILE" '
    .[0] as $ours | .[1] as $theirs |
    ($ours * $theirs)
    | .hooks = ($ours.hooks // {})
    | .env = (($theirs.env // {}) * ($ours.env // {}))
    | .enabledPlugins = (($theirs.enabledPlugins // {}) * ($ours.enabledPlugins // {}))
    | .extraKnownMarketplaces = (($theirs.extraKnownMarketplaces // {}) * ($ours.extraKnownMarketplaces // {}))
    | .model //= $ours.model
    | .effortLevel //= $ours.effortLevel
    | .advisorModel //= $ours.advisorModel
    | .statusLine //= $ours.statusLine
    | if $skipCaveman then
        del(.enabledPlugins["caveman@caveman"]) | del(.extraKnownMarketplaces.caveman)
      else . end
    | if $modelProfile == "sonnet" then
        .model = "sonnet" | .effortLevel = "high"
      else . end
  ' "$source" "$target" > "$target.tmp" 2>/dev/null; then
    # Canonicalize both via jq -S for stable comparison (jq's `*` operator
    # is not output-byte-stable across runs; sorted-keys form is).
    if diff -q <(jq -S . "$target" 2>/dev/null) <(jq -S . "$target.tmp" 2>/dev/null) >/dev/null 2>&1; then
      rm -f "$target.tmp"
      echo "  ✓ settings.json already up to date"
    else
      cp "$target" "$target.bak.$backup_suffix"
      mv "$target.tmp" "$target"
      if [[ "$MODEL_PROFILE" == "sonnet" ]]; then
        echo "  ✓ settings.json merged (sonnet/high forced by --sonnet; permissions preserved)"
      else
        echo "  ✓ settings.json merged (your model/effortLevel/permissions preserved if set)"
      fi
    fi
  else
    rm -f "$target.tmp"
    cp "$target" "$target.bak.$backup_suffix"
    echo "  ⚠ settings.json jq merge failed — wrote ours, your file is at $target.bak.<ts>"
    cp "$source" "$target"
  fi
}

# ── 5. Copy hooks, commands, rules, bin (per-file backup on conflict) ──
echo "→ Copying hooks, commands, rules, bin (backups for changed files)..."
mkdir -p "$HOME/.claude/hooks" "$HOME/.claude/commands" "$HOME/.claude/rules" "$HOME/.claude/bin"
for src in "$REPO_DIR/hooks/"*; do
  [[ -f "$src" ]] && cp_with_backup "$src" "$HOME/.claude/hooks/$(basename "$src")"
done
for src in "$REPO_DIR/commands/"*; do
  [[ -f "$src" ]] && cp_with_backup "$src" "$HOME/.claude/commands/$(basename "$src")"
done
for src in "$REPO_DIR/rules/"*.md; do
  [[ -f "$src" ]] || continue
  cp_with_backup "$src" "$HOME/.claude/rules/$(basename "$src")"
done
if [[ -d "$REPO_DIR/bin" ]]; then
  for src in "$REPO_DIR/bin/"*; do
    [[ -f "$src" ]] && cp_with_backup "$src" "$HOME/.claude/bin/$(basename "$src")"
  done
fi
chmod +x "$HOME/.claude/hooks/"* "$HOME/.claude/bin/"*.mjs 2>/dev/null || true

# ── 6. Statusline ──
echo "→ Installing statusline..."
cp_with_backup "$REPO_DIR/statusline/statusline-command.sh" "$HOME/.claude/statusline-command.sh"
chmod +x "$HOME/.claude/statusline-command.sh"

# ── 7. CLAUDE.md (prepend in <!--cct--> markers, idempotent on re-run) ──
echo "→ Injecting CLAUDE.md framework block..."
inject_claude_md

# ── 8. settings.json (deep jq merge — preserves user customs) ──
echo "→ Merging settings.json..."
merge_settings_json

# ── 9. Durable Headroom routing (launch-independent) ──
# The proxy is the persistent container from step 1 (--restart unless-stopped,
# so the Docker daemon brings it back at login). "Durable routing" then means
# making `claude` route through it no matter how it's launched — terminal,
# desktop app, or IDE — by writing the provider base URL into Claude Code's
# global settings rather than a shell wrapper that only catches terminal launches.
# We also register the container's HTTP MCP (compress/retrieve/stats at /mcp).
# ~/.local/bin is kept on PATH for the CBM binary (Headroom is no longer a host
# binary, so no claude() function and no host `headroom` CLI are involved).
DURABLE_INSTALLED=""
if [[ "$INSTALL_DURABLE_ROUTING" -eq 1 ]]; then
  echo "→ Setting up durable Headroom routing..."

  # Ensure ~/.local/bin is on PATH in the user's rc (idempotent, no wrapper fn).
  USER_SHELL="$(basename "${SHELL:-/bin/zsh}")"
  case "$USER_SHELL" in
    fish)
      rc="$HOME/.config/fish/config.fish"; mkdir -p "$(dirname "$rc")"; touch "$rc"
      grep -q '.local/bin' "$rc" 2>/dev/null || printf '
# CBM binary lives in ~/.local/bin
if not contains $HOME/.local/bin $PATH
    set -gx PATH $HOME/.local/bin $PATH
end
' >> "$rc"
      ;;
    bash)
      rc="$HOME/.bashrc"; touch "$rc"
      grep -q '.local/bin' "$rc" 2>/dev/null || printf '
# CBM binary lives in ~/.local/bin
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH";; esac
' >> "$rc"
      ;;
    *)
      rc="$HOME/.zshrc"; touch "$rc"
      grep -q '.local/bin' "$rc" 2>/dev/null || printf '
# CBM binary lives in ~/.local/bin
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH";; esac
' >> "$rc"
      ;;
  esac

  if [[ "$HEADROOM_UP" == 1 ]]; then
    # Routing: point Claude Code's provider base URL at the container. Only done
    # once the proxy is confirmed healthy — pinning the base URL to a dead proxy
    # would break ALL Claude Code traffic.
    SETTINGS_FILE="$HOME/.claude/settings.json"
    if command -v jq >/dev/null 2>&1 && [[ -f "$SETTINGS_FILE" ]]; then
      _hr_tmp="$(mktemp)"
      if jq --arg url "http://127.0.0.1:${CCT_HEADROOM_PORT}" \
            '.env = (.env // {}) | .env.ANTHROPIC_BASE_URL = $url' \
            "$SETTINGS_FILE" > "$_hr_tmp" 2>/dev/null && [[ -s "$_hr_tmp" ]]; then
        cp "$SETTINGS_FILE" "$SETTINGS_FILE.cct.bak.$(date +%s)" 2>/dev/null || true
        mv "$_hr_tmp" "$SETTINGS_FILE"
        echo "  ✓ Routed Claude Code through the proxy (ANTHROPIC_BASE_URL in settings.json)"
      else
        rm -f "$_hr_tmp"
        echo "  ⚠ Couldn't write ANTHROPIC_BASE_URL — add this to settings.json env manually:"
        echo "      \"ANTHROPIC_BASE_URL\": \"http://127.0.0.1:${CCT_HEADROOM_PORT}\""
      fi
    fi

    # MCP: newer Headroom proxies auto-expose compress/retrieve/stats at /mcp,
    # but older image tags (the current `:latest` is app-version 0.27.0) don't —
    # they forward unknown paths upstream, which 404s. Registering then would
    # leave a DEAD MCP server in Claude Code. So probe /mcp with a real MCP
    # `initialize` and only register on a 2xx; otherwise drop any stale entry.
    # This auto-enables the tools the day a newer image actually serves /mcp.
    DURABLE_INSTALLED="container routing (settings.json env)"
    mcp_code="$(curl -s -o /dev/null -w '%{http_code}' \
      -X POST "http://127.0.0.1:${CCT_HEADROOM_PORT}/mcp" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"cct","version":"0"}}}' \
      2>/dev/null || echo 000)"
    if command -v claude >/dev/null 2>&1; then
      if [[ "$mcp_code" =~ ^2 ]]; then
        claude mcp remove headroom >/dev/null 2>&1 || true   # idempotent: add errors on dup
        if claude mcp add --transport http --scope user \
             headroom "http://127.0.0.1:${CCT_HEADROOM_PORT}/mcp" >/dev/null 2>&1; then
          echo "  ✓ Registered Headroom MCP (compress/retrieve/stats) at /mcp"
          DURABLE_INSTALLED="$DURABLE_INSTALLED + remote MCP at /mcp"
        else
          echo "  ⚠ 'claude mcp add' failed — register manually:"
          echo "      claude mcp add --transport http --scope user headroom http://127.0.0.1:${CCT_HEADROOM_PORT}/mcp"
        fi
      else
        # Don't leave a dead server behind from a prior run / older image.
        claude mcp remove headroom >/dev/null 2>&1 || true
        echo "  · /mcp not served by this image (HTTP $mcp_code) — skipping MCP registration."
        echo "    Compression proxy is active regardless; MCP auto-enables once the image serves /mcp."
      fi
    fi

    echo "  ✓ Durable routing configured (restart Claude Code to activate)"
  else
    echo "  ⚠ Proxy isn't healthy — skipped routing + MCP wiring. Once the container is up"
    echo "    (re-run install.sh), routing is restored automatically."
  fi
else
  echo "→ Skipping durable Headroom routing (--no-durable-routing)"
  echo "  The proxy container still runs; route per-session with:"
  echo "    ANTHROPIC_BASE_URL=http://127.0.0.1:${CCT_HEADROOM_PORT} claude"
fi

# ── 9b. Record the install manifest so uninstall can be precise.
#        (Upgrade cleanup / cct_migrate already ran before step 1.) ──
echo "→ Recording install manifest..."
set +e
cct_write_manifest
set -e

# ── 10. Validate ──
echo "→ Validating installation..."
if "$REPO_DIR/install.sh" --check >/dev/null 2>&1; then
  echo "  ✓ All hooks, command plugin refs, and bin scripts resolve"
else
  echo "  ⚠ ./install.sh --check reported issues — re-run for details"
fi

echo ""
echo "=== Installation Complete ==="
echo ""
echo "What was installed:"
if [[ "$HEADROOM_UP" == 1 ]]; then
  echo "  ✓ Headroom proxy (Docker container 'headroom-proxy', API-layer compression + MCP)"
else
  echo "  - Headroom proxy NOT running (Docker missing/down) — see warnings above"
fi
echo "  ✓ codebase-memory-mcp (knowledge graph for code)"
echo "  ✓ context-mode plugin (output virtualization)"
if [[ "$INSTALL_CAVEMAN" -eq 1 ]]; then
  echo "  ✓ Caveman plugin (compressed Claude output)"
else
  echo "  - Caveman plugin skipped (--no-caveman)"
fi
echo "  ✓ All enforcement hooks from repo hooks/"
echo "  ✓ All slash commands from repo commands/"
echo "  ✓ Private agent definitions left untouched in ~/.claude/agents/"
echo "  ✓ Stack rules dir created at ~/.claude/rules/ (empty by design — drop your own per rules/README.md)"
echo "  ✓ bin/ helper scripts (sync-copilot, sync-runner-tools)"
echo "  ✓ Custom statusline"
if [[ "$MODEL_PROFILE" == "sonnet" ]]; then
  echo "  ✓ Optimized settings.json (sonnet/high profile)"
else
  echo "  ✓ Optimized settings.json (opus/xhigh power profile)"
fi
if [[ -n "$DURABLE_INSTALLED" ]]; then
  echo "  ✓ Durable routing: $DURABLE_INSTALLED"
else
  echo "  - Durable routing skipped; start claude with: ANTHROPIC_BASE_URL=http://127.0.0.1:${CCT_HEADROOM_PORT} claude"
fi
echo ""
echo "Next steps:"
echo "  1. Restart Claude Code (and your shell) to activate routing: exec \$SHELL"
if [[ "$INSTALL_DURABLE_ROUTING" -eq 1 ]]; then
  echo "  2. Run 'claude' (any launcher) — it now routes through the Headroom proxy automatically"
else
  echo "  2. Run 'ANTHROPIC_BASE_URL=http://127.0.0.1:${CCT_HEADROOM_PORT} claude' for API-layer compression"
fi
echo "     (Docker Desktop must be running — it brings the 'headroom-proxy' container back at login)"
echo "  3. In a project, CBM will prompt to index on first use"
if [[ "$INSTALL_CAVEMAN" -eq 1 ]]; then
  echo "  4. Run '/caveman' to activate compressed output mode"
else
  echo "  4. Caveman skipped; re-run './install.sh' without --no-caveman to add it"
fi
echo "  5. Re-run './install.sh --check' anytime to validate config"
echo ""
echo "Repos:"
echo "  Headroom:  https://github.com/chopratejas/headroom"
echo "  CBM:       https://github.com/DeusData/codebase-memory-mcp"
echo "  ctx-mode:  https://github.com/mksglu/context-mode"
echo "  Caveman:   https://github.com/JuliusBrussee/caveman"
echo "  lean-ctx:  https://github.com/yvgude/lean-ctx"
