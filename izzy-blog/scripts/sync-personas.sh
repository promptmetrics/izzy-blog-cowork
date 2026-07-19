#!/bin/sh
# Auto-sync writing personas from a user-supplied private git repo into the
# plugin data dir. Read-only (repo -> machine), idempotent, non-blocking on
# failure. Mirrors the venv-provisioning pattern of run-pm-publish.sh.
#
# The plugin ships NO repo hardcoded. The user supplies repo/branch/auth via
# ${CLAUDE_PLUGIN_DATA}/persona-sync.json (copied from the template on first
# run). Empty repo => warn-once + skip + continue.
#
# On any failure this script prints a warning to stderr (and an append-only
# log) and exits 0 — the /publish pipeline must continue with whatever
# personas already exist locally.
set -u

DATA="${CLAUDE_PLUGIN_DATA:-}"
ROOT="${CLAUDE_PLUGIN_ROOT:-}"

# All failure paths exit 0 so the pipeline never breaks on sync failure.
exit0() { exit 0; }

if [ -z "$DATA" ] || [ -z "$ROOT" ]; then
  echo "sync-personas: CLAUDE_PLUGIN_DATA/CLAUDE_PLUGIN_ROOT unset — skipping" >&2
  exit0
fi

# python3 (stdlib only) is used for JSON parsing and persona validation.
# jq is not assumed available. If python3 is missing, we cannot parse config
# or validate personas, so skip silently.
if ! command -v python3 >/dev/null 2>&1; then
  echo "sync-personas: python3 not on PATH — skipping" >&2
  exit0
fi

LOG="$DATA/.persona-sync.log"
# Cap the log at ~1 MB (truncate-on-open when over the cap).
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null | tr -d ' ')" -gt 1048576 ]; then
  : > "$LOG" 2>/dev/null || true
fi
log() { echo "$(date -u +%FT%TZ) $*" >>"$LOG" 2>/dev/null || true; }
warn() { echo "sync-personas: $*" >&2; log "WARN $*"; }

# ---------------------------------------------------------------------------
# STEP 1 — Load config. Copy the template into the data dir on first run.
# ---------------------------------------------------------------------------
CFG="$DATA/persona-sync.json"
TPL="$ROOT/scripts/persona-sync.example.json"
if [ ! -f "$TPL" ]; then
  warn "template persona-sync.example.json missing — skipping"
  exit0
fi
if [ ! -f "$CFG" ]; then
  cp "$TPL" "$CFG" 2>/dev/null || { warn "cannot write $CFG — skipping"; exit0; }
  log "seeded config from template"
fi

# Validate the config is well-formed JSON up front so a typo doesn't masquerade
# as an "empty repo" warning.
if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$CFG" 2>/dev/null; then
  warn "persona-sync.json is malformed JSON — skipping (fix the syntax and rerun)"
  exit0
fi

# Parse a config key via python3 stdlib. Booleans are coerced to lowercase
# "true"/"false" so shell string compares are case-correct; JSON null and
# missing keys become the empty string. Exits non-zero on a malformed file
# (already validated above, so this is defense-in-depth).
parse_cfg() {  # $1 = key
  python3 - "$CFG" "$1" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
if not isinstance(d, dict):
    print(''); sys.exit(0)
k = sys.argv[2]
v = d.get(k, '')
if isinstance(v, bool):
    print('true' if v else 'false')
elif v is None:
    print('')
else:
    print(v)
PY
}

enabled=$(parse_cfg enabled)
if [ "$enabled" = "false" ]; then
  log "disabled via config"
  exit0
fi

repo=$(parse_cfg repo)
branch=$(parse_cfg branch); [ -z "$branch" ] && branch=main
auth=$(parse_cfg auth);    [ -z "$auth" ]   && auth=auto
ttl=$(parse_cfg ttl_seconds); [ -z "$ttl" ] && ttl=900
# Sanitize ttl to a positive integer.
case "$ttl" in *[!0-9]*) ttl=900;; esac
[ "$ttl" -lt 1 ] && ttl=900
if [ "$(parse_cfg mirror)" = "true" ]; then mirror=1; else mirror=0; fi

# ---------------------------------------------------------------------------
# STEP 2 — Empty repo => warn-once + skip.
# ---------------------------------------------------------------------------
if [ -z "$repo" ]; then
  WARNED="$DATA/.persona-sync-no-repo-warned"
  if [ ! -f "$WARNED" ]; then
    warn "persona-sync.json has empty 'repo' — set it to 'owner/name' to enable. Skipping."
    : > "$WARNED" 2>/dev/null || true
  fi
  exit0
fi
rm -f "$DATA/.persona-sync-no-repo-warned" 2>/dev/null || true

# ---------------------------------------------------------------------------
# STEP 3 — TTL skip. Exit silently if the cache was refreshed recently.
# ---------------------------------------------------------------------------
LAST="$DATA/.persona-sync-last"
now=$(date +%s 2>/dev/null || echo 0)
# If we can't read the clock, don't risk a bogus "fresh" decision — run sync.
if [ "$now" -gt 0 ] && [ -f "$LAST" ]; then
  last=$(cat "$LAST" 2>/dev/null)
  case "$last" in *[!0-9]*) last=0;; esac
  delta=$((now - last))
  if [ "$delta" -ge 0 ] && [ "$delta" -lt "$ttl" ]; then
    exit0
  fi
