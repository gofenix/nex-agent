---
name: pulse
description: Create a concise morning or evening briefing with notable product, repo, news, and weather updates.
always: false
user-invocable: true
---

# Pulse

Use this skill when the user asks for `pulse`, a daily briefing, or a compact morning/evening roundup.

## Goal

Produce a fast, scannable briefing that feels curated rather than exhaustive.

Prefer durable patterns over improvisation:

- determine the current local date and whether this is a morning or evening run
- gather only a small set of timely, high-signal updates
- avoid repeating the same story from recent Pulse outputs when possible
- keep the final result brief enough to read in under two minutes

## Suggested Workflow

1. Use `bash` to check the current local date and time.
2. If `workspace/notes/pulse/` already contains recent briefings, inspect the latest one or two with `read` or `bash` to avoid obvious duplication.
3. Gather a small set of updates with existing tools:
   - Product Hunt or notable launches: `web_fetch`
   - GitHub Trending or open-source momentum: `web_fetch`
   - Breaking or important news: `web_search` plus `web_fetch`
   - Weather for the places the user cares about: `web_fetch`
4. Curate aggressively. Skip routine, stale, or low-signal items.
5. If this Pulse should be kept for future deduplication, save it under `workspace/notes/pulse/YYYY-MM-DD-morning.md` or `workspace/notes/pulse/YYYY-MM-DD-evening.md`.
6. If the user expects delivery into a chat channel, use `message`. Otherwise reply directly in the current conversation.

## Curation Rules

- Favor timeliness over completeness.
- Prefer 3-6 strong items over 12 mediocre ones.
- If nothing important happened in a category, say so briefly instead of padding.
- Keep commentary to one or two sentences per item.
- Match the user's language.

## Output Shape

Start directly with the title. Do not add a preamble.

Use a structure like:

```markdown
# Pulse | Morning - YYYY-MM-DD

## Highlights
- **[Headline](URL)** Brief explanation and why it matters.

## Product
- **[Product Name](URL)** One-line summary.

## Open Source
- **[owner/repo](URL)** Why it is worth noticing.

## Weather
- City: short weather summary.
```

Adapt the sections to the day. If a section has nothing useful, omit it or replace it with a one-line note.
