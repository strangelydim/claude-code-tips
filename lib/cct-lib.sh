# shellcheck shell=bash
# cct-lib.sh — shared registry + safe primitives for install.sh and uninstall.sh.
#
# Single source of truth for what this repo (and its ancestors) installs into
# Claude Code, organised into COMPONENTS so uninstall.sh can remove one or all.
#
# Safety model
#   * Content/signature-provable items — repo files (by hash), exact settings
#     hook-command substrings, the CLAUDE.md <!--cct--> block, our rc-line
#     blocks, repo-specific deprecated file hashes — are removed directly; their
#     content proves we own them.
#   * AMBIGUOUS shared items — enabled plugins, marketplaces, MCP-server
#     registrations, the Headroom proxy container + its routing env — are
#     removed ONLY when the install manifest proves THIS repo added them. With no
#     manifest, they are LEFT and reported with a manual command, never guessed.
#   * `serena` MCP is NEVER touched (user-managed). Binaries are never removed.
#   * Every settings/CLAUDE.md/rc edit is backed up first; all ops are idempotent
#     and honor CCT_DRY_RUN.

CCT_SCHEMA_VERSION=3
CCT_HEADROOM_HOOK_CMD_SIG="headroom init hook ensure"   # legacy host ensure-hook (pre-v3); stripped on migrate
CCT_MCP_NEVER=(serena)   # user-managed MCP servers we never remove

# Headroom now runs as a Docker container (no host Python). install.sh and the
# daemon remover share these names so ownership/teardown stay in lockstep.
CCT_HEADROOM_IMAGE="${CCT_HEADROOM_IMAGE:-ghcr.io/chopratejas/headroom:latest}"
CCT_HEADROOM_CONTAINER="${CCT_HEADROOM_CONTAINER:-headroom-proxy}"
CCT_HEADROOM_PORT="${CCT_HEADROOM_PORT:-8787}"
CCT_HEADROOM_VOLUME="${CCT_HEADROOM_VOLUME:-headroom-workspace}"

# Paths (overridable for fixture testing) ------------------------------------
CCT_CLAUDE_DIR="${CCT_CLAUDE_DIR:-$HOME/.claude}"
CCT_CLAUDE_JSON="${CCT_CLAUDE_JSON:-$HOME/.claude.json}"
CCT_SETTINGS="$CCT_CLAUDE_DIR/settings.json"
CCT_CLAUDE_MD="$CCT_CLAUDE_DIR/CLAUDE.md"
CCT_MANIFEST="$CCT_CLAUDE_DIR/.cct-manifest.json"
CCT_DRY_RUN="${CCT_DRY_RUN:-0}"
CCT_REPO_DIR="${CCT_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Ordered component list (per stack layer). -----------------------------------
CCT_COMPONENTS=(caveman context-mode cbm lean-ctx headroom hooks commands statusline claude-md rules shell settings)

cct_component_desc() {
  case "$1" in
    caveman)      echo "Caveman plugin + marketplace" ;;
    context-mode) echo "context-mode plugin + marketplace + MCP + its settings hooks" ;;
    cbm)          echo "codebase-memory MCP + cbm-* hooks + settings entries" ;;
    lean-ctx)     echo "lean-ctx hook-rewrite settings entry (+ deprecated rtk leftovers)" ;;
    headroom)     echo "durable routing: Docker proxy container + routing env + remote MCP (+legacy daemon/ensure-hooks)" ;;
    hooks)        echo "enforcement hooks: bash-ban, flutter-ctx, memory-symlink, sync-* (+bin)" ;;
    commands)     echo "slash commands: e2e, e2e-auto, unleash, ship (+deprecated handoff)" ;;
    statusline)   echo "statusline-command.sh + settings.statusLine" ;;
    claude-md)    echo "the <!--cct--> block in CLAUDE.md" ;;
    rules)        echo "rules/README.md template" ;;
    shell)        echo "rc PATH block + deprecated claude() wrapper" ;;
    settings)     echo "framework env keys + model/effort/advisor (gated)" ;;
    *)            echo "(unknown)" ;;
  esac
}