fi

# ---------------------------------------------------------------------------
# STEP 4 — Acquire a mkdir-based lock (atomic on macOS; no flock needed).
# Stale after 300s. A lock dir with no .ts is treated as stale (age = infinity)
# so a crashed run never wedges all future syncs.
# ---------------------------------------------------------------------------
CACHE="$DATA/.persona-cache"
LOCK="$CACHE/.lock"
mkdir -p "$CACHE" 2>/dev/null || true
acquired=0
if mkdir "$LOCK" 2>/dev/null; then
  acquired=1
else
  if [ -f "$LOCK/.ts" ]; then
    lts=$(cat "$LOCK/.ts" 2>/dev/null)
    case "$lts" in *[!0-9]*) lts=0;; esac
    [ "$((now - lts))" -gt 300 ] && lts=0  # force stale reclaim below
  else
    lts=0  # no .ts => treat as ancient/stale
  fi
  if [ "$lts" -eq 0 ]; then
    rm -rf "$LOCK" 2>/dev/null
    if mkdir "$LOCK" 2>/dev/null; then
      acquired=1
    fi
  fi
fi
if [ "$acquired" != 1 ]; then
  warn "another sync is running (lock held) — skipping"
  exit0
fi
date +%s > "$LOCK/.ts" 2>/dev/null || true
trap 'rm -rf "$LOCK" 2>/dev/null' EXIT INT TERM

# ---------------------------------------------------------------------------
# STEP 5 — Resolve auth. Build a CLEAN remote URL (no embedded token) plus a
# bearer/basic token when applicable. The token is never placed in the URL or
# in .git/config; it is passed per-invocation via http.extraHeader.
# Priority: gh > pat > ssh (unless auth forces one). none => public https.
# ---------------------------------------------------------------------------
tok=""
remote_url=""
case "$auth" in
  gh|pat|ssh|none) mode=$auth ;;
  *) mode=auto ;;
esac

if [ "$mode" = auto ] || [ "$mode" = gh ]; then
  if command -v gh >/dev/null 2>&1; then
    t=$(gh auth token 2>/dev/null) || t=""
    if [ -n "$t" ]; then
      tok=$t
      remote_url="https://github.com/${repo}.git"
    fi
  fi
  [ -z "$tok" ] && [ "$mode" = gh ] && warn "gh not authed — no fallback under auth=gh"
fi

