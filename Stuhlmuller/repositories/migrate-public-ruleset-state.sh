#!/usr/bin/env bash
set -euo pipefail

mode="${1:---check}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
manifest_file="$script_dir/public-rulesets.json"

case "$mode" in
  --apply | --check | --self-test) ;;
  *)
    echo "usage: $0 [--check|--apply|--self-test]" >&2
    exit 2
    ;;
esac

has_address() {
  grep -Fqx -- "$1" <<<"$state_addresses"
}

verify_address() {
  local address="$1" repository="$2" ruleset_id="$3"

  jq -e --arg address "$address" --arg repository "$repository" --arg ruleset_id "$ruleset_id" '
    [.. | objects
      | select(.address? == $address and .mode? == "managed" and .type? == "github_repository_ruleset")
      | .values] as $matches
    | ($matches | length) == 1
    and $matches[0].repository == $repository
    and $matches[0].name == "main"
    and ($matches[0].ruleset_id != null or $matches[0].id != null)
    and ($matches[0].ruleset_id == null or ($matches[0].ruleset_id | tostring) == $ruleset_id)
    and ($matches[0].id == null or (
      ($matches[0].id | tostring) == $ruleset_id
      or ($matches[0].id | tostring) == "\($repository):\($ruleset_id)"
    ))
  ' <<<"$state_json" >/dev/null
}

verify_ruleset_count() {
  local expected_count="$1"

  jq -e --argjson expected_count "$expected_count" '
    [.. | objects
      | select(.address? != null and .mode? == "managed" and .type? == "github_repository_ruleset")]
    | length == $expected_count
  ' <<<"$state_json" >/dev/null
}

collect_pending_moves() {
  pending=()
  for entry in "${rulesets[@]}"; do
    repository="${entry%%|*}"
    ruleset_id="${entry#*|}"
    key="$repository.main"
    old_address="github_repository_ruleset.this[\"$key\"]"
    new_address="github_repository_ruleset.existing[\"$key\"]"

    if has_address "$new_address"; then
      if has_address "$old_address"; then
        echo "error: both ruleset state addresses exist for $repository" >&2
        return 1
      fi
      verify_address "$new_address" "$repository" "$ruleset_id" || return 1
    elif has_address "$old_address"; then
      verify_address "$old_address" "$repository" "$ruleset_id" || return 1
      pending+=("$old_address|$new_address")
    else
      echo "error: neither ruleset state address exists for $repository" >&2
      return 1
    fi
  done
}

make_fixture_state() {
  jq -cn --arg resource_name "$1" --slurpfile manifest "$manifest_file" '
    {values: {root_module: {resources: [
      $manifest[0][]
      | .repository as $repository
      | .ruleset_id as $ruleset_id
      | {
          address: "github_repository_ruleset.\($resource_name)[\"\($repository).main\"]",
          mode: "managed",
          type: "github_repository_ruleset",
          values: {
            repository: $repository,
            name: "main",
            ruleset_id: $ruleset_id,
            id: ($ruleset_id | tostring)
          }
        }
    ]}}}
  '
}

command -v jq >/dev/null || {
  echo "jq is required" >&2
  exit 1
}
jq -e '
  type == "array"
  and length == 11
  and ([.[].repository] | unique | length) == length
  and ([.[].ruleset_id] | unique | length) == length
  and all(.[];
    (.repository | type) == "string"
    and (.repository | test("^[A-Za-z0-9._-]+$"))
    and (.ruleset_id | type) == "number"
    and (.ruleset_id | floor) == .ruleset_id
    and .ruleset_id > 0)
' "$manifest_file" >/dev/null
rulesets=()
while IFS='|' read -r repository ruleset_id; do
  rulesets+=("$repository|$ruleset_id")
done < <(jq -r '.[] | [.repository, (.ruleset_id | tostring)] | join("|")' "$manifest_file")

