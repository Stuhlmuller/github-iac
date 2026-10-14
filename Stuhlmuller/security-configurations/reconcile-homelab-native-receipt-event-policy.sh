#!/usr/bin/env bash
set -euo pipefail

mode="${1:---check}"
organization="Stuhlmuller"
repository="homelab"
policy_name="Allow native receipt provenance events"
policy_endpoint="repos/$organization/$repository/actions/policies"
policy_collection_path="$policy_endpoint?has_parents=true"
workflow_path=".github/workflows/harbor-native-chainguard-receipt-provenance.yml"
api_version="2026-03-10"

case "$mode" in
  --apply | --check | --self-test) ;;
  *)
    echo "usage: $0 [--check|--apply|--self-test]" >&2
    exit 2
    ;;
esac

required_commands=(jq)
if [[ "$mode" != "--self-test" ]]; then
  required_commands+=(gh)
fi
for command_name in "${required_commands[@]}"; do
  command -v "$command_name" >/dev/null || {
    echo "$command_name is required" >&2
    exit 1
  }
done

desired_policy="$(jq -cn \
  --arg name "$policy_name" \
  --arg workflow_path "$workflow_path" \
  '{
    name: $name,
    enforcement: "active",
    conditions: {
      workflow_path: {include: [$workflow_path], exclude: []}
    },
    rules: [{
      type: "restrict_action_events",
      parameters: {allowed_events: ["pull_request_target", "push"]}
    }]
  }'
)"

canonical_policy() {
  jq -S -c '
    del(.id, .target, .source_type, .source, .node_id, ._links,
        .created_at, .updated_at)
    | walk(if type == "array" then sort_by(tojson) else . end)
  '
}

canonical_target_and_events() {
  jq -S -c '
    {name, conditions, rules}
    | walk(if type == "array" then sort_by(tojson) else . end)
  '
}

desired_canonical="$(canonical_policy <<<"$desired_policy")"
desired_target_and_events="$(canonical_target_and_events <<<"$desired_policy")"

github_api() {
  gh api \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: $api_version" \
    "$@"
}

list_policy_summaries() {
  github_api --method GET "$policy_collection_path" -f per_page=100
}

get_policy() {
  local policy_id="$1"

  [[ "$policy_id" =~ ^[0-9]+$ ]] || {
    echo "invalid Actions policy id: $policy_id" >&2
    return 1
  }
  github_api --method GET "$policy_endpoint/$policy_id"
}

get_policy_detail() {
  local summary="$1"
  local policy_id=""
  local source_type=""
  local self_href=""
  local expected_self_href=""
  local detail=""

  policy_id="$(jq -r '.id // empty' <<<"$summary")"
  source_type="$(jq -r '.source_type // empty' <<<"$summary")"
  self_href="$(jq -r '._links.self.href // empty' <<<"$summary")"
  [[ "$policy_id" =~ ^[0-9]+$ ]] || {
    echo "invalid Actions policy summary id" >&2
    return 1
  }
  [[ -n "$source_type" && -n "$self_href" ]] || {
    echo "incomplete Actions policy summary" >&2
    return 1
  }

  if [[ "$source_type" == "Repository" ]]; then
    expected_self_href="https://api.github.com/repos/$organization/$repository/actions/policies/$policy_id"
    [[ "$self_href" == "$expected_self_href" ]] || {
      echo "repository Actions policy has an unexpected source URL" >&2
      return 1
    }
  fi
  detail="$(get_policy "$policy_id")"

  jq -e \
    --argjson policy_id "$policy_id" \
    --arg source_type "$source_type" \
    --arg self_href "$self_href" '
      .id == $policy_id
      and .target == "actions"
      and .source_type == $source_type
      and ._links.self.href == $self_href
    ' <<<"$detail" >/dev/null || {
    echo "Actions policy detail does not match its listed source" >&2
    return 1
  }
  printf '%s\n' "$detail"
}

