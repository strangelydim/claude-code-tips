# Claude Code Token-Optimisation Stack

> **Fork note.** This is a fork of [sgaabdu4/claude-code-tips](https://github.com/sgaabdu4/claude-code-tips) with a few different defaults:
> - Uses **[lean-ctx](https://github.com/yvgude/lean-ctx)** instead of RTK for CLI compression — both as Headroom's context tool and as the command-rewriting PreToolUse hook.
> - Runs **Headroom as a Docker container** (`ghcr.io/chopratejas/headroom:latest`) — no host Python — and sets up **durable routing** (provider base URL written into `settings.json` + the container's MCP tools registered over HTTP) instead of a shell-function wrapper, so `claude` routes through the proxy no matter how it's launched (terminal, desktop app, IDE).
> - Does **not** use Caveman — install with `./install.sh --no-caveman`.
>
> The long-form post in [`claude-code-tips.md`](./claude-code-tips.md) still describes the original RTK-based stack.

Configs + hooks + scripts for Medium post: **"How I Cut Claude Code Token Usage by 90%+"**.

This repo is intentionally a **power-user default**: it assumes you want aggressive token control, enforcement hooks, and durable Headroom routing. If you want the full stack, run the default installer. If you want less global surface area, use the opt-out flags below.

Post: [`claude-code-tips.md`](./claude-code-tips.md)

Stack: **CBM** (code graph) + **context-mode** (output sandbox) + **lean-ctx** (shell compression) + **Headroom** (API-layer) + **Caveman** (Claude output) + enforcement hooks. ~30min → 3h+ sessions, same 200K window.

## Install

```bash
git clone https://github.com/strangelydim/claude-code-tips.git
cd claude-code-tips && chmod +x install.sh && ./install.sh --no-caveman
```

**Prerequisite:** [Docker](https://www.docker.com/products/docker-desktop/) — Headroom runs as a container, so the stack has no host-Python dependency. Make sure Docker Desktop starts at login; the proxy container runs with `--restart unless-stopped`, so the Docker daemon brings it back automatically. If Docker isn't running, install.sh skips Headroom (everything else still installs) and you re-run once Docker is up.

Sanity-checks `git`/`curl`/`jq` upfront. Pulls and runs the Headroom proxy container (`ghcr.io/chopratejas/headroom:latest`, published on `127.0.0.1:8787`, state persisted in a `headroom-workspace` volume), plus lean-ctx, the CBM binary, context-mode (and Caveman unless `--no-caveman`) plugins via `claude plugin install`, hooks, slash commands, statusline, settings, and durable Headroom routing (provider base URL in `settings.json` + the container's compress/retrieve/stats MCP tools registered over HTTP at `/mcp`). **Idempotent** — re-run anytime; an already-current, healthy proxy is left as-is.

### Power-user flags

Default stays maximal. These flags narrow blast radius without editing the script:

```bash
./install.sh --no-durable-routing # run the proxy container, but don't wire global routing
./install.sh --no-caveman         # skip Caveman plugin + omit it from settings
./install.sh --sonnet             # use model: sonnet + effortLevel: high
./install.sh --check              # validate repo wiring only
```

`--no-durable-routing` is the safer alternative to skipping Headroom entirely: the proxy container still runs, but nothing is written into your global config — you opt into API-layer compression per session by launching `ANTHROPIC_BASE_URL=http://127.0.0.1:8787 claude` instead of having the base URL wired into `settings.json`.

### Existing setup? Don't worry

- `~/.claude/CLAUDE.md` — your content preserved. Our framework is prepended inside `<!--cct-->`/`<!--/cct-->` markers. Re-runs replace inside markers; everything outside untouched.
- `~/.claude/settings.json` — `jq` deep merge. Your `model` / `effortLevel` / `permissions` / custom env keys preserved. Our `hooks` and framework env added.
- `~/.claude/{hooks,commands,rules,bin}/*` — per-file: if a target exists and differs from ours, renamed to `<name>.bak.<timestamp>` before overwrite. Identical files: no-op.
- `~/.claude/agents/*` — intentionally untouched. Keep your private subagent definitions outside this public repo.

### Validate

```bash
./install.sh --check
```

Walks `settings.json`, asserts every hook command path resolves on disk, every `mcp__plugin_*` reference in commands has a matching `enabledPlugins` entry, every `bin/` script referenced by a hook exists. Catches "hook referenced but not installed" forever.

## Uninstall

Reverses the plumbing `install.sh` wired into Claude Code — **safely**. Dry-run by default; pass `--apply` to actually change anything.

```bash
./uninstall.sh                 # DRY-RUN of a full uninstall (shows what would change)
./uninstall.sh --apply         # full uninstall (every edited file is backed up first)
./uninstall.sh --caveman --apply   # uninstall ONLY caveman (+ everything related); leave the rest
./uninstall.sh --list          # list components
```

Safety model:
- **Only removes what this repo installed.** Repo files are matched by content hash; settings hook-entries by exact command; the `<!--cct-->` block by its markers. Anything you added or edited (your own hooks, plugins, env keys, files) is **left and reported**. `serena` MCP is never touched; binaries (lean-ctx, Headroom, CBM) are never removed — only the plumbing.
- **Ambiguous shared items** (plugins, marketplaces, MCP servers, the Headroom proxy) are removed only when the install manifest proves *this repo* added them; otherwise they're left with a manual command. (Installs predating the manifest therefore keep those — by design.)
- **Idempotent**, backs up every edited file to `<file>.cct.bak.<ts>`, and supports additive component flags (`--caveman`, `--context-mode`, `--cbm`, `--lean-ctx`, `--headroom`, `--hooks`, `--commands`, `--statusline`, `--claude-md`, `--rules`, `--shell`, `--settings`; none = all).

`install.sh` is also an **upgrader**: re-running a newer version writes an install manifest, records what it added, and auto-removes artifacts a previous version deprecated (old `rtk` hook, the legacy `claude()` shell wrapper, the retired handoff hooks). The shared registry lives in [`lib/cct-lib.sh`](./lib/cct-lib.sh).

## Layout

| Path | Purpose |
|---|---|
| [`install.sh`](./install.sh) | One-click power-user install. Supports `--check`, `--no-durable-routing`, `--no-caveman`, and `--sonnet`. |
| [`settings/settings.json`](./settings/settings.json) | `~/.claude/settings.json` — model, effort, hooks, env, plugins, statusline |
| [`CLAUDE.md.example`](./CLAUDE.md.example) | Body of `~/.claude/CLAUDE.md` — rules + tool routing. Wrapped in `<!--cct-->` markers when installed |
| [`hooks/`](./hooks/) | All enforcement hooks (cbm-*, bash-ban-raw-tools, sync-*-on-edit, flutter-ctx-redirect, memory-repo-symlink) |
| [`commands/`](./commands/) | Slash commands (`/e2e`, `/e2e-auto`, `/unleash`, `/ship`) |
| [`rules/`](./rules/) | **Empty by design** — your stack-specific rules. See [`rules/README.md`](./rules/README.md) for the template |
| [`bin/`](./bin/) | Helper scripts (`sync-copilot.mjs`, `sync-runner-tools.mjs`) referenced by hooks |
| [`statusline/statusline-command.sh`](./statusline/statusline-command.sh) | Statusline — user, branch, model, ctx%, 5h/7d usage |

Subagent definitions are private by design. The commands can call local agents from `~/.claude/agents/`, but this repo does not ship or overwrite them.

## Hook map

```
durable routing         claude → Headroom proxy container (ANTHROPIC_BASE_URL in settings.json + headroom MCP at http://127.0.0.1:8787/mcp)
PreToolUse(Bash)        context-mode + bash-ban-raw-tools + flutter-ctx-redirect + lean-ctx
PreToolUse(Grep|...)    cbm-code-discovery-gate
PostToolUse             context-mode + cbm-mcp-marker
PostToolUse(Edit|Write) sync-copilot-on-edit + sync-runner-tools-on-edit
PreCompact              context-mode
SessionStart            context-mode + memory-repo-symlink + cbm-session-reminder
```

## Externals (auto-installed by `install.sh`)

| Tool | Repo |
|---|---|
| Headroom (API-layer proxy) | https://github.com/chopratejas/headroom |
| codebase-memory-mcp | https://github.com/DeusData/codebase-memory-mcp |
| context-mode plugin | https://github.com/mksglu/context-mode |
| Caveman plugin | https://github.com/JuliusBrussee/caveman |
| lean-ctx (CLI compression) | https://github.com/yvgude/lean-ctx |

### Optional — required only for `/e2e` and `/e2e-auto`

| Tool | Install |
|---|---|
| flutter-driver-mcp (Flutter projects) | `claude mcp add --transport stdio flutter-driver -- npx flutter-driver-mcp` |
| agent-browser (web projects) | `npm install -g agent-browser` |

`install.sh` does **not** install these — the e2e commands abort with the relevant install hint if you run them without the tool.

## Read the full story

The Medium post walks through the *why* of each layer, the failure modes that drove every hook, and the cost math. Start there: [`claude-code-tips.md`](./claude-code-tips.md).
