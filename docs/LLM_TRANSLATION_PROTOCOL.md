# LLM Translation Protocol

Last updated: February 19, 2026

This protocol defines how LLMs should edit BurdSurvivalJournals translation payloads safely.

## Allowed Input/Output Format

Use `bsj-template-v1` JSON:

```json
{
  "_meta": {
    "schema": "bsj-template-v1",
    "langCode": "FR"
  },
  "entries": {
    "UI_BurdJournals_Close": {
      "english": "Close",
      "translation": "",
      "category": "UI",
      "placeholders": []
    }
  }
}
```

## Hard Rules

1. Modify only `entries[*].translation`.
2. Do not modify:
   - `entries` keys
   - `_meta.schema`
   - placeholder tokens (`%s`, `%d`, `%1`, etc.)
3. Preserve escaped sequences like `\n`.
4. Keep output as valid JSON (UTF-8).
5. Do not add comments to JSON.
6. Do not remove existing non-empty translations unless explicitly instructed.

## Placeholder Validation Rule

For each key:

- All placeholders in `english` must exist in `translation`.
- `translation` must not add placeholders not present in `english`.

## Safety Instructions For LLM Prompting

Recommended system instruction fragment:

```text
Translate only the `translation` fields.
Keep all keys unchanged.
Preserve placeholders and escape sequences exactly.
Return valid JSON only.
```

## Minimal JSON Schema (Conceptual)

```text
root:
  _meta.schema == "bsj-template-v1"
  _meta.langCode: string
  entries: object
entries[key]:
  english: string
  translation: string
  category: string|null
  placeholders: string[]
```

## Import Back Into Tool

1. Export LLM pack from tool.
2. Run LLM translation under this protocol.
3. Import JSON into tool.
4. Resolve blocking placeholder mismatches.
5. Submit via in-tool GitHub PR flow.