policy_snapshot() {
  local list=""
  local summary=""
  local details=()

  list="$(list_policy_summaries)"
  jq -e '
    type == "object"
    and (.total_count | type) == "number"
    and (.policies | type) == "array"
    and .total_count == (.policies | length)
    and all(.policies[];
      (.id | type) == "number"
      and .id > 0
      and (.source_type | type) == "string"
      and (._links.self.href | type) == "string")
  ' <<<"$list" >/dev/null || {
    echo "Actions policy list is incomplete or malformed" >&2
    return 1
  }

  while IFS= read -r summary; do
    details+=("$(get_policy_detail "$summary")")
  done < <(jq -c '.policies[]' <<<"$list")

  if [[ "${#details[@]}" -eq 0 ]]; then
    printf '%s\n' '[]'
    return 0
  fi

  printf '%s\n' "${details[@]}" |
    jq -s -S -c '
      map({
        id,
        name,
        target,
        source_type,
        source,
        enforcement,
        conditions: (.conditions // {}),
        rules: (.rules // []),
        _links: (._links // {})
      })
      | map(walk(if type == "array" then sort_by(tojson) else . end))
      | sort_by(.id)
    '
}

require_repository_owned_policy() {
  local policy="$1"
  local policy_id=""
  local expected_self_href=""

  policy_id="$(jq -r '.id // empty' <<<"$policy")"
  [[ "$policy_id" =~ ^[0-9]+$ ]] || return 1
  expected_self_href="https://api.github.com/repos/$organization/$repository/actions/policies/$policy_id"

  jq -e --arg expected_self_href "$expected_self_href" '
      .target == "actions"
      and .source_type == "Repository"
      and ._links.self.href == $expected_self_href
    ' <<<"$policy" >/dev/null
}

require_safe_update_policy() {
  local policy="$1"

  require_repository_owned_policy "$policy" || return 1
  [[ "$(canonical_target_and_events <<<"$policy")" == "$desired_target_and_events" ]] ||
    return 1
  jq -e '.enforcement == "active" or .enforcement == "evaluate" or .enforcement == "disabled"' \
    <<<"$policy" >/dev/null
}

require_active_policy() {
  local policy="$1"

  require_safe_update_policy "$policy" || return 1
  jq -e '.enforcement == "active"' <<<"$policy" >/dev/null || return 1
  [[ "$(canonical_policy <<<"$policy")" == "$desired_canonical" ]]
}

policy_workflow_scope() {
  jq -r --arg workflow_path "$workflow_path" '
    def has_glob:
      contains("*") or contains("?") or contains("[");

    (.conditions // {}) as $conditions
    | if ($conditions | type) != "object" then "unknown"
      elif ($conditions | has("workflow_path") | not) then "matches"
      elif ($conditions.workflow_path | type) != "object" then "unknown"
      elif (($conditions.workflow_path | keys | sort) != ["exclude", "include"]) then "unknown"
      elif (($conditions.workflow_path.include | type) != "array")
        or (($conditions.workflow_path.exclude | type) != "array") then "unknown"
      elif (all($conditions.workflow_path.include[]; type == "string") | not)
        or (all($conditions.workflow_path.exclude[]; type == "string") | not) then "unknown"
      elif ($conditions.workflow_path.exclude | index($workflow_path)) != null then "does-not-match"
      elif any($conditions.workflow_path.exclude[]; has_glob) then "unknown"
      elif ($conditions.workflow_path.include | length) == 0 then "matches"
      elif ($conditions.workflow_path.include | index("~ALL")) != null then
        if ($conditions.workflow_path.include | length) == 1 then "matches" else "unknown" end
      elif ($conditions.workflow_path.include | index($workflow_path)) != null then "matches"
      elif any($conditions.workflow_path.include[]; has_glob) then "unknown"
      else "does-not-match"
      end
  '
}

require_events_if_policy_may_apply() {
  local policy="$1"
  local scope=""

  scope="$(policy_workflow_scope <<<"$policy")"
  case "$scope" in
    does-not-match)
      return 0
      ;;
    matches)
      ;;
    *)
      echo "cannot determine whether an active Actions policy applies to $workflow_path" >&2
      return 1
      ;;
  esac

  jq -e '
    (.rules | type) == "array"
    and all(
      .rules[];
      .type == "restrict_action_events"
      and (.parameters | type) == "object"
      and (.parameters.allowed_events | type) == "array"
      and (.parameters.allowed_events | index("pull_request_target")) != null
      and (.parameters.allowed_events | index("push")) != null
    )
  ' <<<"$policy" >/dev/null || {
    echo "an active Actions policy can block required native receipt execution" >&2
    return 1
  }
}

