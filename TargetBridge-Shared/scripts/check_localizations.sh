#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
languages_dir="$repo_root/TargetBridge-Shared/Languages"
source_language="$languages_dir/en.json"
languages=(de en fr it zh)
status=0

fail() {
    printf 'Localization check failed: %s\n' "$*" >&2
    status=1
}

for language in "${languages[@]}"; do
    file="$languages_dir/$language.json"
    if ! jq -e 'type == "object" and all(.[]; if type == "string" then test("\\S") else false end)' "$file" >/dev/null; then
        fail "$language.json must be a JSON object of nonempty strings"
        continue
    fi
    # The C and Swift loaders must not disagree about which duplicate wins.
    duplicate_keys="$(jq --stream -r 'select(length == 2 and (.[0] | length) == 1) | .[0][0]' "$file" | LC_ALL=C sort | uniq -d)"
    [[ -z "$duplicate_keys" ]] || fail "$language.json has duplicate keys: $(tr '\n' ' ' <<< "$duplicate_keys")"
done

[[ "$status" -eq 0 ]] || exit "$status"

source_keys="$(mktemp)"
referenced_keys="$(mktemp)"
trap 'rm -f "$source_keys" "$referenced_keys"' EXIT
jq -r 'keys[]' "$source_language" | LC_ALL=C sort > "$source_keys"

# Comparing languages alone misses a key omitted from every catalog. Check
# literal keys passed to the localization helpers as well. Indirect/dynamic
# keys still need coverage at their call sites; unrelated string literals
# (such as filenames) are not localization references.
{
    for source_dir in \
        "$repo_root/TargetBridge-Sender/TBDisplaySender" \
        "$repo_root/TargetBridge-Sender/TBDisplayShared" \
        "$repo_root/TargetBridge-Receiver/TBReceiverC/src"; do
        [[ -d "$source_dir" ]] || continue
        find "$source_dir" -type f \( -name '*.swift' -o -name '*.c' -o -name '*.m' -o -name '*.h' \) \
            -exec jq -Rrs 'scan("(?s)\\b(?:text|tb_i18n_get|tb_i18n_format|tb_copy_i18n|tb_format_i18n)\\s*\\(\\s*(?:[^;\"{}]*?,\\s*)?\"((?:common|sender|receiver)\\.[A-Za-z0-9_.]+)\"") | .[0]' {} +
    done
} | LC_ALL=C sort -u > "$referenced_keys"
missing_references="$(comm -23 "$referenced_keys" "$source_keys")"
[[ -z "$missing_references" ]] || fail "source keys are absent from en.json: $(tr '\n' ' ' <<< "$missing_references")"

for language in "${languages[@]}"; do
    [[ "$language" == "en" ]] && continue

    file="$languages_dir/$language.json"
    translated_keys="$(mktemp)"
    jq -r 'keys[]' "$file" | LC_ALL=C sort > "$translated_keys"

    missing_keys="$(comm -23 "$source_keys" "$translated_keys")"
    extra_keys="$(comm -13 "$source_keys" "$translated_keys")"
    rm -f "$translated_keys"

    [[ -z "$missing_keys" ]] || fail "$language.json is missing keys: $(tr '\n' ' ' <<< "$missing_keys")"
    [[ -z "$extra_keys" ]] || fail "$language.json has unknown keys: $(tr '\n' ' ' <<< "$extra_keys")"

    while IFS=$'\t' read -r key source_value; do
        translated_value="$(jq -r --arg key "$key" '.[$key]' "$file")"
        source_tokens="$(grep -oE '%\{[[:alnum:]_]+\}' <<< "$source_value" | LC_ALL=C sort || true)"
        translated_tokens="$(grep -oE '%\{[[:alnum:]_]+\}' <<< "$translated_value" | LC_ALL=C sort || true)"

        if [[ "$source_tokens" != "$translated_tokens" ]]; then
            fail "$language.json has different placeholders for $key"
        fi
    done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' "$source_language")
done

if [[ "$status" -ne 0 ]]; then
    exit "$status"
fi

printf 'Localization check passed for %s.\n' "${languages[*]}"
