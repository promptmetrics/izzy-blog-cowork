# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Claude Cowork **marketplace** that ships one plugin, `izzy-blog-cowork`, exposing Izzy's blog publishing pipeline as three slash commands. The marketplace is the outer repo; the actual plugin lives in the `izzy-blog/` subdirectory. This nesting is intentional — Cowork marketplace manifests point at a plugin subdirectory via `source`, and the plugin itself has its own `.claude-plugin/plugin.json`. Do not flatten it.

The plugin **delegates** the writing/analysis/rewriting/repurposing work to the separately-installed `claude-blog` plugin's sub-skills (`/claude-blog:blog-write`, `blog-analyze`, `blog-rewrite`, `blog-repurpose`). This repo only owns the routing skill, the persona system, the loop orchestration, the fixer sub-agent, and the MCP server that pushes finished posts to the PromptMetrics admin API.

## Layout

```
.claude-plugin/marketplace.json      # marketplace manifest; source → "./izzy-blog"
izzy-blog/                           # the actual plugin
├── .claude-plugin/plugin.json        # plugin manifest (name/version/deps)
├── .mcp.json                         # wires the pm-publish MCP server (uses ${CLAUDE_PLUGIN_ROOT})
├── skills/publish/SKILL.md           # THE router: /publish blog about | loop | persona
├── agents/blog-fixer.md              # fresh-eyes sub-agent dispatched on loop plateau
├── servers/pm-publish/               # FastMCP server (Python) → PM admin API
├── scripts/run-pm-publish.sh         # venv-provisioning launcher (stdio MCP)
├── personas/.gitkeep                # personas live in ${CLAUDE_PLUGIN_DATA}/personas/ at runtime
└── repurposed/.gitkeep               # repurpose outputs land in ${CLAUDE_PLUGIN_ROOT}/repurposed/
```

`skills/publish/SKILL.md` is the source of truth for all three commands. If a command's behavior is unclear, read that file before guessing.

## The three commands

All entered as `/publish blog ...`. The skill parses the token after `/publish blog` and routes:

- **`about <topic>`** — sequential pipeline: persona check → `/claude-blog:blog-write` → `blog-analyze` → `blog-rewrite` → (publish + repurpose in parallel). Publish calls the `pm_publish` MCP tool; repurpose calls `/claude-blog:blog-repurpose`.
- **`loop to <score> about <topic>`** — score-gated iterative loop (default target 92, max 5 iterations). Write once, then repeatedly analyze → gate → (fact-check if needed) → rewrite. On the first plateau (`rounds_since_best == 1`) it dispatches the `blog-fixer` sub-agent instead of a normal rewrite. Stops on target hit, max iterations, or plateau (`rounds_since_best >= 2`). Completion hands off to `about` for publish + repurpose.
- **`persona [quick|list|use|show] [name]`** — create/list/activate/show writing personas. `quick` seeds from `/Users/izzy/Documents/daily-os/context/about-izzy.md` + `goals.md`. No sub-command runs the 6-step interactive interview.

### Loop enforcement has no Stop hook

Claude Cowork has no Claude Code `Stop` hook, so the loop is enforced **behaviorally** via a sentinel file at `${CLAUDE_PLUGIN_DATA}/.loop-blog-active.json` (`{post, target, started, best, rounds}`). The skill refuses to exit without a stop condition or explicit user "abort". Sentinels older than 2h are treated as abandoned and cleared on the next loop start. Don't reintroduce a hook-based design.

## Runtime environment variables

The MCP server and skills read from the plugin runtime (Cowork/Code exports these to plugin subprocesses):

- `CLAUDE_PLUGIN_ROOT` — installed plugin directory (used by `.mcp.json` and `scripts/run-pm-publish.sh`).
- `CLAUDE_PLUGIN_DATA` — persistent per-plugin data dir. **Personas live here** (`${CLAUDE_PLUGIN_DATA}/personas/<name>.json`), not in the repo's `personas/` (that's just a `.gitkeep` placeholder). The loop sentinel and active-persona marker also live here. The venv is provisioned here too (`${CLAUDE_PLUGIN_DATA}/venv`).
- `PM_ADMIN_EMAIL` / `PM_ADMIN_PASSWORD` — required for the PM admin API login (set in Cowork connector settings or env).
- `PM_ADMIN_JWT` — optional; skips the sign-in call.
- `PM_BASE_URL` — optional; defaults to `https://pm-backend-784948600682.us-central1.run.app/api/v1`.

## Commands (development)

There is no build, test, or lint step at the repo level. The Python server has no test suite.

```bash
# Validate the plugin manifest (run from inside the plugin dir, not repo root)
cd izzy-blog && claude plugin validate ./

# Load the plugin into a session for manual testing
cd izzy-blog && claude --plugin-dir ./

# Smoke-test the MCP server standalone (needs PM_ADMIN_EMAIL/PASSWORD in env)
cd izzy-blog && ./scripts/run-pm-publish.sh   # speaks stdio MCP; Ctrl-C to exit

# Force a reinstall of the Python server after editing server.py. The launcher caches
# the venv keyed to the plugin root (tracked by ${CLAUDE_PLUGIN_DATA}/.pm-publish-installed-root),
# so it auto-reprovisions only when ROOT changes — editing server.py does NOT trigger reinstall.
# Delete the venv to force it:
rm -rf "${CLAUDE_PLUGIN_DATA}/venv"
```

Verification flow (from the plugin README): `claude plugin validate ./` passes → start a session with the plugin loaded → `/publish blog persona quick` → `/publish blog about "a test topic"` and confirm write/analyze/rewrite/publish/repurpose all complete.

## pm-publish MCP server (`izzy-blog/servers/pm-publish/`)

FastMCP server exposing one tool, `publish_post(markdown_path, slug=None)`. It parses frontmatter (title/slug/category/description/coverImage/author), falls back to the first H1 for the title, slugs the title with `python-slugify`, then `POST`s to `/admin/post/from-markdown` with a JWT (env-provided or freshly minted via `/user/sign-in`). Requires Python ≥ 3.12; deps are pinned in `pyproject.toml` (fastmcp 2.x, httpx 0.27.x, python-frontmatter 1.x, python-slugify 8.x).

## Editing conventions

- The routing skill is one file (`skills/publish/SKILL.md`) handling all three sub-commands — keep it that way; don't split into multiple skills unless a sub-command outgrows it.
- When changing pipeline behavior, update the step tables in `SKILL.md` — they're treated as the contract by future readers.
- The `blog-fixer` agent is intentionally `model: opus`, `effort: medium`, `maxTurns: 20`, `disallowedTools: Bash`. It's a read-and-Edit-only fresh-eyes editor; don't add tools to it.
- Output paths are hardcoded to `/Users/izzy/Documents/daily-os/blog/<slug>.md` for posts and `${CLAUDE_PLUGIN_ROOT}/repurposed/<slug>/` for repurpose output. Changing these is a user-facing behavior change.