validate_effective_event_policies() {
  local snapshot="$1"
  local policy=""

  while IFS= read -r policy; do
    if [[ "$(jq -r '.enforcement // empty' <<<"$policy")" == active ]]; then
      require_events_if_policy_may_apply "$policy"
    fi
  done < <(jq -c '.[]' <<<"$snapshot")
}

classify_snapshot() {
  local snapshot="$1"
  local matches=""
  local match_count=""
  local policy=""
  local policy_id=""

  matches="$(jq -c --arg name "$policy_name" '[.[] | select(.name == $name)]' <<<"$snapshot")"
  match_count="$(jq length <<<"$matches")"
  if [[ "$match_count" -eq 0 ]]; then
    printf '%s\n' create
    return 0
  fi
  if [[ "$match_count" -ne 1 ]]; then
    echo "expected at most one $policy_name policy, found $match_count" >&2
    return 1
  fi

  policy="$(jq -c '.[0]' <<<"$matches")"
  require_safe_update_policy "$policy" || {
    echo "$policy_name is not an exact repository-owned policy with the required workflow path and events" >&2
    return 1
  }
  policy_id="$(jq -r .id <<<"$policy")"

  if require_active_policy "$policy"; then
    printf 'active:%s\n' "$policy_id"
  else
    printf 'update:%s\n' "$policy_id"
  fi
}

post_policy() {
  printf '%s\n' "$desired_policy" |
    github_api --method POST "$policy_endpoint" --input - >/dev/null
}

put_policy() {
  local policy_id="$1"

  [[ "$policy_id" =~ ^[0-9]+$ ]] || {
    echo "invalid Actions policy id: $policy_id" >&2
    return 1
  }
  printf '%s\n' "$desired_policy" |
    github_api --method PUT "$policy_endpoint/$policy_id" --input - >/dev/null
}

reconcile() {
  local before=""
  local action=""
  local preapply=""
  local preapply_action=""
  local policy_id=""
  local after=""
  local after_action=""

  before="$(policy_snapshot)"
  validate_effective_event_policies "$before" || return 1
  action="$(classify_snapshot "$before")"

  if [[ "$mode" == "--check" ]]; then
    if [[ "$action" == active:* ]]; then
      echo "$policy_name is active and exact"
      return 0
    fi
    echo "$policy_name needs reconciliation: $action" >&2
    return 1
  fi

  if [[ "$action" == active:* ]]; then
    echo "$policy_name is already active and exact"
    return 0
  fi

  preapply="$(policy_snapshot)"
  [[ "$preapply" == "$before" ]] || {
    echo "Actions policy state changed before reconciliation" >&2
    return 1
  }
  validate_effective_event_policies "$preapply" || return 1
  preapply_action="$(classify_snapshot "$preapply")"
  [[ "$preapply_action" == "$action" ]] || {
    echo "Actions policy target changed before reconciliation" >&2
    return 1
  }

  case "$action" in
    create)
      post_policy
      ;;
    update:*)
      policy_id="${action#update:}"
      put_policy "$policy_id"
      ;;
    *)
      echo "unexpected Actions policy reconciliation action: $action" >&2
      return 1
      ;;
  esac

  after="$(policy_snapshot)"
  validate_effective_event_policies "$after" || return 1
  after_action="$(classify_snapshot "$after")"
  [[ "$after_action" == active:* ]] || {
    echo "$policy_name did not read back as active" >&2
    return 1
  }
  if [[ "$action" == update:* ]]; then
    [[ "$after_action" == "active:${action#update:}" ]] || {
      echo "$policy_name changed identity during reconciliation" >&2
      return 1
    }
  fi

  echo "$policy_name is active and exact"
}