if [[ "$mode" == "--self-test" ]]; then
  old_state="$(make_fixture_state this)"
  state_json="$old_state"
  state_addresses="$(jq -r '.values.root_module.resources[].address' <<<"$state_json")"
  verify_ruleset_count 11
  collect_pending_moves
  (( ${#pending[@]} == 11 ))
  [[ "${pending[0]}" == 'github_repository_ruleset.this[".github.main"]|github_repository_ruleset.existing[".github.main"]' ]]

  state_json="$(jq '.values.root_module.resources[0].values.id = "999"' <<<"$old_state")"
  if verify_address 'github_repository_ruleset.this[".github.main"]' .github 11493159; then
    echo "conflicting ruleset identity fixture unexpectedly passed" >&2
    exit 1
  fi

  state_json="$(jq '
    .values.root_module.resources += [
      (.values.root_module.resources[]
        | select(.values.repository == "homelab")
        | .address = "github_repository_ruleset.existing[\"homelab.main\"]")
    ]
  ' <<<"$old_state")"
  state_addresses="$(jq -r '.values.root_module.resources[].address' <<<"$state_json")"
  if verify_ruleset_count 11; then
    echo "duplicate ruleset fixture unexpectedly passed" >&2
    exit 1
  fi
  if collect_pending_moves 2>/dev/null; then
    echo "dual-address ruleset fixture unexpectedly passed" >&2
    exit 1
  fi

  state_json="$(jq '.values.root_module.resources[0].address = "github_repository_ruleset.existing[\"unrelated.main\"]"' <<<"$old_state")"
  state_addresses="$(jq -r '.values.root_module.resources[].address' <<<"$state_json")"
  if collect_pending_moves 2>/dev/null; then
    echo "missing-address ruleset fixture unexpectedly passed" >&2
    exit 1
  fi

  state_json="$(jq '(.values.root_module.resources[] | select(.values.repository == "homelab") | .address) = "github_repository_ruleset.existing[\"homelab.main\"]"' <<<"$old_state")"
  state_addresses="$(jq -r '.values.root_module.resources[].address' <<<"$state_json")"
  collect_pending_moves
  (( ${#pending[@]} == 10 ))

  state_json="$(make_fixture_state existing)"
  state_addresses="$(jq -r '.values.root_module.resources[].address' <<<"$state_json")"
  collect_pending_moves
  (( ${#pending[@]} == 0 ))

  echo "public ruleset state policy fixtures passed"
  exit 0
fi

command -v terragrunt >/dev/null || {
  echo "terragrunt is required" >&2
  exit 1
}

cd "$script_dir"
terragrunt --log-disable init -reconfigure -input=false

state_addresses="$(terragrunt --log-disable state list)"
state_json="$(terragrunt --log-disable show -json)"
verify_ruleset_count "${#rulesets[@]}"
collect_pending_moves

if (( ${#pending[@]} == 0 )); then
  echo "all 11 public ruleset state addresses are already migrated"
  exit 0
fi

if [[ "$mode" == "--check" ]]; then
  echo "error: run this reviewed script with --apply before the targeted deployment" >&2
  exit 1
fi

for move in "${pending[@]}"; do
  old_address="${move%%|*}"
  new_address="${move#*|}"
  terragrunt --log-disable state mv -dry-run "$old_address" "$new_address"
done

for move in "${pending[@]}"; do
  old_address="${move%%|*}"
  new_address="${move#*|}"
  terragrunt --log-disable state mv -lock-timeout=5m "$old_address" "$new_address"
done

state_addresses="$(terragrunt --log-disable state list)"
state_json="$(terragrunt --log-disable show -json)"
verify_ruleset_count "${#rulesets[@]}"
for entry in "${rulesets[@]}"; do
  repository="${entry%%|*}"
  ruleset_id="${entry#*|}"
  key="$repository.main"
  old_address="github_repository_ruleset.this[\"$key\"]"
  new_address="github_repository_ruleset.existing[\"$key\"]"
  if has_address "$old_address" || ! has_address "$new_address"; then
    echo "error: ruleset state migration did not finish exactly for $repository" >&2
    exit 1
  fi
  verify_address "$new_address" "$repository" "$ruleset_id"
done

echo "all 11 public ruleset state addresses are migrated"