# Deprecated file hashes (git-lineage authoritative; proof-required) ----------
_cct_known_hashes() {
  case "$1" in
    handoff-precompact)     echo "ced08d4a8c036962c4fb5e07609b3ad3d320983c37331e9bcffd528a5ee9e494" ;;
    handoff-session-resume) echo "9eca46c8ae39ccb44de2f4385e96fcb5aa40517cba26266d5cae98f046b0170b" ;;
    handoff.md)             echo "df8e3fd8232a61e4e35d78ee581c2bb7e568c514314e9ef2183aaf0dc56da3eb" ;;
    *)                      echo "" ;;
  esac
}

# ───────────────────────── reporting + primitives ─────────────────────────
CCT_N_REMOVED=0; CCT_N_LEFT=0; CCT_N_WARN=0
_cct_removed() { CCT_N_REMOVED=$((CCT_N_REMOVED+1)); printf '  %s %s\n' "$([ "$CCT_DRY_RUN" = 1 ] && echo '[dry-run] would remove:' || echo '✓ removed:')" "$*"; }
_cct_left()    { CCT_N_LEFT=$((CCT_N_LEFT+1));    printf '  ↳ left (unproven ownership): %s\n' "$*"; }
_cct_warn()    { CCT_N_WARN=$((CCT_N_WARN+1));    printf '  ⚠ %s\n' "$*"; }
_cct_ts()      { date +%s 2>/dev/null || echo 0; }
_cct_sha()     { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }
_cct_backup()  { local f="$1"; [ -f "$f" ] || return 0; [ "$CCT_DRY_RUN" = 1 ] && return 0; cp "$f" "$f.cct.bak.$(_cct_ts).$$" 2>/dev/null || true; }

# jq edit in place: backup + atomic write; returns 2 if no-op, 1 on failure.
_cct_jq_inplace() {
  local f="$1"; shift
  [ -f "$f" ] || return 2
  command -v jq >/dev/null 2>&1 || { _cct_warn "jq missing — cannot edit $f"; return 1; }
  local out; out="$(jq "$@" "$f" 2>/dev/null)" || { _cct_warn "jq failed on $f (left unchanged)"; return 1; }
  [ -n "$out" ] || { _cct_warn "jq produced empty output for $f (left unchanged)"; return 1; }
  if diff -q <(jq -S . "$f" 2>/dev/null) <(printf '%s' "$out" | jq -S . 2>/dev/null) >/dev/null 2>&1; then return 2; fi
  [ "$CCT_DRY_RUN" = 1 ] && return 0
  _cct_backup "$f"; printf '%s\n' "$out" > "$f.cct.tmp.$$" && mv "$f.cct.tmp.$$" "$f"
}

# manifest ownership ----------------------------------------------------------
cct_manifest_present() { [ -f "$CCT_MANIFEST" ]; }
cct_manifest_owns() {  # <list-key> <id>
  cct_manifest_present || return 1
  jq -e --arg id "$2" --arg k "$1" '(.added[$k] // []) | index($id)' "$CCT_MANIFEST" >/dev/null 2>&1
}
cct_manifest_owns_daemon() { cct_manifest_present && jq -e '.added.headroom_daemon == true' "$CCT_MANIFEST" >/dev/null 2>&1; }