if [ -z "$tok" ] && { [ "$mode" = auto ] || [ "$mode" = pat ]; }; then
  ENVF="$DATA/persona-sync.env"
  if [ -f "$ENVF" ]; then
    t=$(
      umask 077
      . "$ENVF" 2>/dev/null && printf '%s' "${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    )
    if [ -n "$t" ]; then
      tok=$t
      remote_url="https://github.com/${repo}.git"
    fi
  fi
  [ -z "$tok" ] && [ "$mode" = pat ] && warn "PAT not found in $ENVF"
fi

if [ -z "$tok" ] && { [ "$mode" = auto ] || [ "$mode" = ssh ]; }; then
  remote_url="git@github.com:${repo}.git"
fi

if [ -z "$tok" ] && [ -z "$remote_url" ] && [ "$mode" = none ]; then
  remote_url="https://github.com/${repo}.git"
fi

if [ -z "$remote_url" ]; then
  warn "no auth method resolved — skipping"
  exit0
fi

# Encode the token for a Basic-auth http header (base64 via python3 stdlib).
# The remote URL stays clean (no embedded token, nothing in .git/config); this
# header is passed per git invocation only, so subsequent `fetch` runs keep
# working. The header value contains a space, so it must reach git as a SINGLE
# argument — we pass it via positional parameters ($@), never word-split.
auth_header=""
if [ -n "$tok" ]; then
  b64=$(printf 'x-access-token:%s' "$tok" | python3 -c "import base64,sys; print(base64.b64encode(sys.stdin.buffer.read()).decode())" 2>/dev/null) || b64=""
  if [ -z "$b64" ]; then
    warn "could not encode auth token — skipping"
    exit0
  fi
  auth_header="Authorization: Basic $b64"
fi
# Never echo the token to logs/stderr.
log "resolved auth, target repo=$repo branch=$branch"

# ---------------------------------------------------------------------------
# STEP 6 — Clone or fetch, shallow + branch-pinned.
# credential.helper= disables any default helper (no hung macOS Keychain
# prompt); core.fsmonitor=false avoids a one-shot fsmonitor daemon spawn.
# $GIT_OPTS word-splits safely (no spaces inside values); the optional auth
# header is injected via "$@" so its space survives intact.
# ---------------------------------------------------------------------------
GIT_OPTS="-c credential.helper= -c core.fsmonitor=false"
if [ -d "$CACHE/.git" ]; then
  if [ -n "$auth_header" ]; then
    set -- -c "http.extraHeader=$auth_header"
  else
    set --
  fi
  if git $GIT_OPTS "$@" -C "$CACHE" fetch --depth 1 origin "$branch" >>"$LOG" 2>&1; then
    git $GIT_OPTS "$@" -C "$CACHE" reset --hard FETCH_HEAD >>"$LOG" 2>&1 || {
      warn "reset --hard failed — using existing cache"
    }
  else
    warn "fetch failed (offline, branch renamed, or auth) — re-cloning from scratch"
    rm -rf "$CACHE" 2>/dev/null
    if [ -n "$auth_header" ]; then
      set -- -c "http.extraHeader=$auth_header"
    else
      set --
    fi
    if git $GIT_OPTS "$@" clone --depth 1 --branch "$branch" "$remote_url" "$CACHE" >>"$LOG" 2>&1; then
      :
    else
      [ -d "$CACHE/.git" ] || { warn "clone failed — skipping (no cache available)"; exit0; }
      warn "re-clone failed — using whatever cache remains"
    fi
  fi
else
  if [ -n "$auth_header" ]; then
    set -- -c "http.extraHeader=$auth_header"
  else
    set --
  fi
  if git $GIT_OPTS "$@" clone --depth 1 --branch "$branch" "$remote_url" "$CACHE" >>"$LOG" 2>&1; then
    :
  else
    [ -d "$CACHE/.git" ] || { warn "clone failed — skipping (offline or no access)"; exit0; }
    warn "clone failed (offline?) — using existing cache if any"
  fi
fi

# ---------------------------------------------------------------------------
# STEP 7 — Collect *.json at the cache root (personas live at repo root).
# ---------------------------------------------------------------------------
files=$(cd "$CACHE" 2>/dev/null && ls -1 *.json 2>/dev/null) || files=""
if [ -z "$files" ]; then
  warn "no *.json in repo root — nothing to sync"
  date +%s > "$LAST" 2>/dev/null || true
  exit0
fi

# ---------------------------------------------------------------------------
# STEP 8 — Validate each file and atomically copy valid ones into personas/.
# ---------------------------------------------------------------------------
DEST="$DATA/personas"
mkdir -p "$DEST" 2>/dev/null || { warn "cannot mkdir $DEST"; exit0; }
MANIFEST="$DATA/.persona-sync-manifest"
MANIFEST_NEW="$MANIFEST.$$"
: > "$MANIFEST_NEW" 2>/dev/null || { warn "cannot write manifest temp"; exit0; }

synced=0
skipped=0
for f in $files; do
  src="$CACHE/$f"
  [ -f "$src" ] || continue
  # Validate: parses as JSON, has the 6 required keys, correct top-level types.
  if python3 - "$src" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
required = ("name", "tone_dimensions", "readability", "style", "do", "dont")
for k in required:
    if k not in d:
        sys.exit(1)
ok = (
    isinstance(d.get("tone_dimensions"), dict)
    and isinstance(d.get("readability"), dict)
    and isinstance(d.get("style"), dict)
    and isinstance(d.get("do"), list)
    and isinstance(d.get("dont"), list)
)
sys.exit(0 if ok else 1)
PY
  then
    :
  else
    warn "malformed: $f — keeping prior copy if any"
    skipped=$((skipped + 1))
    continue
  fi
  # Atomic per-file write: cp to a temp in the same dir, then mv over target.
  tmp="$DEST/.${f}.tmp.$$"
  if cp "$src" "$tmp" 2>/dev/null && mv "$tmp" "$DEST/$f" 2>/dev/null; then
    printf '%s\n' "$f" >> "$MANIFEST_NEW"
    synced=$((synced + 1))
  else
    rm -f "$tmp" 2>/dev/null || true
    warn "copy failed: $f"
  fi
done

# ---------------------------------------------------------------------------
# STEP 9 — Mirror mode: remove previously-synced files no longer in the repo.
# Only files the manifest tracks are eligible — local-only personas a user
# created by hand are never deleted. Skip entirely if this run synced nothing
# (e.g. every upstream file was malformed) so one bad commit can't wipe all
# synced personas.
# ---------------------------------------------------------------------------
if [ "$mirror" = 1 ] && [ -f "$MANIFEST" ] && [ "$synced" -gt 0 ]; then
  while IFS= read -r prev || [ -n "$prev" ]; do
    [ -n "$prev" ] || continue
    if [ -f "$DEST/$prev" ] && ! grep -Fxq "$prev" "$MANIFEST_NEW" 2>/dev/null; then
      rm -f "$DEST/$prev" 2>/dev/null && log "mirror deleted: $prev"
    fi
  done < "$MANIFEST"
fi
mv "$MANIFEST_NEW" "$MANIFEST" 2>/dev/null || rm -f "$MANIFEST_NEW" 2>/dev/null || true

# ---------------------------------------------------------------------------
# STEP 10 — Freshness marker. Written once we reached the clone/fetch step.
# ---------------------------------------------------------------------------
date +%s > "$LAST" 2>/dev/null || true
log "done synced=$synced skipped=$skipped mirror=$mirror repo=$repo"
exit0