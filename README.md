# izzy-blog-cowork (Claude Cowork Marketplace)

A Claude Cowork marketplace containing Izzy's blog pipeline plugin.

## Plugin: `izzy-blog-cowork`

Located in [`./izzy-blog`](./izzy-blog). It adds:

- `/publish blog about <topic>` — single-pass pipeline: write → analyze → rewrite → publish + repurpose.
- `/publish blog loop to <score> about <topic>` — score-gated iterative loop, then publish + repurpose.
- `/publish blog persona` — create, list, use, and show writing personas.

## Install in Claude Cowork

Add the marketplace URL:

```
https://github.com/promptmetrics/izzy-blog-cowork
```

Then install the `izzy-blog-cowork` plugin from the marketplace.

## Repository layout

```text
.claude-plugin/marketplace.json  # marketplace manifest
izzy-blog/                       # the plugin
```
