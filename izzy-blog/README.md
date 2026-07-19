# izzy-blog-cowork

Claude Cowork plugin for Izzy's blog pipeline: persona interview, score-gated writing, one-click publish to PromptMetrics, and repurposing.

## What it adds

Three slash commands:

- `/publish blog about <topic>` — single-pass pipeline: write → analyze → rewrite → publish + repurpose.
- `/publish blog loop to <score> about <topic>` — score-gated iterative loop, then publish + repurpose.
- `/publish blog persona` — create, list, use, and show writing personas.

## Repository layout

```text
izzy-blog-cowork/
├── .claude-plugin/
│   └── marketplace.json         # marketplace metadata
└── izzy-blog/
    ├── .claude-plugin/
    │   └── plugin.json          # plugin manifest
    ├── .mcp.json                # pm-publish MCP server wiring
    ├── skills/
    │   └── publish/SKILL.md     # /publish blog about | loop | persona
    ├── agents/
    │   └── blog-fixer.md        # fresh-eyes fixer sub-agent
    ├── servers/
    │   └── pm-publish/          # MCP server for PM admin API
    ├── scripts/
    │   └── run-pm-publish.sh    # venv + MCP launcher
    ├── repurposed/              # default output folder for repurpose step
    └── personas/                # default persona storage
```

## Prerequisites

1. Claude Cowork (or Claude Code) with plugin support.
2. The `claude-blog` plugin installed — this plugin delegates writing, analysis, rewriting, and repurposing to its sub-skills.
3. Python ≥ 3.12 on `PATH` for the MCP server.
4. `PM_ADMIN_EMAIL` and `PM_ADMIN_PASSWORD` configured in your environment or Cowork connector settings.

## Installation

### From the marketplace

Add `https://github.com/promptmetrics/izzy-blog-cowork` in Claude Cowork and install the `izzy-blog-cowork` plugin.

### Local development

```bash
cd /Users/izzy/Documents/izzy-blog-cowork/izzy-blog
claude plugin validate ./
claude --plugin-dir ./
```

Then invoke `/publish blog about ...` in that session.

## Configuration

The MCP server reads these environment variables:

- `PM_ADMIN_EMAIL` — PromptMetrics admin email
- `PM_ADMIN_PASSWORD` — PromptMetrics admin password
- `PM_ADMIN_JWT` — optional; skips login if provided
- `PM_BASE_URL` — optional; defaults to the PM backend URL

## Personas

Create a persona with `/publish blog persona` or `/publish blog persona quick`. Personas are stored in the plugin data directory (`${CLAUDE_PLUGIN_DATA}/personas/`).

When you run `/publish blog about`, the plugin checks for personas and offers to create one if none exist.

## Persona sync (optional)

The plugin data dir is wiped on a plugin update, which would erase your personas. **Persona sync** auto-populates `${CLAUDE_PLUGIN_DATA}/personas/` from a private git repo you control, so personas survive updates with no manual clone/copy step. It runs at MCP server start and at the start of `/publish blog about` (TTL-cached, so warm runs are ~ms). It is read-only — the plugin never writes back to your repo.

The plugin ships **no repo hardcoded**. You supply the repo, branch, and auth method once.

### One-time setup

1. Create a private git repo containing one `*.json` per persona at the repo root (each file must match the persona schema in the `/publish blog persona` section).
2. Copy the template into your plugin data dir and edit it:

   ```bash
   cp "${CLAUDE_PLUGIN_ROOT}/scripts/persona-sync.example.json" \
      "${CLAUDE_PLUGIN_DATA}/persona-sync.json"
   ```

   Then set `"repo": "owner/name"` (and optionally `"branch"`).

3. Authenticate so sync can read the private repo. Pick one:

   - **GitHub CLI (recommended):** run `gh auth login`. No secret stored by the plugin — sync reads `gh auth token` at runtime. Default `auth: "auto"` picks this up first.
   - **Fine-grained PAT (for machines without `gh`):** create a read-only, single-repo PAT and put it in `${CLAUDE_PLUGIN_DATA}/persona-sync.env` (chmod 600):

     ```bash
     echo 'GH_TOKEN=ghp_xxxxxxxxxxxx' > "${CLAUDE_PLUGIN_DATA}/persona-sync.env"
     chmod 600 "${CLAUDE_PLUGIN_DATA}/persona-sync.env"
     ```

   - **SSH deploy key:** ensure `git@github.com:owner/name.git` is reachable via your SSH key. `auth: "auto"` falls back to this last.

   You can force a method with `"auth": "gh"|"pat"|"ssh"|"none"` in `persona-sync.json` (`"none"` is for public repos only).

4. Run any `/publish blog` command. Sync clones into `${CLAUDE_PLUGIN_DATA}/.persona-cache/` and copies valid personas into `personas/`.

### Behavior notes

- **Empty `repo`** (the shipped default) → sync warns once and skips; the pipeline continues with whatever personas exist. Fill in `repo` to enable.
- **TTL:** sync skips the network within `ttl_seconds` (default 900) of the last run. Force a refresh by deleting `${CLAUDE_PLUGIN_DATA}/.persona-sync-last`.
- **Malformed file:** a persona missing required keys (`name`, `tone_dimensions`, `readability`, `style`, `do`, `dont`) is skipped with a warning; the prior good copy is kept; other personas still sync.
- **Offline / unreachable:** sync uses the last good cache and warns; the pipeline runs with whatever personas exist.
- **`mirror: true`** (default `false`): deletes a locally-synced persona that was removed from the repo, but only files sync previously tracked — a persona you created by hand is never deleted. Note: renaming a persona in the repo will delete the old local file on the next mirror run.
- **Editing a persona:** edit it in your source repo and commit; within the TTL window (or on the next session) the machine picks up the change.

## Outputs

- Blog posts: `/Users/izzy/Documents/daily-os/blog/<slug>.md`
- Repurposed content: `./repurposed/<slug>/`

## Verification

1. `claude plugin validate ./` should pass when run from the `izzy-blog/` subdirectory.
2. Start a session with the plugin loaded.
3. `/publish blog persona quick` — create a quick-start persona.
4. `/publish blog about "a test topic"` — verify write, analyze, rewrite, publish, and repurpose all complete.

## Notes

- This plugin does not delete or replace the original `~/.claude/skills/izzy-blog/` and `~/.claude/skills/blog-loop/` skills. They can coexist during migration.
- The score-gated loop no longer relies on a Claude Code `Stop` hook; enforcement is behavioral via a sentinel file and completion reporting rules.
