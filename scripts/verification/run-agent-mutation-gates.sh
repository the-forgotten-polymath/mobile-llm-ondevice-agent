#!/bin/bash
# SPDX-License-Identifier: MIT
# TEST-ID: AHT-TEST-001

set -euo pipefail

fail() {
    echo "run-agent-mutation-gates: $*" >&2
    exit 2
}

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
repo_root="$(cd "$script_dir/../.." && pwd -P)"
manifest="$repo_root/Verification/AgentHarness/Mutations/mutations.v1.json"
[[ -s "$manifest" ]] || fail "mutation manifest is missing"
command -v jq >/dev/null || fail "jq is required"

scratch_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/mobilellm-agent-mutations.XXXXXX")"
cleanup() { /bin/rm -rf -- "$scratch_root"; }
trap cleanup EXIT

/bin/mkdir -p "$scratch_root/Packages"
for package in AgentContracts AgentRuntime LLMCore AppRuntime; do
    /usr/bin/ditto "$repo_root/Packages/$package" "$scratch_root/Packages/$package"
done

mutation_count="$(jq '.mutations | length' "$manifest")"
[[ "$mutation_count" -eq 6 ]] || fail "the curated suite must contain exactly six release mutations"

for index in $(/usr/bin/jot - 0 $((mutation_count - 1))); do
    id="$(jq -r ".mutations[$index].id" "$manifest")"
    package="$(jq -r ".mutations[$index].package" "$manifest")"
    relative_file="$(jq -r ".mutations[$index].file" "$manifest")"
    test_filter="$(jq -r ".mutations[$index].testFilter" "$manifest")"
    source_file="$scratch_root/$relative_file"
    canonical_file="$repo_root/$relative_file"
    original_file="$scratch_root/original.txt"
    replacement_file="$scratch_root/replacement.txt"
    log_file="$scratch_root/$id.log"

    [[ -f "$source_file" && -f "$canonical_file" ]] || fail "$id source file is missing"
    /bin/cp "$canonical_file" "$source_file"
    jq -j ".mutations[$index].original" "$manifest" >"$original_file"
    jq -j ".mutations[$index].replacement" "$manifest" >"$replacement_file"

    /usr/bin/ruby -e '
      path, original_path, replacement_path = ARGV
      source = File.binread(path)
      original = File.binread(original_path)
      replacement = File.binread(replacement_path)
      count = source.scan(original).length
      abort("mutation original must occur exactly once; found #{count}") unless count == 1
      File.binwrite(path, source.sub(original, replacement))
    ' "$source_file" "$original_file" "$replacement_file" || fail "$id could not be applied exactly"

    set +e
    swift test \
        --package-path "$scratch_root/Packages/$package" \
        --scratch-path "$scratch_root/build-$package" \
        --filter "$test_filter" >"$log_file" 2>&1
    test_status=$?
    set -e
    if [[ $test_status -eq 0 ]]; then
        /bin/cat "$log_file" >&2
        fail "$id survived $test_filter"
    fi
    if ! /usr/bin/grep -Eq "Test Case .*${test_filter#*/}.* failed" "$log_file"; then
        /bin/cat "$log_file" >&2
        fail "$id did not reach and fail its sentinel test (compile/setup failures do not count)"
    fi
    echo "$id killed by $test_filter"
done

echo "Agent Harness mutation verification passed ($mutation_count/6 killed)."
