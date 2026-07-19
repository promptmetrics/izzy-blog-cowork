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
