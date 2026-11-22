#!/usr/bin/env bash
set -euo pipefail

endpoint="repos/Stuhlmuller/homelab/rulesets"
desired_file="$(dirname "${BASH_SOURCE[0]}")/homelab-codex-review-ruleset.json"
name="$(jq -er '.name' "$desired_file")"

canonical() {
  jq -cS '{name, target, enforcement, bypass_actors, conditions, rules}'
}

desired="$(canonical < "$desired_file")"

matches() {
  [[ "$(canonical)" == "$desired" ]]
}

case "${1:---check}" in
  --check | --apply) ;;
  --self-test)
    matches < "$desired_file"
    for mutation in '.enforcement = "disabled"' \
      '.rules[0].parameters.required_status_checks[0].integration_id = 42' \
      '.bypass_actors = [{actor_id: 5015161, actor_type: "Integration", bypass_mode: "pull_request"}]'; do
      if jq "$mutation" "$desired_file" | matches; then
        echo "Unexpected ruleset accepted: $mutation" >&2
        exit 1
      fi
    done
    echo "Codex review ruleset fixtures passed"
    exit 0
    ;;
  *)
    echo "usage: $0 [--check|--apply|--self-test]" >&2
    exit 2
    ;;
esac

rulesets="$(gh api --paginate --slurp "$endpoint?includes_parents=false&per_page=100")"
ruleset_id="$(jq -er --arg name "$name" '
  [.[][] | select(.name == $name)] |
  if length == 0 then ""
  elif length == 1 and .[0].source_type == "Repository" and
    .[0].source == "Stuhlmuller/homelab" and .[0].target == "branch"
  then .[0].id | tostring
  else error("Ambiguous or unexpected Codex review ruleset identity")
  end
' <<< "$rulesets")"

if [[ -n "$ruleset_id" ]]; then
  [[ "$ruleset_id" =~ ^[0-9]+$ ]]
  live="$(gh api "$endpoint/$ruleset_id")"
  if matches <<< "$live"; then
    echo "Verified ruleset $ruleset_id"
    exit 0
  fi
fi

if [[ "${1:---check}" == --check ]]; then
  echo "Codex review ruleset is missing or differs from source" >&2
  exit 1
fi

if [[ -n "$ruleset_id" ]]; then
  gh api --method PUT "$endpoint/$ruleset_id" --input "$desired_file" >/dev/null
else
  ruleset_id="$(gh api --method POST "$endpoint" --input "$desired_file" --jq .id)"
fi
[[ "$ruleset_id" =~ ^[0-9]+$ ]]
live="$(gh api "$endpoint/$ruleset_id")"
matches <<< "$live"
echo "Verified ruleset $ruleset_id"
