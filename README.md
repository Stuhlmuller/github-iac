# GitHub Infrastructure as Code

OpenTofu modules and Terragrunt configuration for the `Stuhlmuller` GitHub organization.

## Layout

- `Stuhlmuller/`: organization configuration and the deployable Terragrunt unit.
- `modules/github_repositories/`: repositories, rulesets, default branches, and protected Actions environments.
- `root.hcl`: encrypted S3 state backend configuration.

## Development

Tool versions are pinned in `mise.toml`.

```bash
terragrunt hcl fmt --check --diff
tofu fmt -check -recursive
```

Pull requests run unprivileged validation only. Pull-request code receives no AWS
credentials, GitHub App private key, or organization-write token.

## Public control-plane security

The GitHub provider does not expose organization code-security configurations.
The repository therefore owns one narrow API reconciler for `homelab` and
`github-iac`:

```bash
bash Stuhlmuller/security-configurations/reconcile-public-control-plane.sh --check
bash Stuhlmuller/security-configurations/reconcile-public-control-plane.sh --apply
```

The configuration enables secret scanning, push protection, non-provider
patterns, validity checks, private vulnerability reporting, the dependency
graph, and Dependabot alerts. Custom CodeQL remains workflow-owned. Actions are
restricted to the repository's exact action allowlist, full commit SHA pins,
read-only default tokens, approval for every external contributor, and one-day
log retention. Renovate owns update pull requests, so automatic Dependabot
updates remain disabled.

The script requires an authenticated organization owner or security manager
with organization Administration write, repository Administration write,
Dependabot alerts read, and Contents read permissions. It refuses duplicate or
out-of-scope attachments, verifies effective repository APIs rather than only
configuration metadata, and exits unsuccessfully when either repository has an
open Dependabot alert.

Rollback reattaches both repositories to the existing `Public Protection`
configuration after verifying effective secret scanning and push protection.
It preserves the stricter Actions settings:

```bash
bash Stuhlmuller/security-configurations/reconcile-public-control-plane.sh --rollback
```

## Protected deployment

The `Terragrunt Deploy` workflow accepts only the exact 40-character commit SHA currently at `main`.

After the migration script is reviewed and merged, move all 11 public rulesets
to their isolated state addresses once. The script is exact and idempotent;
`--check` must pass before the targeted workflow can plan:

`Stuhlmuller/repositories/public-rulesets.json` is the shared repository and
ruleset-ID inventory used by configuration, migration, and reconciliation.
Wait for every GitHub-IaC plan or deployment to finish, then keep them paused
until migration and `--check` both complete.

```bash
export AWS_PROFILE="<administrator-profile>"
bash Stuhlmuller/repositories/migrate-public-ruleset-state.sh --apply
bash Stuhlmuller/repositories/migrate-public-ruleset-state.sh --check
```

After the migration, run the repository-owned all-public-ruleset reconciler
once with administrator AWS credentials and an administrator GitHub token:

```bash
GITHUB_TOKEN="$(gh auth token)" \
  bash Stuhlmuller/repositories/reconcile-public-rulesets.sh --apply
GITHUB_TOKEN="$(gh auth token)" \
  bash Stuhlmuller/repositories/reconcile-public-rulesets.sh --check
```

The script plans only the 11 declared public-repository rulesets. It rejects
imports, state moves, destructive actions, unrelated drift, or any change
outside removal of the existing integration bypass plus the exact `homelab`
and `github-iac` hardening policies. It applies the verified saved plan and
checks every live ruleset ID afterward. Future `homelab` ruleset changes use
the protected workflow below.

