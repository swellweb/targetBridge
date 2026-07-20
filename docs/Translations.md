# Translations

TargetBridge now uses shared JSON language files for both the Sender and the Receiver.

## Where translations live

All shared language files are in:

- `TargetBridge-Shared/Languages/en.json`
- `TargetBridge-Shared/Languages/it.json`
- `TargetBridge-Shared/Languages/de.json`
- `TargetBridge-Shared/Languages/zh.json`

The Sender and Receiver both read from these files.

## How to add or update a translation

1. Open the source file for the language you want to edit.
2. Find the key you want to translate.
3. Update only the value on the right side.
4. Keep the key name exactly the same.

Example:

```json
{
  "sender.button.connect": "Connect"
}
```

## Key naming

Keys are grouped by area:

- `common.*` for shared strings
- `sender.*` for Sender UI
- `receiver.*` for Receiver UI

Examples:

- `common.app_name`
- `sender.button.connect`
- `sender.status.ready`
- `receiver.ui.title`
- `receiver.status.waiting_for_sender`

## Placeholders

Some strings contain placeholders that must be preserved exactly.

Examples:

- `%{ip}`
- `%{width}`
- `%{height}`
- `%{codec}`
- `%{preset}`

Example:

```json
{
  "receiver.mode.receiving": "%{width} x %{height} px receiving"
}
```

Do not translate or remove the placeholder tokens themselves. Only translate the surrounding text.

## Important rules

- Keep the JSON valid.
- Do not rename keys.
- Do not remove placeholders.
- Try to keep the same meaning across all languages.
- If you add a new key in `en.json`, also add it to `it.json`, `de.json`, and `zh.json`.
- A feature is not complete until its visible text is reviewed in English, Italian, German, and Chinese.

## Adding a new language

To add a new language:

1. Copy `TargetBridge-Shared/Languages/en.json`
2. Rename it, for example `fr.json`
3. Translate the values
4. Add the corresponding language mapping in the Sender and Receiver code

## Testing

Before building, run the shared validation from the repository root:

```bash
./TargetBridge-Shared/scripts/check_localizations.sh
```

The check verifies valid JSON, identical translation keys, and preserved placeholders.
It cannot judge translation quality, so always open Sender and Receiver in every supported
language to review new feature text before release.

After editing translations, rebuild:

```bash
cd TargetBridge-Sender
./scripts/build_targetbridge_sender_app.sh
```

```bash
cd TargetBridge-Receiver
./scripts/build_tbreceiver_c_app.sh
```

Then open the apps and verify the translated strings in the UI.
