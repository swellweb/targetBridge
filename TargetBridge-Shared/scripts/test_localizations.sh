#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/TargetBridge-Shared/"{Languages,scripts} \
    "$fixture/TargetBridge-Sender/TBDisplaySender"
cp "$script_dir/check_localizations.sh" "$fixture/TargetBridge-Shared/scripts/"
cat > "$fixture/TargetBridge-Sender/TBDisplaySender/Example.swift" <<'EOF'
let profile = text(
    "sender.profile.full_hd"
)
let unrelatedFilename = "receiver.log"
let session = text("sender.session_title")
let receiver = text("sender.receiver_summary")
EOF

reset_catalogs() {
    for language in de en fr it zh; do
        cat > "$fixture/TargetBridge-Shared/Languages/$language.json" <<'EOF'
{
  "sender.profile.full_hd": "Full HD",
  "sender.session_title": "Session %{index}",
  "sender.receiver_summary": "%{name}: %{id}"
}
EOF
    done
}

edit_catalog() {
    local language="$1" expression="$2"
    local file="$fixture/TargetBridge-Shared/Languages/$language.json"
    jq "$expression" "$file" > "$fixture/edited.json"
    mv "$fixture/edited.json" "$file"
}

checks=0
expect() {
    local expected="$1" label="$2" result=0
    bash "$fixture/TargetBridge-Shared/scripts/check_localizations.sh" > "$fixture/result.log" 2>&1 || result=$?
    if [[ "$expected" == pass && "$result" -ne 0 ]] || \
       [[ "$expected" == fail && "$result" -eq 0 ]]; then
        printf 'FAIL: %s (exit %s)\n' "$label" "$result" >&2
        cat "$fixture/result.log" >&2
        exit 1
    fi
    checks=$((checks + 1))
    printf 'PASS: %s\n' "$label"
}

reset_catalogs
expect pass 'valid catalogs'
edit_catalog it '.["sender.receiver_summary"] = "%{id} — %{name}"'
expect pass 'placeholder order and UTF-8 may differ'

reset_catalogs
edit_catalog it '.["sender.session_title"] = "Sessione %{indice}"'
expect fail 'renamed placeholder'
reset_catalogs
edit_catalog it '.["sender.session_title"] = "Sessione"'
expect fail 'missing placeholder'
reset_catalogs
edit_catalog it '.["sender.session_title"] = "Sessione %{index} %{index}"'
expect fail 'duplicated placeholder'
reset_catalogs
edit_catalog it 'del(.["sender.profile.full_hd"])'
expect fail 'key missing from one language'
reset_catalogs
for language in de en fr it zh; do
    edit_catalog "$language" 'del(.["sender.profile.full_hd"])'
done
expect fail 'referenced key missing from every language'
reset_catalogs
mkdir -p "$fixture/TargetBridge-Receiver/TBReceiverC/src"
cat > "$fixture/TargetBridge-Receiver/TBReceiverC/src/Example.c" <<'EOF'
tb_copy_i18n(buffer, sizeof(buffer), "receiver.status.unknown");
EOF
expect fail 'literal C helper key missing from every language'
rm "$fixture/TargetBridge-Receiver/TBReceiverC/src/Example.c"
reset_catalogs
edit_catalog it '.unexpected = "Extra"'
expect fail 'unknown key'
reset_catalogs
edit_catalog it '.["sender.profile.full_hd"] = "  "'
expect fail 'empty text'
reset_catalogs
edit_catalog it '.["sender.profile.full_hd"] = 42'
expect fail 'non-string text'
reset_catalogs
printf '{ invalid json' > "$fixture/TargetBridge-Shared/Languages/it.json"
expect fail 'invalid JSON'
reset_catalogs
sed '$s/}/, "sender.profile.full_hd": "Duplicate"}/' "$fixture/TargetBridge-Shared/Languages/it.json" > "$fixture/duplicate.json"
mv "$fixture/duplicate.json" "$fixture/TargetBridge-Shared/Languages/it.json"
expect fail 'duplicate JSON key'
printf '%s localization checker regressions passed.\n' "$checks"
