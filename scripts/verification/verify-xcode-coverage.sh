#!/bin/bash
# SPDX-License-Identifier: MIT
# Normalizes xccov JSON and enforces conservative whole-file floors for changed app/UI sources.

set -euo pipefail

fail() {
    echo "verify-xcode-coverage: $*" >&2
    exit 2
}

base_ref=""
output=""
reports=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-ref)
            [[ $# -ge 2 ]] || fail "--base-ref requires a value"
            base_ref="$2"
            shift 2
            ;;
        --report)
            [[ $# -ge 2 ]] || fail "--report requires a value"
            reports+=("$2")
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || fail "--output requires a value"
            output="$2"
            shift 2
            ;;
        *) fail "unknown option: $1" ;;
    esac
done

[[ -n "$base_ref" ]] || fail "--base-ref is required"
[[ -n "$output" ]] || fail "--output is required"
[[ ${#reports[@]} -gt 0 ]] || fail "at least one --report is required"

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
repo_root="$(cd "$script_dir/../.." && pwd -P)"
git -C "$repo_root" rev-parse --verify "$base_ref^{commit}" >/dev/null 2>&1 \
    || fail "--base-ref does not resolve to a commit: $base_ref"
comparison_base="$(git -C "$repo_root" merge-base "$base_ref" HEAD)"

for report in "${reports[@]}"; do
    [[ -s "$report" ]] || fail "missing or empty xccov report: $report"
    jq -e '.targets | type == "array" and length > 0' "$report" >/dev/null \
        || fail "xccov report has no targets: $report"
done

changed_sources=()
while IFS= read -r path; do
    case "$path" in
        App/*.swift|App/**/*.swift|Packages/AppRuntime/Sources/*.swift|Packages/AppRuntime/Sources/**/*.swift|Packages/AppUI/Sources/*.swift|Packages/AppUI/Sources/**/*.swift|Packages/MobileLLMUI/Sources/*.swift|Packages/MobileLLMUI/Sources/**/*.swift)
            changed_sources+=("$path")
            ;;
    esac
done < <(git -C "$repo_root" -c core.quotePath=false diff --name-only "$comparison_base" -- '*.swift')

mkdir -p "$(dirname "$output")"
scratch="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/mobilellm-xccov.XXXXXX")"
trap '/bin/rm -rf -- "$scratch"' EXIT
metrics="$scratch/metrics.jsonl"
: > "$metrics"

for source in "${changed_sources[@]}"; do
    match=""
    for report in "${reports[@]}"; do
        candidate="$(jq -c --arg suffix "/$source" '
            [.targets[].files[]? | select(.path | endswith($suffix))] | first // empty
        ' "$report")"
        if [[ -n "$candidate" ]]; then
            match="$candidate"
            break
        fi
    done
    [[ -n "$match" ]] || fail "changed app/UI source is absent from xccov evidence: $source"

    line_percent="$(jq -r '(.lineCoverage // 0) * 100' <<<"$match")"
    function_total="$(jq -r '(.functions // []) | length' <<<"$match")"
    function_covered="$(jq -r '[.functions[]? | select((.lineCoverage // 0) > 0)] | length' <<<"$match")"
    function_percent="$(jq -n --argjson covered "$function_covered" --argjson total "$function_total" \
        'if $total == 0 then 100 else ($covered * 100 / $total) end')"
    jq -n \
        --arg source "$source" \
        --argjson linePercent "$line_percent" \
        --argjson functionPercent "$function_percent" \
        '{source: $source, linePercent: $linePercent, functionPercent: $functionPercent}' \
        >> "$metrics"

    jq -e '(.lineCoverage // 0) >= 0.90' <<<"$match" >/dev/null \
        || fail "changed source line coverage is below 90%: $source ($line_percent%)"
    jq -n -e --argjson value "$function_percent" '$value >= 90' >/dev/null \
        || fail "changed source function coverage is below 90%: $source ($function_percent%)"
done

source_commit="$(git -C "$repo_root" rev-parse HEAD)"
spec_sha256="$(/usr/bin/shasum -a 256 "$repo_root/spec.md" | /usr/bin/awk '{print $1}')"
jq -s \
    --arg sourceCommit "$source_commit" \
    --arg comparisonBase "$comparison_base" \
    --arg specSHA256 "$spec_sha256" \
    '{schemaVersion: 1, sourceCommit: $sourceCommit, comparisonBase: $comparisonBase,
      specSHA256: $specSHA256, floorPercent: 90, changedAppAndUISources: .}' \
    "$metrics" > "$output"

echo "Xcode coverage evidence: $output"
