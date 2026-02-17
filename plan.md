# Plan: claude-statusline — Pure Bash Status Line for Claude Code

## Context

Replace the Python claude-pulse dependency with a self-contained bash script. Must support a persistent gitstatusd daemon (required for large work repos), work in both subscription mode (OAuth API for usage %) and bedrock mode (cost from stdin, no API), and be fully config-driven.

## New repo: `/home/stonefish/claude-statusline/`

```
claude-statusline/
├── statusline.sh        # Main script (~300-350 lines)
├── config.json          # Default/reference config
└── README.md            # Setup instructions
```

User config: `${XDG_CONFIG_HOME:-$HOME/.config}/claude-statusline/config.json`
Cache/state: `${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline/`

## config.json

```json
{
  "segments": ["user", "dir", "git", "model", "context", "session", "weekly", "cost"],
  "separator": " | ",
  "cache_ttl": 60,
  "git_cache_ttl": 5,
  "path_max_length": 40,
  "show_host": "auto",
  "git_backend": "auto",
  "colors": {
    "low": "76",
    "mid": "178",
    "high": "196",
    "separator": "dim",
    "branch_clean": "76",
    "branch_dirty": "178",
    "staged": "178",
    "untracked": "39",
    "model": "dim",
    "user": "3",
    "user_root": "11",
    "host": "dim",
    "dir": "31",
    "reset_time": "dim",
    "cost": "76"
  }
}
```

All settings have baked-in defaults. Script works with no config file at all.

## Segments

| Segment | Source | Output | Auto-hide |
|---------|--------|--------|-----------|
| `user` | `$USER`, `$SSH_CONNECTION` | `stonefish` or `stonefish@host` | never |
| `dir` | stdin workspace | `project/s/subdir` (abbreviated) | if no cwd |
| `git` | gitstatusd or git CLI | `main +2 !1 ?3 ⇡1` | if not a git repo |
| `model` | stdin | `Opus 4.6` | if absent |
| `context` | stdin | `Ctx 34%` (colored low/mid/high) | if absent |
| `session` | API `five_hour` | `Ses 12% 4h23m` | if no credentials |
| `weekly` | API `seven_day` | `Wk 8% Thu` | if no credentials |
| `cost` | stdin | `$1.24` | if absent or 0 |

## gitstatusd — Spawn-Query-Kill with Cache

### Approach

Spawn gitstatusd fresh when needed, query, kill. Combined with a 5s cache, this means one ~150ms spawn every 5 seconds. No persistent daemon, no FIFOs on disk, no PID files, no lock files.

**Cache file:** `~/.cache/claude-statusline/git.cache` (plain text: `branch\tstaged\tunstaged\tuntracked\tahead\tbehind`)

**Flow:**

```
Each invocation:
  1. Git segment enabled and cwd is a git repo? If not → skip.
  2. git.cache mtime < 5s? → read cache, done.
  3. Cache stale → query_gitstatusd():
     a. Find binary at ~/.cache/gitstatus/gitstatusd-{platform}-{arch}
     b. Spawn with coproc: coproc GITD { "$binary" --num-threads=2; }
     c. Hello handshake: printf '}\x1f\x1e', read -d $'\x1e' -t 2
     d. Query: printf '1 \x1f%s\x1f0\x1e' "$cwd", read -d $'\x1e' -t 2
     e. Parse \x1f-delimited fields → branch, staged, unstaged, untracked, ahead, behind
     f. Kill coproc
     g. Write result to git.cache
  4. If gitstatusd binary not found or query fails → fallback to git CLI:
     git status --porcelain=v2 --branch (single command, parse in while-read loop)
  5. If git CLI also fails → use stale cache if available, else omit segment.
```

**Fallback chain:** gitstatusd → git CLI → stale cache → omit segment

## API Call + Caching

```
Credentials: ~/.claude/.credentials.json
  → jq '.claudeAiOauth.accessToken'
  → if missing: bedrock mode, skip session/weekly

Cache: ~/.cache/claude-statusline/usage.json
  → check mtime vs cache_ttl (default 60s)
  → if fresh: read from cache
  → if stale: curl with 3s timeout
    → 200: write to cache
    → non-200: show "--", keep old cache
```

## Stdin JSON Parsing

Claude Code pipes JSON on stdin. Extract with a single `jq` call:

```bash
read -r input
eval "$(echo "$input" | jq -r '
  @sh "MODEL=\(.data.model.display_name // .model.display_name // "")",
  @sh "CTX_PCT=\(.data.context_window.used_percentage // .context_window.used_percentage // "")",
  @sh "COST=\(.data.cost.total_cost_usd // .cost.total_cost_usd // "")",
  @sh "CWD=\(.workspace.current_dir // "")",
  @sh "PROJECT_DIR=\(.workspace.project_dir // "")"
')"
```

Single jq invocation, tries both `.data.X` and `.X` paths for compatibility.

## Script Structure

```bash
#!/bin/bash
set -euo pipefail

# ── Defaults & Constants ──
# ── Color helpers ──
c()        # emit ANSI for a color number/keyword
usage_c()  # pick low/mid/high by percentage

# ── Config ──
load_config()  # jq from config file, merge with defaults

# ── Utilities ──
shorten_path()
format_countdown()
secs_until_reset()

# ── gitstatusd daemon ──
find_gitstatusd()
start_daemon()
query_daemon()
git_cli_query()
get_git_status()   # orchestrator: cache check → daemon/cli → cache write

# ── API ──
fetch_usage()      # curl + mtime cache

# ── Segment builders ── (each prints segment string or empty)
seg_user()
seg_dir()
seg_git()
seg_model()
seg_context()
seg_session()
seg_weekly()
seg_cost()

# ── Main ──
main() {
    load_config
    read_stdin

    local parts=()
    for seg in "${SEGMENTS[@]}"; do
        local result
        result=$("seg_$seg") && [[ -n "$result" ]] && parts+=("$result")
    done

    # Join with separator
    local sep output=""
    sep="$(c "$SEP_COLOR")${SEPARATOR}$(c reset)"
    for ((i=0; i<${#parts[@]}; i++)); do
        ((i > 0)) && output+="$sep"
        output+="${parts[i]}"
    done
    printf '%b' "$output"
}
main
```

## Reference: Existing Python Implementation

Key details from claude-pulse (Python) to preserve:

### API Endpoint & Auth
- Endpoint: `https://api.anthropic.com/api/oauth/usage`
- Auth: `Bearer {token}` header
- Required header: `anthropic-beta: oauth-2025-04-20`
- Credentials: `~/.claude/.credentials.json` → `.claudeAiOauth.accessToken`
- Refresh: `POST https://console.anthropic.com/v1/oauth/token` with `grant_type=refresh_token`
- Security: tokens ONLY sent to `api.anthropic.com` and `console.anthropic.com`

### Usage Response Shape
- `five_hour.utilization` (0-100 int)
- `five_hour.resets_at` (ISO timestamp or null)
- `seven_day.utilization` (0-100 int)
- `seven_day.resets_at` (ISO timestamp or null)

### gitstatusd Protocol
- Binary at: `~/.cache/gitstatus/gitstatusd-{platform}-{arch}`
- Hello handshake: send `}\x1f\x1e`, expect response ending `\x1e`
- Query: send `1 \x1f{cwd}\x1f0\x1e`, parse `\x1f`-delimited response
- Response fields: [2]=workdir [3]=commit [4]=branch [10]=staged [11]=unstaged [12]=conflicted [13]=untracked
- Spawn with `--num-threads=1` (or 2), kill after query

### git CLI Fallback
- `git status --porcelain=v2 --branch`
- `# branch.head` line → branch name
- `(detached)` → use `git rev-parse --short HEAD`
- Line prefix `1`/`2` → XY status (X=staged, Y=unstaged, `.`=clean)
- Line prefix `u` → unmerged (count as unstaged)
- Line prefix `?` → untracked

### Path Shortening
- If inside project_dir: show `project_name/abbreviated/path`
- Middle components abbreviated to first char
- Home dir → `~`
- Max length configurable (default 40)

### Plan Names
- `default_claude_pro` → "Pro"
- `default_claude_max_5x` → "Max 5x"
- `default_claude_max_20x` → "Max 20x"

## Verification

1. `echo '<subscription JSON>' | bash statusline.sh` → all segments render with colors
2. `echo '<bedrock JSON>' | bash statusline.sh` with no credentials → session/weekly hidden, cost shows
3. Edit config: reorder segments, change separator to ` · `, disable git → verify
4. No config file at all → verify defaults work
5. In a git repo with gitstatusd binary → verify daemon starts, response cached
6. Run again within 5s → verify cache hit (no daemon query)
7. Non-git directory → git segment silently omitted
8. Kill network → `--` shown for session/weekly, no crash
9. Point `~/.claude/settings.json` statusLine at the script → test live in Claude Code
