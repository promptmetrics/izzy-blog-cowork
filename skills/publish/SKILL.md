---
name: publish
description: |
  Izzy's blog pipeline for Claude Cowork. Routes: "publish blog about", "publish blog loop", and "publish blog persona". Writes, analyzes, rewrites, publishes to PromptMetrics, and repurposes content.
argument-hint: "blog about <topic> | blog loop to <score> about <topic> | blog persona [quick|list|use|show] [name]"
---

# Publish — Izzy's Blog Pipeline

Router for three sub-commands:

- `/publish blog about <topic>` — single-pass write → analyze → rewrite → publish + repurpose.
- `/publish blog loop to <score> about <topic>` — score-gated iterative loop, then publish + repurpose.
- `/publish blog persona [quick|list|use|show] [name]` — create/list/use/show writing personas.

## Command parsing

Inspect the user's slash command text after `/publish`. The first word after `/publish` must be `blog`. Then route on the second word:

- `about` → single-pass pipeline
- `loop` → score-gated loop
- `persona` → persona management

If the user types something else, ask them to use one of the supported forms.

---

## `/publish blog about <topic>`

Single-pass content pipeline.

### Pipeline

| Step | Action | Tool |
|------|--------|------|
| 1 | Persona check | Read `${CLAUDE_PLUGIN_DATA}/personas/` |
| 2 | Write post | `/claude-blog:blog-write <topic>` |
| 3 | Analyze | `/claude-blog:blog-analyze <file> --format json` |
| 4 | Rewrite | `/claude-blog:blog-rewrite <file>` |
| 5a | Publish | MCP tool `pm_publish` |
| 5b | Repurpose | `/claude-blog:blog-repurpose <file>` |

Steps 1–4 run sequentially. Steps 5a and 5b run in parallel.

### Persona handling

Before writing, check for saved personas in `${CLAUDE_PLUGIN_DATA}/personas/`:

- **No personas found:** ask the user:
  - "You don't have a writing persona set up yet. A persona makes the blog sound like you. Create one now?"
  - If yes → run the persona interview first, then continue with the chosen persona.
  - If no → proceed with the default `claude-blog` voice and note it in the report.
- **One persona:** use it automatically and mention it.
- **Multiple personas:** ask which to use, or default to the most recently modified.

To use a specific persona without prompting, pass `with persona <name>` in the command.

### Output locations

- Blog post: `/Users/izzy/Documents/daily-os/blog/<slug>.md`
- Repurposed content: `${CLAUDE_PLUGIN_ROOT}/repurposed/<slug>/`

### Step-by-step

1. **Persona check.** Read `${CLAUDE_PLUGIN_DATA}/personas/*.json`.
2. **Write.** Invoke `/claude-blog:blog-write` with the topic.
3. **Analyze.** Run `/claude-blog:blog-analyze --format json`.
4. **Rewrite.** Pass critical/high issues to `/claude-blog:blog-rewrite`.
5. **Publish + repurpose in parallel.**
   - `pm_publish` MCP tool with `markdown_path = <file>`.
   - `/claude-blog:blog-repurpose` → save outputs to `${CLAUDE_PLUGIN_ROOT}/repurposed/<slug>/`.
6. **Report:** final path, score, persona used, publish result, repurposed folder + file list.

---

## `/publish blog loop to <score> about <topic>`

Score-gated iterative loop.

### Parameters (defaults)

| Param | Default | Meaning |
|-------|---------|---------|
| `target` | **92** | Stop when `blog-analyze` score ≥ this |
| `max_iterations` | **5** | Hard cap on analyze rounds |

Honor user overrides like "to 95 max 8".

### Protocol

1. **Never report done without a `blog-analyze` score from this run as proof.**
2. **Never raise the score by gaming the rubric** — no keyword stuffing, fabricated sources/stats, or filler padding.

### Loop