Live verification also requires [GitHub's default additional approval for
unattributed Copilot pull requests](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets#additional-approval-for-unattributed-copilot-pull-requests).
Provider `6.12.1` does not model this public-preview field, so the
repository-owned API check verifies exact default drift directly. GitHub notes
that it has no effect while native required approvals remain zero; `policy-bot`
is the effective approval gate for these repositories.

The workflow never moves state. Dispatch it only after the separate migration:

1. Dispatch `.github/workflows/deploy.yml` on `main` with `expected_sha` set to the reviewed commit.
2. Approve `github-iac-plan`.
3. Review the authenticated, scope-checked plan.
4. Approve `github-iac-production` to apply that exact saved plan.

```bash
gh workflow run deploy.yml --repo Stuhlmuller/github-iac --ref main \
  -f expected_sha=<40-character-main-sha>
```

The workflow targets only the isolated homelab ruleset. It hashes canonical
before and after policy state, binds the before hash to GitHub immediately
before apply, and requires the after hash to contain exactly seven checks,
strict mode, pull-request/signature/history protections, exact branch
conditions, and no bypass actors. The
encrypted, versioned saved plan is deleted only after apply and exact live
verification. Rejected, cancelled, or failed runs retain their exact plan
version for investigation and explicit cleanup.

Required GitHub configuration:

- `APP_CLIENT_ID` repository variable for a dedicated deployment App.
- `APP_PRIVATE_KEY` environment secret in both `github-iac-plan` and `github-iac-production`; do not store it as a repository secret.
- The App is installed only on `homelab`, grants repository Administration
  write, and grants no organization or other repository permission. The
  workflow also scopes every generated token to `homelab`.
- Reviewer `rstuhlmuller` on both environments. Administrator bypass is disabled and deployments are restricted to protected branches.

Before dispatching the protected workflow, restrict the App installation and
permissions, then rotate its private key into both protected environments:

```bash
set -euo pipefail
private_key_path=/secure/path/github-app-private-key.pem
test -s "$private_key_path"
openssl pkey -check -noout -in "$private_key_path"

for environment in github-iac-plan github-iac-production; do
  gh secret set APP_PRIVATE_KEY --repo Stuhlmuller/github-iac \
    --env "$environment" < "$private_key_path"
  test "$(gh secret list --repo Stuhlmuller/github-iac --env "$environment" \
    --json name --jq 'any(.[]; .name == "APP_PRIVATE_KEY")')" = true
done

repository_has_key="$(gh secret list --repo Stuhlmuller/github-iac \
  --json name --jq 'any(.[]; .name == "APP_PRIVATE_KEY")')"
if [ "$repository_has_key" = true ]; then
  gh secret delete APP_PRIVATE_KEY --repo Stuhlmuller/github-iac
fi
test "$(gh secret list --repo Stuhlmuller/github-iac \
  --json name --jq 'any(.[]; .name == "APP_PRIVATE_KEY")')" = false
```

After this change reaches `main`, adopt the bootstrapped environments into the
declared remote state with administrator AWS and GitHub credentials. Import
only an address that is absent, then review and apply the exact environment-only
plan:

```bash
set -euo pipefail
export AWS_PROFILE="<administrator-profile>"
export GITHUB_TOKEN="$(gh auth token)"
cd Stuhlmuller/repositories
terragrunt --log-disable init -reconfigure

environment_targets=(
  github-iac:github-iac-plan
  github-iac:github-iac-production
  homelab:homelab-plan
  homelab:homelab-production
)
plan_targets=()
for target in "${environment_targets[@]}"; do
  repository="${target%%:*}"
  environment="${target#*:}"
  address="github_repository_environment.this[\"$repository.$environment\"]"
  if ! terragrunt --log-disable state show "$address" >/dev/null 2>&1; then
    terragrunt --log-disable import "$address" "$target"
  fi
  plan_targets+=("-target=$address")
done

environment_plan_dir="$(mktemp -d "${TMPDIR:-/tmp}/github-iac-environments.XXXXXX")"
environment_plan="$environment_plan_dir/plan.out"
environment_plan_json="$environment_plan_dir/plan.json"
trap 'test ! -d "$environment_plan_dir" || rm -rf -- "$environment_plan_dir"' EXIT
terragrunt --log-disable plan -input=false "${plan_targets[@]}" \
  -out="$environment_plan"
terragrunt --log-disable show -json "$environment_plan" > "$environment_plan_json"
jq -e '
  [.resource_changes[] | select(.mode == "managed")] as $changes
  | ($changes | map(.address) | sort) == ([
      "github_repository_environment.this[\"github-iac.github-iac-plan\"]",
      "github_repository_environment.this[\"github-iac.github-iac-production\"]",
      "github_repository_environment.this[\"homelab.homelab-plan\"]",
      "github_repository_environment.this[\"homelab.homelab-production\"]"
    ] | sort)
  and all($changes[];
    (.change.actions == ["no-op"] or .change.actions == ["update"])
    and .change.before.environment == .change.after.environment
    and ({
      "github-iac-plan": "github-iac",
      "github-iac-production": "github-iac",
      "homelab-plan": "homelab",
      "homelab-production": "homelab"
    }[.change.after.environment] == .change.after.repository)
    and .change.before.repository == .change.after.repository
    and .change.after.can_admins_bypass == false
    and .change.after.prevent_self_review == false
    and (.change.after.reviewers | length) == 1
    and (.change.after.reviewers[0].users | sort) == [57728706]
    and .change.after.reviewers[0].teams == []
    and (if .change.after.environment == "homelab-plan" then
      .change.after.deployment_branch_policy == []
    else
      .change.after.deployment_branch_policy == [{
        "custom_branch_policies": false,
        "protected_branches": true
      }]
    end)
    and ((.change.importing // null) == null)
    and ((.previous_address // null) == null))
' "$environment_plan_json"
terragrunt --log-disable show -no-color "$environment_plan"
printf 'Apply this exact environment-only plan? Type apply: '
read -r environment_confirmation
test "$environment_confirmation" = apply
terragrunt --log-disable apply "$environment_plan"

for target in "${environment_targets[@]}"; do
  repository="${target%%:*}"
  environment="${target#*:}"
  gh api "repos/Stuhlmuller/$repository/environments/$environment" |
    jq -e --arg environment "$environment" '
      .name == $environment
      and .can_admins_bypass == false
      and (if $environment == "homelab-plan" then
        .deployment_branch_policy == null
        and ([.protection_rules[].type] | sort) == ["required_reviewers"]
      else
        .deployment_branch_policy == {
          "protected_branches": true,
          "custom_branch_policies": false
        }
        and ([.protection_rules[].type] | sort) == [
          "branch_policy",
          "required_reviewers"
        ]
      end)
      and ([.protection_rules[] | select(.type == "required_reviewers") | {
        prevent_self_review,
        reviewer_ids: [.reviewers[].reviewer.id]
      }] == [{
        "prevent_self_review": false,
        "reviewer_ids": [57728706]
      }])
    '
done
```

The commands verify all four state addresses, the exact reviewer, disabled
administrator bypass, protected `main` deployments, and unrestricted trusted
pull-request refs for `homelab-plan`. The ruleset-only deployment workflow does
not reconcile environments. `homelab-plan` intentionally omits a branch policy
because required same-repository pull-request plans run from feature refs; the
workflow trust check and required environment reviewer remain the gate.

`prevent_self_review` remains false because user `57728706` is the only owner
and deployment reviewer. Enable it after adding a second qualified reviewer;
administrator bypass remains disabled meanwhile.

Do not dispatch while either environment is absent or while the repository secret remains; GitHub would otherwise auto-create an unprotected environment or expose the fallback repository secret.

Do not run an untargeted organization-wide apply to deliver a homelab ruleset change.

## Rollback

Create a forward commit correcting only the incompatible rule while retaining strict mode, all other protections, the isolated `github_repository_ruleset.existing` state addresses, and the protected workflow. Full code reverts are unsupported because they would require a separate reviewed reverse state migration for all 11 address and ruleset-ID pairs. Never repair live GitHub state manually.
