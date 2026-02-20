# Burd's Survival Journals Translation Guide

Last updated: February 19, 2026

This guide explains how to contribute translations using the updated localization tool in `docs/`.

## Goals

- Make translation contributions safe and predictable.
- Support in-browser translation, offline template work, and LLM-assisted workflows.
- Keep Build 42 and Build 41 translation outputs in sync.

## Translation Scope

Current English baseline key counts:

- `ContextMenu_EN.txt`: 30
- `IG_UI_EN.txt`: 60
- `ItemName_EN.txt`: 6
- `Recipes_EN.txt`: 18
- `Sandbox_EN.txt`: 147
- `Tooltip_EN.txt`: 94
- `UI_EN.txt`: 358
- Total: `713` keys

Important naming note:

- Item names are maintained in `ItemName_XX.txt`.
- Legacy `Items_XX.txt` files may still exist in repo history and are treated as read-only diagnostics, not active translation targets.

## Format Rules (All Workflows)

1. Keep translation keys unchanged.
2. Preserve placeholders exactly:
   - `%s`, `%d`, `%1`, `%2`, etc.
3. Preserve escaped sequences like `\n`.
4. Keep Lua table names aligned to file names:
   - `UI_FR.txt` must contain `UI_FR = { ... }`
5. Avoid deleting existing translated values unless intentionally clearing them.

## Workflow A: Translate In Browser (Recommended)

1. Open the tool page.
2. Select language in the top dropdown.
3. Translate strings directly in the text areas.
4. Use filters/search to target empty keys or categories.
5. Check the **Translation Health** panel for:
   - Coverage
   - Placeholder issues
   - Missing categories
6. Connect GitHub and submit through **Submit to GitHub**.

Submission preflight now includes:

- Language selection toggles
- Changed key counts
- Planned file targets for both Build 42 and Build 41

## Workflow B: Translate With Local Template

1. In the tool, choose your language.
2. Click **Export Template**.
3. Edit `BSJ_Template_<LANG>.json`.
4. Import the file with **Import**.
5. Review import preflight:
   - Detected language
   - Key count
   - Placeholder mismatches
   - Merge mode (`fill`, `overwrite`, `skip`)
6. Apply import and then submit via GitHub flow (or export files).

Template schema is `bsj-template-v1` with:

- `_meta`
- `entries` keyed by translation key
- Per-entry fields:
  - `english`
  - `translation`
  - `category`
  - `placeholders`

## Workflow C: LLM-Assisted Translation

1. In the tool, choose your language.
2. Click **Export LLM Pack**.
3. Give the JSON file to your LLM with strict rules:
   - Translate only `entries[*].translation`
   - Do not change keys
   - Preserve placeholders and escapes
4. Import the updated JSON into the tool.
5. Resolve or explicitly override placeholder mismatch warnings in import preflight.
6. Submit through in-tool GitHub PR flow.

See `docs/LLM_TRANSLATION_PROTOCOL.md` for full constraints and validation schema.

## Import Behavior

The import system supports:

- `.json` (single-language, multi-language, `bsj-template-v1`)
- `.txt` Lua translation files
- `.zip` translation bundles

Safety behavior:

- Language mismatch is shown before apply.
- Placeholder mismatches are blocking by default.
- Unknown keys are ignored during apply.
- ZIP import enforces one language per import action.

## Export Behavior

Exports available:

- Mod-ready ZIP (Build 42 + Build 41 paths)
- JSON backup
- Template (`bsj-template-v1`)
- LLM Pack (`bsj-template-v1` + extra metadata)
- Per-category copy/download

## Contribution Checklist

Before opening a PR:

1. Placeholder mismatches resolved (or intentionally reviewed).
2. Coverage/health checked for your target language.
3. Import/export round-trip tested if working from local template/LLM.
4. In-game validation performed for critical UI strings.
5. PR description reviewed and language selections confirmed in preflight.

## Troubleshooting

If import is blocked:

- Fix placeholder mismatches first.
- Ensure language code is correct and consistent.
- Ensure JSON matches expected schema.

If GitHub submission is blocked:

- Reconnect GitHub.
- Verify there are changed keys.
- Check submission preflight warnings/errors.

If you find malformed source entries:

- Report file path + key + language.
- Example known malformed line reference: `Contents/mods/BurdSurvivalJournals/42/media/lua/shared/Translate/CN/Tooltip_CN.txt:49`

## Contributing

Primary contribution path:

- Use the tool and submit via in-tool GitHub PR flow.

Fallback path:

- Export files and open a manual PR against `TheBurd/PZ-BurdSurvivalJournals`.