```
topic → write → analyze → gate → done | fact-check → rewrite → re-analyze → …
file  → analyze → gate → done | fact-check → rewrite → re-analyze → …
```

1. **Write** (topic only): `/claude-blog:blog-write`. Create sentinel `${CLAUDE_PLUGIN_DATA}/.loop-blog-active.json` = `{"post":"<abs>","target":<n>,"started":<epoch>,"best":0,"rounds":0}`.
2. **Analyze:** `/claude-blog:blog-analyze --format json`.
3. **Capture best:** if new high score, copy main file to `<slug>.best.md`; update sentinel.
4. **Gate:** target hit / max iterations / plateau (`rounds_since_best >= 2`) → Completion.
5. **Research Gate (conditional):** run fact-validation only when issues are factual/sourcing-related or E-E-A-T/AI-citation scores are low.
6. **Rewrite:**
   - `rounds_since_best == 0` → `/claude-blog:blog-rewrite`.
   - `rounds_since_best == 1` → dispatch `izzy-blog-cowork:blog-fixer` sub-agent.
7. Loop back to analyze.

### Completion

1. Restore best snapshot if needed; delete `.best.md`.
2. Remove sentinel.
3. Hand off to `/publish blog about <file>` for publish + repurpose.
4. Report final path, score, loop log, stop reason, top 2 unresolved issues if target missed.

### Sentinel / no Stop hook

Claude Cowork has no Claude Code `Stop` hook. Enforcement is behavioral:

- The sentinel file proves a loop is active.
- Refuse to exit without reaching a stop condition or the user explicitly saying "abort".
- Sentinels stale >2h are treated as abandoned and removed on a new loop start.

---

## `/publish blog persona [quick|list|use|show] [name]`

Create, list, activate, and show writing personas.

### Sub-commands

- `quick` — seed a persona from `/Users/izzy/Documents/daily-os/context/about-izzy.md` + `goals.md`, then ask the user to confirm/tweak and save.
- `list` — show saved personas.
- `use <name>` — write `${CLAUDE_PLUGIN_DATA}/.active-persona` marker.
- `show <name>` — display full profile.
- (no sub-command) — run the 6-step interactive interview to create a new persona.

### Create interview

1. **Brand Basics:** brand name, industry, target audience, one-sentence mission.
2. **Tone Dimensions:** NNGroup sliders (funny-serious, formal-casual, respectful-irreverent, enthusiastic-matter-of-fact).
3. **Writing Rules:** vocabulary tier, readability band, sentence length mean/std, contraction frequency, max passive voice.
4. **Do's and Don'ts:** 3–5 items each.
5. **Summary Label:** Key Takeaways, The Bottom Line, TL;DR, etc.
6. **Voice Samples (optional):** 1–3 URLs; read and compare extracted values.

### Save

Write to `${CLAUDE_PLUGIN_DATA}/personas/<name>.json`.

### Persona schema

```json
{
  "name": "izzy-default",
  "description": "...",
  "brand": "...",
  "industry": "...",
  "audience": "...",
  "mission": "...",
  "tone_dimensions": { "funny_serious": 0.7, "formal_casual": 0.4, "respectful_irreverent": 0.2, "enthusiastic_matter_of_fact": 0.5 },
  "readability": { "flesch_grade_min": 8, "flesch_grade_max": 10, "flesch_ease_min": 50, "flesch_ease_max": 60 },
  "style": { "sentence_length_mean": 18, "sentence_length_std": 6, "contraction_frequency": 0.6, "passive_voice_max_pct": 10, "vocabulary_tier": "professional", "summary_label": "Key Takeaways" },
  "voice_samples": [],
  "do": ["..."],
  "dont": ["..."]
}
```

---

## Error handling

- If any `/claude-blog:*` sub-skill fails, report the error and stop the pipeline.
- If `pm_publish` fails, still report repurposed output and the publish error.
- If `blog-repurpose` fails, still report the published post and the repurposing error.
- If persona files are malformed, warn and fall back to default voice.
