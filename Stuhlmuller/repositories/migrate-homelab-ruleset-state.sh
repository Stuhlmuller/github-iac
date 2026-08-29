#!/usr/bin/env bash
set -euo pipefail

mode="${1:---check}"
old_address='github_repository_ruleset.this["homelab.main"]'
new_address='github_repository_ruleset.existing["homelab.main"]'
ruleset_id="14700233"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

case "$mode" in
  --apply | --check) ;;
  *)
    echo "usage: $0 [--check|--apply]" >&2
    exit 2
    ;;
esac

for command_name in jq terragrunt; do
  command -v "$command_name" >/dev/null || {
    echo "$command_name is required" >&2
    exit 1
  }
done

cd "$script_dir"
terragrunt --log-disable init -reconfigure -input=false

state_addresses="$(terragrunt --log-disable state list)"
has_address() {
  grep -Fqx -- "$1" <<<"$state_addresses"
}

verify_address() {
  terragrunt --log-disable show -json |
    jq -e --arg address "$1" --arg ruleset_id "$ruleset_id" '
      [.. | objects
        | select(.address? == $address and .mode? == "managed" and .type? == "github_repository_ruleset")
        | .values] as $matches
      | ($matches | length) == 1
      and $matches[0].repository == "homelab"
      and (
        (($matches[0].ruleset_id // "") | tostring) == $ruleset_id
        or (($matches[0].id // "") | tostring) == $ruleset_id
        or (($matches[0].id // "") | tostring) == "homelab:\($ruleset_id)"
      )
    ' >/dev/null
}

if has_address "$new_address"; then
  if has_address "$old_address"; then
    echo "error: both homelab ruleset state addresses exist" >&2
    exit 1
  fi
  verify_address "$new_address"
  echo "homelab ruleset state is already migrated"
  exit 0
fi

if ! has_address "$old_address"; then
  echo "error: neither homelab ruleset state address exists" >&2
  exit 1
fi
verify_address "$old_address"

if [[ "$mode" == "--check" ]]; then
  echo "error: run this reviewed script with --apply before dispatching the targeted deployment" >&2
  exit 1
fi

terragrunt --log-disable state mv -dry-run "$old_address" "$new_address"
terragrunt --log-disable state mv -lock-timeout=5m "$old_address" "$new_address"

state_addresses="$(terragrunt --log-disable state list)"
if has_address "$old_address" || ! has_address "$new_address"; then
  echo "error: homelab ruleset state migration did not finish exactly" >&2
  exit 1
fi
verify_address "$new_address"
echo "homelab ruleset state migrated to $new_address"