# ── hook stripping: accumulate owned signatures, flush in ONE pass ──
# Filters at .hooks[].command granularity, then prunes hook-entries left with no
# inner hooks, then prunes event arrays left empty. Co-bundled user hooks survive.
_CCT_SIG_ACC=""
cct_acc_sig() { _CCT_SIG_ACC="${_CCT_SIG_ACC}${1}"$'\n'; }
_CCT_HOOK_STRIP_JQ='
  def owned($c): ($c|type=="string") and (any($sigs[]; . as $s | $c|contains($s)));
  .hooks = ((.hooks // {})
    | with_entries(.value = ((.value // [])
        | map(.hooks = ((.hooks // []) | map(select(owned(.command) | not))))
        | map(select((.hooks // []) | length > 0))))
    | with_entries(select((.value // []) | length > 0)))
'
cct_flush_hooks() {
  [ -n "$_CCT_SIG_ACC" ] || return 0
  [ -f "$CCT_SETTINGS" ] || return 0
  local sigs; sigs="$(printf '%s' "$_CCT_SIG_ACC" | grep -v '^$' | jq -R . | jq -s .)"
  _cct_jq_inplace "$CCT_SETTINGS" "$_CCT_HOOK_STRIP_JQ" --argjson sigs "$sigs"
  case $? in 0) _cct_removed "matching hook entries in settings.json" ;; esac
  _CCT_SIG_ACC=""
}

# file removal ----------------------------------------------------------------
# repo-owned: remove iff on-disk byte-matches the repo's copy.
cct_remove_repo_file() {  # <abs-path> <repo-relative-path>
  local dst="$1" src="$CCT_REPO_DIR/$2"
  [ -f "$dst" ] || return 0
  if [ -f "$src" ] && [ "$(_cct_sha "$dst")" = "$(_cct_sha "$src")" ]; then
    [ "$CCT_DRY_RUN" = 1 ] || rm -f "$dst"
    _cct_removed "$dst"
  else
    _cct_warn "left $dst — differs from repo copy (you may have edited it); remove manually if desired"
  fi
}
# deprecated: remove iff on-disk matches a known historical hash.
cct_remove_deprecated_file() {  # <abs-path> <basename-for-hash-lookup>
  local dst="$1" name="$2"
  [ -f "$dst" ] || return 0
  local known; known="$(_cct_known_hashes "$name")"
  if [ -n "$known" ] && [ "$(_cct_sha "$dst")" = "$known" ]; then
    [ "$CCT_DRY_RUN" = 1 ] || rm -f "$dst"
    _cct_removed "$dst (deprecated)"
  else
    _cct_warn "left $dst — deprecated artifact, but content doesn't match a known hash; remove manually if it's yours"
  fi
}

# gated settings/json removals ------------------------------------------------
cct_remove_plugin() {     # <plugin-key>
  cct_manifest_owns plugins "$1" || { _cct_left "plugin $1 (manual: edit enabledPlugins / claude plugin uninstall)"; return 0; }
  _cct_jq_inplace "$CCT_SETTINGS" 'del(.enabledPlugins[$p])' --arg p "$1" && _cct_removed "plugin $1"
}
cct_remove_marketplace() {  # <marketplace-key>
  cct_manifest_owns marketplaces "$1" || { _cct_left "marketplace $1"; return 0; }
  _cct_jq_inplace "$CCT_SETTINGS" 'del(.extraKnownMarketplaces[$m])' --arg m "$1" && _cct_removed "marketplace $1"
}
cct_remove_mcp() {        # <mcp-name>
  case " ${CCT_MCP_NEVER[*]} " in *" $1 "*) return 0 ;; esac   # never serena
  cct_manifest_owns mcp "$1" || { _cct_left "MCP server $1 (manual: claude mcp remove $1)"; return 0; }
  _cct_jq_inplace "$CCT_CLAUDE_JSON" 'if .mcpServers then .mcpServers |= del(.[$n]) else . end
      | if .projects then .projects |= with_entries(.value.mcpServers |= (if . then del(.[$n]) else . end)) else . end' \
    --arg n "$1" && _cct_removed "MCP server $1"
}
cct_remove_env_key() {    # <env-key>
  cct_manifest_owns env "$1" || { _cct_left "env $1 in settings.json"; return 0; }
  _cct_jq_inplace "$CCT_SETTINGS" 'if .env then .env |= del(.[$k]) else . end' --arg k "$1" && _cct_removed "env $1"
}
cct_remove_setting_key() {  # <top-level key> (gated)
  cct_manifest_owns settings_keys "$1" || { _cct_left "settings.$1"; return 0; }
  _cct_jq_inplace "$CCT_SETTINGS" 'del(.[$k])' --arg k "$1" && _cct_removed "settings.$1"
}

# Headroom proxy container (gated) --------------------------------------------
# The proxy is a Docker container install.sh created. We force-remove the
# container but deliberately LEAVE its named volume ($CCT_HEADROOM_VOLUME) —
# that holds savings/stats data, which a binary/data item we never delete.
cct_remove_headroom_daemon() {
  cct_manifest_owns_daemon || { _cct_left "Headroom proxy container (manual: docker rm -f $CCT_HEADROOM_CONTAINER)"; return 0; }
  if [ "$CCT_DRY_RUN" = 1 ]; then _cct_removed "Headroom proxy container (docker rm -f $CCT_HEADROOM_CONTAINER; volume $CCT_HEADROOM_VOLUME kept)"; return 0; fi
  command -v docker >/dev/null 2>&1 && docker rm -f "$CCT_HEADROOM_CONTAINER" >/dev/null 2>&1 || true
  _cct_removed "Headroom proxy container (volume $CCT_HEADROOM_VOLUME kept)"
}

# rc-file line/block removal --------------------------------------------------
# Removes a line matching PATTERN and an immediately-preceding comment line.
cct_rc_remove() {  # <rc-file> <grep-ERE-pattern> <label>
  local rc="$1" pat="$2" label="$3"
  [ -f "$rc" ] || return 0
  grep -qE "$pat" "$rc" 2>/dev/null || return 0
  if [ "$CCT_DRY_RUN" = 1 ]; then _cct_removed "$label in $rc"; return 0; fi
  _cct_backup "$rc"
  awk -v pat="$pat" '
    { lines[NR]=$0 }
    END {
      for (i=1;i<=NR;i++) drop[i]=0
      for (i=1;i<=NR;i++) if (lines[i] ~ pat) { drop[i]=1; if (i>1 && lines[i-1] ~ /^[[:space:]]*#/) drop[i-1]=1 }
      for (i=1;i<=NR;i++) if (!drop[i]) print lines[i]
    }' "$rc" > "$rc.cct.tmp.$$" && mv "$rc.cct.tmp.$$" "$rc"
  _cct_removed "$label in $rc"
}

# ───────────────────────── component removers ─────────────────────────
cct_comp_caveman() {
  cct_remove_plugin "caveman@caveman"; cct_remove_marketplace "caveman"
}
cct_comp_context_mode() {
  cct_acc_sig "context-mode hook claude-code"
  cct_remove_plugin "context-mode@context-mode"; cct_remove_marketplace "context-mode"
  cct_remove_mcp "context-mode"
}
cct_comp_cbm() {
  local h; for h in cbm-code-discovery-gate cbm-mcp-marker cbm-session-reminder; do
    cct_acc_sig "/hooks/$h"; cct_remove_repo_file "$CCT_CLAUDE_DIR/hooks/$h" "hooks/$h"
  done
  cct_remove_mcp "codebase-memory-mcp"
}
cct_comp_lean_ctx() {
  cct_acc_sig "lean-ctx hook rewrite"
  # deprecated rtk leftovers (settings entries by signature; file by hash)
  cct_acc_sig "rtk hook claude"; cct_acc_sig "/hooks/rtk-rewrite.sh"
  cct_remove_deprecated_file "$CCT_CLAUDE_DIR/hooks/rtk-rewrite.sh" "rtk-rewrite.sh"
}
cct_comp_headroom() {
  if cct_manifest_owns_daemon; then cct_acc_sig "$CCT_HEADROOM_HOOK_CMD_SIG"; fi
  cct_remove_headroom_daemon
  local k; for k in ANTHROPIC_BASE_URL ENABLE_TOOL_SEARCH; do cct_remove_env_key "$k"; done
  cct_remove_plugin "headroom@headroom-marketplace"; cct_remove_marketplace "headroom-marketplace"
  cct_remove_mcp "headroom"
}
cct_comp_hooks() {
  local h; for h in bash-ban-raw-tools flutter-ctx-redirect memory-repo-symlink sync-copilot-on-edit sync-runner-tools-on-edit; do
    cct_acc_sig "/hooks/$h"; cct_remove_repo_file "$CCT_CLAUDE_DIR/hooks/$h" "hooks/$h"
  done
  cct_remove_repo_file "$CCT_CLAUDE_DIR/bin/sync-copilot.mjs" "bin/sync-copilot.mjs"
  cct_remove_repo_file "$CCT_CLAUDE_DIR/bin/sync-runner-tools.mjs" "bin/sync-runner-tools.mjs"
  # deprecated handoff hooks (file by hash; settings entries by signature)
  cct_acc_sig "/hooks/handoff-precompact"; cct_acc_sig "/hooks/handoff-session-resume"
  cct_remove_deprecated_file "$CCT_CLAUDE_DIR/hooks/handoff-precompact" "handoff-precompact"
  cct_remove_deprecated_file "$CCT_CLAUDE_DIR/hooks/handoff-session-resume" "handoff-session-resume"
}
cct_comp_commands() {
  local c; for c in e2e.md e2e-auto.md unleash.md ship.md; do
    cct_remove_repo_file "$CCT_CLAUDE_DIR/commands/$c" "commands/$c"
  done
  cct_remove_deprecated_file "$CCT_CLAUDE_DIR/commands/handoff.md" "handoff.md"
}
cct_comp_statusline() {
  local f="$CCT_CLAUDE_DIR/statusline-command.sh" src="$CCT_REPO_DIR/statusline/statusline-command.sh" ours=0
  [ -f "$f" ] && [ -f "$src" ] && [ "$(_cct_sha "$f")" = "$(_cct_sha "$src")" ] && ours=1
  cct_remove_repo_file "$f" "statusline/statusline-command.sh"
  # The settings.statusLine pointer is content-provable (it names our script), so
  # remove it ungated — but only when the file was ours, never a user's custom one.
  if [ "$ours" = 1 ] && [ -f "$CCT_SETTINGS" ] && jq -e '(.statusLine.command // "") | contains("statusline-command.sh")' "$CCT_SETTINGS" >/dev/null 2>&1; then
    _cct_jq_inplace "$CCT_SETTINGS" 'del(.statusLine)' >/dev/null 2>&1 && _cct_removed "settings.statusLine"
  fi
}
cct_comp_claude_md() { cct_remove_claude_md_block; }
cct_comp_rules() { cct_remove_repo_file "$CCT_CLAUDE_DIR/rules/README.md" "rules/README.md"; }
cct_comp_shell() {
  local rc; for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.config/fish/config.fish"; do
    cct_rc_remove "$rc" 'headroom wrap claude' "deprecated claude() wrapper"
    cct_rc_remove "$rc" 'CBM.*binar.*live' "PATH-ensure block"
  done
}
cct_comp_settings() {
  local k; for k in CLAUDE_CODE_DISABLE_BACKGROUND_TASKS CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS \
    ENABLE_PROMPT_CACHING_1H BASH_MAX_OUTPUT_LENGTH MAX_MCP_OUTPUT_TOKENS \
    ANTHROPIC_DEFAULT_OPUS_MODEL CLAUDE_AUTOCOMPACT_PCT_OVERRIDE CLAUDE_CODE_SUBAGENT_MODEL; do
    cct_remove_env_key "$k"
  done
  for k in model effortLevel advisorModel; do cct_remove_setting_key "$k"; done
}

# CLAUDE.md <!--cct--> block remover -----------------------------------------
cct_remove_claude_md_block() {
  local f="$CCT_CLAUDE_MD"
  [ -f "$f" ] || return 0
  grep -qF '<!--cct-->' "$f" 2>/dev/null || return 0
  grep -qF '<!--/cct-->' "$f" 2>/dev/null || { _cct_warn "CLAUDE.md has start marker but no end marker — left untouched"; return 0; }
  if [ "$CCT_DRY_RUN" = 1 ]; then _cct_removed "<!--cct--> block in CLAUDE.md"; return 0; fi
  _cct_backup "$f"
  awk 'BEGIN{skip=0} /<!--cct-->/{skip=1;next} /<!--\/cct-->/{skip=0;next} !skip{print}' "$f" > "$f.cct.tmp.$$" && mv "$f.cct.tmp.$$" "$f"
  _cct_removed "<!--cct--> block in CLAUDE.md"
}

# Dispatch a single component by name.
cct_run_component() {
  case "$1" in
    caveman) cct_comp_caveman ;; context-mode) cct_comp_context_mode ;;
    cbm) cct_comp_cbm ;; lean-ctx) cct_comp_lean_ctx ;; headroom) cct_comp_headroom ;;
    hooks) cct_comp_hooks ;; commands) cct_comp_commands ;; statusline) cct_comp_statusline ;;
    claude-md) cct_comp_claude_md ;; rules) cct_comp_rules ;; shell) cct_comp_shell ;;
    settings) cct_comp_settings ;;
    *) _cct_warn "unknown component: $1" ;;
  esac
}

# ───────────────────────── install-side: migrations + manifest ─────────────
# These are consumed by install.sh (set -e); install.sh wraps calls in set +e
# because the removal primitives use non-zero returns to signal "no-op".
CCT_BASELINE="$CCT_CLAUDE_DIR/.cct-baseline.json"

# Schema version recorded by the last install (0 if none / pre-manifest).
cct_installed_version() { if cct_manifest_present; then jq -r '.schema // 0' "$CCT_MANIFEST" 2>/dev/null || echo 0; else echo 0; fi; }

# Upgrade cleanup: remove artifacts deprecated up to the current schema version.
# Pure idempotent signature/hash removals — safe to run on every install.
cct_migrate() {  # <from_version>
  local from="${1:-0}"
  [ "$from" -lt 2 ] && _cct_migrate_v2
  [ "$from" -lt 3 ] && _cct_migrate_v3
  return 0
}
_cct_migrate_v3() {  # v2 -> v3: retire host Headroom (pipx + launchd) for the Docker proxy
  # A previous version ran a launchd Headroom daemon on port 8787; retire it so
  # the container's `docker run -p 8787` doesn't collide. This needs the legacy
  # host CLI — absent on a Docker-only machine, where there's nothing to free.
  if command -v headroom >/dev/null 2>&1; then
    if [ "${CCT_DRY_RUN:-0}" = 1 ]; then _cct_removed "legacy host Headroom launchd daemon (headroom install remove)"
    else headroom install remove >/dev/null 2>&1 || true; _cct_removed "legacy host Headroom launchd daemon (freed port $CCT_HEADROOM_PORT)"; fi
  fi
  # The old `headroom init --global claude` injected self-healing ensure-hooks
  # into settings.json; the Docker proxy needs none, so strip them.
  cct_acc_sig "$CCT_HEADROOM_HOOK_CMD_SIG"; cct_flush_hooks
  return 0
}
_cct_migrate_v2() {  # v1 -> v2: rtk -> lean-ctx, shell wrapper -> durable routing, handoff retired
  cct_acc_sig "rtk hook claude"; cct_acc_sig "/hooks/rtk-rewrite.sh"
  cct_acc_sig "/hooks/handoff-precompact"; cct_acc_sig "/hooks/handoff-session-resume"
  cct_flush_hooks
  cct_remove_deprecated_file "$CCT_CLAUDE_DIR/hooks/rtk-rewrite.sh" "rtk-rewrite.sh"
  cct_remove_deprecated_file "$CCT_CLAUDE_DIR/hooks/handoff-precompact" "handoff-precompact"
  cct_remove_deprecated_file "$CCT_CLAUDE_DIR/hooks/handoff-session-resume" "handoff-session-resume"
  cct_remove_deprecated_file "$CCT_CLAUDE_DIR/commands/handoff.md" "handoff.md"
  local rc; for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.config/fish/config.fish"; do
    cct_rc_remove "$rc" 'headroom wrap claude' "deprecated claude() wrapper"
  done
  return 0
}

_cct_daemon_running() { command -v docker >/dev/null 2>&1 && [ "$(docker inspect -f '{{.State.Running}}' "$CCT_HEADROOM_CONTAINER" 2>/dev/null)" = "true" ]; }
_cct_jq_or() { local d="$1"; shift; local o; o="$(jq -c "$@" 2>/dev/null)"; [ -n "$o" ] && printf '%s' "$o" || printf '%s' "$d"; }

# Capture a one-time, sticky baseline of pre-existing ambiguous items, taken
# BEFORE install mutates anything, so the manifest can compute added = now\baseline.
cct_capture_baseline() {
  [ "$CCT_DRY_RUN" = 1 ] && return 0
  cct_manifest_present && return 0
  [ -f "$CCT_BASELINE" ] && return 0
  mkdir -p "$CCT_CLAUDE_DIR"
  local p m e k c d
  p="$(_cct_jq_or '[]' '(.enabledPlugins//{})|keys' "$CCT_SETTINGS")"
  m="$(_cct_jq_or '[]' '(.extraKnownMarketplaces//{})|keys' "$CCT_SETTINGS")"
  e="$(_cct_jq_or '[]' '(.env//{})|keys' "$CCT_SETTINGS")"
  k="$(_cct_jq_or '[]' '[keys[]?]' "$CCT_SETTINGS")"
  c="$(_cct_jq_or '[]' '[((.mcpServers//{})|keys[]?),((.projects//{})|to_entries[]?|(.value.mcpServers//{})|keys[]?)]|unique' "$CCT_CLAUDE_JSON")"
  d=false; _cct_daemon_running && d=true
  jq -n --argjson p "$p" --argjson m "$m" --argjson e "$e" --argjson k "$k" --argjson c "$c" --argjson d "$d" \
    '{plugins:$p,marketplaces:$m,env:$e,keys:$k,mcp:$c,daemon:$d}' > "$CCT_BASELINE" 2>/dev/null || true
}

# Write/refresh the manifest: added = (current ∩ our-known) \ baseline.
cct_write_manifest() {
  [ "$CCT_DRY_RUN" = 1 ] && return 0
  command -v jq >/dev/null 2>&1 || return 0
  local base='{"plugins":[],"marketplaces":[],"env":[],"keys":[],"mcp":[],"daemon":false}'
  [ -f "$CCT_BASELINE" ] && base="$(cat "$CCT_BASELINE" 2>/dev/null || printf '%s' "$base")"
  local cp cm ce ck cc dn
  cp="$(_cct_jq_or '[]' '(.enabledPlugins//{})|keys' "$CCT_SETTINGS")"
  cm="$(_cct_jq_or '[]' '(.extraKnownMarketplaces//{})|keys' "$CCT_SETTINGS")"
  ce="$(_cct_jq_or '[]' '(.env//{})|keys' "$CCT_SETTINGS")"
  ck="$(_cct_jq_or '[]' '[keys[]?]' "$CCT_SETTINGS")"
  cc="$(_cct_jq_or '[]' '[((.mcpServers//{})|keys[]?),((.projects//{})|to_entries[]?|(.value.mcpServers//{})|keys[]?)]|unique' "$CCT_CLAUDE_JSON")"
  dn=false; _cct_daemon_running && dn=true
  jq -n --argjson base "$base" --argjson schema "$CCT_SCHEMA_VERSION" \
    --argjson cp "$cp" --argjson cm "$cm" --argjson ce "$ce" --argjson ck "$ck" --argjson cc "$cc" --argjson dn "$dn" \
    --argjson kp '["context-mode@context-mode","caveman@caveman","headroom@headroom-marketplace"]' \
    --argjson km '["context-mode","caveman","headroom-marketplace"]' \
    --argjson kc '["codebase-memory-mcp","context-mode","headroom"]' \
    --argjson ke '["ANTHROPIC_BASE_URL","ENABLE_TOOL_SEARCH","ANTHROPIC_DEFAULT_OPUS_MODEL","CLAUDE_CODE_DISABLE_BACKGROUND_TASKS","CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS","ENABLE_PROMPT_CACHING_1H","BASH_MAX_OUTPUT_LENGTH","MAX_MCP_OUTPUT_TOKENS","CLAUDE_AUTOCOMPACT_PCT_OVERRIDE","CLAUDE_CODE_SUBAGENT_MODEL"]' \
    --argjson kk '["model","effortLevel","advisorModel","statusLine"]' '
    def added($cur;$known;$baseline): [ $cur[] | . as $x | select((($known|index($x))!=null) and ((($baseline//[])|index($x))==null)) ];
    {schema:$schema, added:{
      plugins: added($cp;$kp;$base.plugins),
      marketplaces: added($cm;$km;$base.marketplaces),
      mcp: added($cc;$kc;$base.mcp),
      env: added($ce;$ke;$base.env),
      settings_keys: added($ck;$kk;($base.keys // [])),
      headroom_daemon: ($dn and (($base.daemon // false)|not))
    }}' > "$CCT_MANIFEST" 2>/dev/null || true
}
