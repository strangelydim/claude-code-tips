#!/bin/bash
set -uo pipefail
# uninstall.sh — safely remove the plumbing install.sh wired into Claude Code.
#
# SAFE BY DEFAULT: runs as a DRY-RUN unless you pass --apply. Only removes what
# this repo (and its ancestors) installed; anything you added or edited is left
# and reported. Ownership-ambiguous shared items (plugins, marketplaces, MCP
# servers, the Headroom proxy) are removed only when the install manifest proves
# we added them — otherwise left with a manual command. Idempotent.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CCT_REPO_DIR="$REPO_DIR"
# shellcheck source=lib/cct-lib.sh
. "$REPO_DIR/lib/cct-lib.sh"

print_usage() {
  cat <<EOF
uninstall.sh — remove the Claude Code plumbing this repo installed (safely).

Usage:
  ./uninstall.sh [--apply] [component flags...]

Modes:
  (no flags)            DRY-RUN of a FULL uninstall (shows what would change).
  --apply               Actually perform removals (backs up every edited file).
  --dry-run             Force dry-run even with --apply.
  --list                List components and exit.
  -h, --help            This help.

Component flags (additive — pick any; none = all):
$(for c in "${CCT_COMPONENTS[@]}"; do printf '  --%-13s %s\n' "$c" "$(cct_component_desc "$c")"; done)

Notes:
  * Binaries (lean-ctx, Headroom, CBM, jq, tvly) are never removed — only plumbing.
  * serena MCP is never touched (user-managed).
  * Override target dir for testing with CCT_CLAUDE_DIR / CCT_CLAUDE_JSON.
EOF
}

SELECTED=()
APPLY=0
FORCE_DRY=0
valid_component() { local c; for c in "${CCT_COMPONENTS[@]}"; do [ "$c" = "$1" ] && return 0; done; return 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --dry-run) FORCE_DRY=1; shift ;;
    --list) for c in "${CCT_COMPONENTS[@]}"; do printf '  %-13s %s\n' "$c" "$(cct_component_desc "$c")"; done; exit 0 ;;
    -h|--help) print_usage; exit 0 ;;
    --*)
      comp="${1#--}"
      if valid_component "$comp"; then SELECTED+=("$comp"); shift
      else echo "Unknown flag/component: $1" >&2; print_usage >&2; exit 2; fi
      ;;
    *) echo "Unexpected argument: $1" >&2; print_usage >&2; exit 2 ;;
  esac
done

# Dry-run unless --apply; --dry-run always wins.
if [ "$APPLY" = 1 ] && [ "$FORCE_DRY" = 0 ]; then CCT_DRY_RUN=0; else CCT_DRY_RUN=1; fi
export CCT_DRY_RUN

# No component flags → all.
if [ "${#SELECTED[@]}" -eq 0 ]; then SELECTED=("${CCT_COMPONENTS[@]}"); SCOPE="full"; else SCOPE="components: ${SELECTED[*]}"; fi

echo "=== claude-code-tips uninstall ==="
echo "Target:   $CCT_CLAUDE_DIR  (mcp: $CCT_CLAUDE_JSON)"
echo "Scope:    $SCOPE"
if [ "$CCT_DRY_RUN" = 1 ]; then echo "Mode:     DRY-RUN (no changes will be made — re-run with --apply to perform them)"; else echo "Mode:     APPLY (files edited will be backed up to <file>.cct.bak.<ts>)"; fi
if cct_manifest_present; then echo "Manifest: present — ambiguous shared items removed precisely"; else echo "Manifest: absent — ambiguous shared items (plugins/marketplaces/MCP/daemon) will be LEFT + reported"; fi
echo ""

# Run components in canonical order (intersect with selection), accumulating
# hook signatures, then flush the settings hook-strip in a single pass.
for c in "${CCT_COMPONENTS[@]}"; do
  for s in "${SELECTED[@]}"; do
    if [ "$c" = "$s" ]; then
      echo "→ $c — $(cct_component_desc "$c")"
      cct_run_component "$c"
      break
    fi
  done
done
echo "→ applying settings.json hook removals"
cct_flush_hooks

# If a full uninstall actually applied, drop the manifest last (it described the
# install we just removed). Partial uninstalls leave it.
if [ "$SCOPE" = "full" ] && [ "$CCT_DRY_RUN" = 0 ]; then
  [ -f "$CCT_MANIFEST" ] && rm -f "$CCT_MANIFEST" && echo "  ✓ removed install manifest"
  [ -f "$CCT_BASELINE" ] && rm -f "$CCT_BASELINE" && echo "  ✓ removed install baseline"
fi

echo ""
echo "=== summary ==="
echo "  removed/queued: $CCT_N_REMOVED   left (unproven): $CCT_N_LEFT   warnings: $CCT_N_WARN"
if [ "$CCT_DRY_RUN" = 1 ]; then
  echo "  This was a DRY-RUN. Re-run with --apply to perform these changes."
fi
if [ "$CCT_N_LEFT" -gt 0 ] && ! cct_manifest_present; then
  echo "  Items left for safety had no install manifest to prove ownership. If you're"
  echo "  certain they're yours to remove, use the manual commands shown above."
fi
exit 0