self_test() {
  local valid=""
  local wrong_event=""
  local broad_path=""
  local wrong_path=""
  local duplicate=""
  local parent_collision=""
  local unexpected_source=""
  local inactive=""
  local unrelated=""
  local inherited_blocking=""
  local inherited_allowed=""
  local inherited_valid=""
  local actor_blocking=""

  make_repository_policy() {
    local policy_id="$1"
    local enforcement="${2:-active}"

    jq -cn \
      --argjson desired "$desired_policy" \
      --argjson policy_id "$policy_id" \
      --arg enforcement "$enforcement" \
      --arg source "$repository" \
      --arg self_href "https://api.github.com/repos/$organization/$repository/actions/policies/$policy_id" '
      $desired + {
        id: $policy_id,
        target: "actions",
        source_type: "Repository",
        source: $source,
        enforcement: $enforcement,
        _links: {self: {href: $self_href}}
      }
    '
  }

  setup_mock() {
    mock_before_details="$1"
    mock_preapply_details="$2"
    mock_after_details="$3"
    mock_state_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-native-receipt-policy.XXXXXX")"
    printf '%s\n' false >"$mock_state_dir/mutated"
    printf '%s\n' 0 >"$mock_state_dir/collection_calls"
    printf '%s\n' 0 >"$mock_state_dir/post_calls"
    printf '%s\n' 0 >"$mock_state_dir/put_calls"
    printf '%s\n' '[]' >"$mock_state_dir/list_details.json"
  }

  teardown_mock() {
    rm -rf -- "$mock_state_dir"
  }

  mock_count() {
    cat "$mock_state_dir/$1"
  }

  mock_increment() {
    local file="$1"
    local count=""

    count="$(mock_count "$file")"
    printf '%s\n' "$((count + 1))" >"$mock_state_dir/$file"
  }

  mock_details_for_list() {
    local calls=""

    calls="$(mock_count collection_calls)"
    if [[ "$(<"$mock_state_dir/mutated")" == true ]]; then
      printf '%s\n' "$mock_after_details"
    elif [[ "$calls" -gt 1 ]]; then
      printf '%s\n' "$mock_preapply_details"
    else
      printf '%s\n' "$mock_before_details"
    fi
  }

  github_api() {
    local arguments="$*"
    local policy_id=""
    local details=""
    local payload=""

    if [[ "$arguments" == *"$policy_collection_path"* ]]; then
      mock_increment collection_calls
      details="$(mock_details_for_list)"
      printf '%s\n' "$details" >"$mock_state_dir/list_details.json"
      jq -c '{total_count: length, policies: map({id, name, target, source_type, source, enforcement, _links})}' \
        <<<"$details"
      return 0
    fi

    if [[ "$arguments" =~ --method[[:space:]]POST ]]; then
      payload="$(cat)"
      [[ "$(canonical_policy <<<"$payload")" == "$desired_canonical" ]] || {
        echo "unexpected POST payload" >&2
        return 1
      }
      mock_increment post_calls
      printf '%s\n' true >"$mock_state_dir/mutated"
      jq -ce '.[0]' <<<"$mock_after_details"
      return 0
    fi

    if [[ "$arguments" =~ --method[[:space:]]PUT ]]; then
      payload="$(cat)"
      [[ "$(canonical_policy <<<"$payload")" == "$desired_canonical" ]] || {
        echo "unexpected PUT payload" >&2
        return 1
      }
      mock_increment put_calls
      printf '%s\n' true >"$mock_state_dir/mutated"
      jq -ce '.[0]' <<<"$mock_after_details"
      return 0
    fi

    if [[ "$arguments" =~ --method[[:space:]]GET[[:space:]]repos/Stuhlmuller/homelab/actions/policies/([0-9]+) ]]; then
      policy_id="${BASH_REMATCH[1]}"
      jq -ce --argjson policy_id "$policy_id" '
        [.[] | select(.id == $policy_id)]
        | if length == 1 then .[0] else error("missing mock policy") end
      ' "$mock_state_dir/list_details.json"
      return 0
    fi

    if [[ "$arguments" == *"actions/policies/"* ]]; then
      echo "policy details must use the repository endpoint" >&2
      return 1
    fi

    echo "unexpected mock API call: $arguments" >&2
    return 1
  }

  assert_mock_counts() {
    local expected_post="$1"
    local expected_put="$2"

    [[ "$(mock_count post_calls)" -eq "$expected_post" ]]
    [[ "$(mock_count put_calls)" -eq "$expected_put" ]]
  }

  valid="$(make_repository_policy 123)"
  inactive="$(make_repository_policy 123 evaluate)"
  wrong_event="$(jq '(.rules[0].parameters.allowed_events) = ["push"]' <<<"$valid")"
  broad_path="$(jq '(.conditions.workflow_path.include) = ["~ALL"]' <<<"$valid")"
  wrong_path="$(jq '(.conditions.workflow_path.include) = [".github/workflows/other.yml"]' <<<"$valid")"
  duplicate="$(jq -cn --argjson first "$valid" --argjson second "$(make_repository_policy 456)" '[$first, $second]')"
  parent_collision="$(jq -cn --argjson direct "$valid" --argjson parent "$(jq -cn \
    --argjson desired "$desired_policy" \
    '{
      id: 456,
      target: "actions",
      source_type: "Organization",
      source: "Stuhlmuller",
      _links: {self: {href: "https://api.github.com/orgs/Stuhlmuller/actions/policies/456"}}
    } + $desired
  ')" '[$direct, $parent]')"
  unexpected_source="$(jq -cn --argjson desired "$desired_policy" '{
    id: 123,
    target: "actions",
    source_type: "Organization",
    source: "Stuhlmuller",
    _links: {self: {href: "https://api.github.com/orgs/Stuhlmuller/actions/policies/123"}}
  } + $desired')"
  unrelated="$(jq -cn '[{
    id: 999,
    name: "Unrelated Actions policy",
    target: "actions",
    source_type: "Repository",
    source: "homelab",
    enforcement: "active",
    conditions: {workflow_path: {include: [".github/workflows/other.yml"], exclude: []}},
    rules: [{type: "restrict_action_events", parameters: {allowed_events: ["push"]}}],
    _links: {self: {href: "https://api.github.com/repos/Stuhlmuller/homelab/actions/policies/999"}}
  }]')"
  inherited_blocking="$(jq -cn '[{
    id: 998,
    name: "Inherited blocking policy",
    target: "actions",
    source_type: "Organization",
    source: "Stuhlmuller",
    enforcement: "active",
    conditions: {workflow_path: {include: [".github/workflows/harbor-native-chainguard-receipt-provenance.yml"], exclude: []}},
    rules: [{type: "restrict_action_events", parameters: {allowed_events: ["push"]}}],
    _links: {self: {href: "https://api.github.com/orgs/Stuhlmuller/actions/policies/998"}}
  }]')"
  inherited_allowed="$(jq -cn '{
    id: 997,
    name: "Inherited compatible policy",
    target: "actions",
    source_type: "Organization",
    source: "Stuhlmuller",
    enforcement: "active",
    conditions: {workflow_path: {include: [".github/workflows/harbor-native-chainguard-receipt-provenance.yml"], exclude: []}},
    rules: [{type: "restrict_action_events", parameters: {allowed_events: ["pull_request_target", "push"]}}],
    _links: {self: {href: "https://api.github.com/orgs/Stuhlmuller/actions/policies/997"}}
  }')"
  actor_blocking="$(jq '
    .rules += [{
      type: "restrict_actions_actors",
      parameters: {allowed_actors: ["Stuhlmuller"]}
    }]
  ' <<<"$inherited_allowed")"

  setup_mock '[]' '[]' "[$valid]"
  mode=--apply
  reconcile >/dev/null
  assert_mock_counts 1 0
  teardown_mock

  setup_mock "[$valid]" "[$valid]" "[$valid]"
  mode=--check
  reconcile >/dev/null
  assert_mock_counts 0 0
  teardown_mock

  inherited_valid="$(jq -cn --argjson direct "$valid" --argjson inherited "$inherited_allowed" '[$direct, $inherited]')"
  setup_mock "$inherited_valid" "$inherited_valid" "$inherited_valid"
  mode=--check
  reconcile >/dev/null
  assert_mock_counts 0 0
  teardown_mock

  inherited_valid="$(jq -cn --argjson direct "$valid" --argjson inherited "$actor_blocking" '[$direct, $inherited]')"
  setup_mock "$inherited_valid" "$inherited_valid" "$inherited_valid"
  mode=--apply
  if reconcile >/dev/null 2>&1; then
    echo "actor restriction fixture unexpectedly reconciled" >&2
    exit 1
  fi
  assert_mock_counts 0 0
  teardown_mock

  setup_mock "[$inactive]" "[$inactive]" "[$valid]"
  mode=--apply
  reconcile >/dev/null
  assert_mock_counts 0 1
  teardown_mock

  for invalid in "$wrong_event" "$broad_path" "$wrong_path"; do
    setup_mock "[$invalid]" "[$invalid]" "[$invalid]"
    mode=--apply
    if reconcile >/dev/null 2>&1; then
      echo "unsafe event-policy fixture unexpectedly reconciled" >&2
      exit 1
    fi
    assert_mock_counts 0 0
    teardown_mock
  done

  setup_mock "$duplicate" "$duplicate" "$duplicate"
  mode=--apply
  if reconcile >/dev/null 2>&1; then
    echo "duplicate name fixture unexpectedly reconciled" >&2
    exit 1
  fi
  assert_mock_counts 0 0
  teardown_mock

  setup_mock "$parent_collision" "$parent_collision" "$parent_collision"
  mode=--apply
  if reconcile >/dev/null 2>&1; then
    echo "parent name collision fixture unexpectedly reconciled" >&2
    exit 1
  fi
  assert_mock_counts 0 0
  teardown_mock

  setup_mock "[$unexpected_source]" "[$unexpected_source]" "[$unexpected_source]"
  mode=--apply
  if reconcile >/dev/null 2>&1; then
    echo "unexpected source fixture unexpectedly reconciled" >&2
    exit 1
  fi
  assert_mock_counts 0 0
  teardown_mock

  for blocking_policy in \
    "$inherited_blocking" \
    "$(jq '.[0].conditions = {}' <<<"$inherited_blocking")" \
    "$(jq '.[0].conditions.workflow_path.include = ["~ALL"]' <<<"$inherited_blocking")" \
    "$(jq '
      .[0].conditions.workflow_path.include = ["*.yml"]
      | .[0].rules[0].parameters.allowed_events = ["pull_request_target", "push"]
    ' <<<"$inherited_blocking")"; do
    setup_mock "$blocking_policy" "$blocking_policy" "$blocking_policy"
    mode=--apply
    if reconcile >/dev/null 2>&1; then
      echo "inherited blocking policy fixture unexpectedly reconciled" >&2
      exit 1
    fi
    assert_mock_counts 0 0
    teardown_mock
  done

  setup_mock '[]' "$unrelated" '[]'
  mode=--apply
  if reconcile >/dev/null 2>&1; then
    echo "concurrent drift fixture unexpectedly reconciled" >&2
    exit 1
  fi
  assert_mock_counts 0 0
  teardown_mock

  echo "native receipt event policy reconciler self-test passed"
}

if [[ "$mode" == "--self-test" ]]; then
  self_test
  exit 0
fi

reconcile
