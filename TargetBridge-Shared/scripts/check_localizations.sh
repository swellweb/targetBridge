#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
languages_dir="$repo_root/TargetBridge-Shared/Languages"
source_language="$languages_dir/en.json"
languages=(de en it zh)
status=0

fail() {
    printf 'Localization check failed: %s\n' "$*" >&2
    status=1
}

for language in "${languages[@]}"; do
    file="$languages_dir/$language.json"
    if ! jq empty "$file"; then
        fail "$language.json is not valid JSON"
    fi
done

source_keys="$(mktemp)"
trap 'rm -f "$source_keys"' EXIT
jq -r 'keys[]' "$source_language" | LC_ALL=C sort > "$source_keys"

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
        source_tokens="$(grep -oE '%\\{[[:alnum:]_]+\\}' <<< "$source_value" | LC_ALL=C sort -u || true)"
        translated_tokens="$(grep -oE '%\\{[[:alnum:]_]+\\}' <<< "$translated_value" | LC_ALL=C sort -u || true)"

        if [[ "$source_tokens" != "$translated_tokens" ]]; then
            fail "$language.json has different placeholders for $key"
        fi
    done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' "$source_language")
done

if [[ "$status" -ne 0 ]]; then
    exit "$status"
fi

printf 'Localization check passed for %s.\n' "${languages[*]}"
