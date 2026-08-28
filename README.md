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

Pull requests run static checks only. Pull-request code receives no AWS
credentials, GitHub App private key, or organization-write token.

## Repository security configurations

The GitHub provider does not expose organization code-security configurations.
The repository therefore owns one narrow API reconciler for the enforced
`Stuhlmuller/homelab` exception:

```bash
bash Stuhlmuller/security-configurations/reconcile-homelab.sh --check
bash Stuhlmuller/security-configurations/reconcile-homelab.sh --apply
```

The configuration keeps secret scanning and push protection enabled, enables
the dependency graph and Dependabot alerts, and leaves automatic Dependabot
updates disabled because Renovate owns update pull requests. The script requires
an authenticated organization owner or security manager with organization
Administration write plus repository Administration read, Dependabot alerts
read, and Contents read permissions. A classic token needs `write:org` and
`repo`. The script refuses duplicate configurations or attachments outside
`homelab`, verifies both alert and SBOM APIs, prints every open alert, and exits
unsuccessfully until all alerts are resolved or dismissed with justification.

Rollback reattaches only `homelab` to the existing `Public Protection`
configuration after verifying that it enforces secret scanning and push
protection:

```bash
bash Stuhlmuller/security-configurations/reconcile-homelab.sh --rollback
```

## Protected deployment

The `Terragrunt Deploy` workflow accepts only the exact 40-character commit SHA currently at `main`.

1. Dispatch `.github/workflows/deploy.yml` on `main` with `expected_sha` set to the reviewed commit.
2. Approve `github-iac-plan`.
3. Review the authenticated, scope-checked plan.
4. Approve `github-iac-production` to apply that exact saved plan.

```bash
gh workflow run deploy.yml --repo Stuhlmuller/github-iac --ref main \
  -f expected_sha=<40-character-main-sha>
```

The workflow targets only the isolated homelab ruleset. It stores the binary plan encrypted in the private state bucket, verifies its SHA-256 digest before apply, rejects a stale `main`, verifies live state after apply, and deletes the saved plan immediately after its verified download. A rejected or cancelled run intentionally retains its plan for investigation; delete that run's exact S3 object after review.

Required GitHub configuration:

- `APP_CLIENT_ID` repository variable for the `stuhlmuller-github-iac` App.
- `APP_PRIVATE_KEY` environment secret in both `github-iac-plan` and `github-iac-production`; do not store it as a repository secret.
- GitHub App repository permission: Administration write, scoped by the workflow to `homelab`.
- Reviewer `rstuhlmuller` on both environments. Administrator bypass is disabled and deployments are restricted to protected branches.

Bootstrap both protected environments and rotate the App private key into environment-level secrets before merging this workflow:

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

if ! terragrunt --log-disable state show \
  'github_repository_environment.this["github-iac.github-iac-plan"]' >/dev/null 2>&1; then
  terragrunt --log-disable import \
    'github_repository_environment.this["github-iac.github-iac-plan"]' \
    github-iac:github-iac-plan
fi
if ! terragrunt --log-disable state show \
  'github_repository_environment.this["github-iac.github-iac-production"]' >/dev/null 2>&1; then
  terragrunt --log-disable import \
    'github_repository_environment.this["github-iac.github-iac-production"]' \
    github-iac:github-iac-production
fi

environment_plan_dir="$(mktemp -d "${TMPDIR:-/tmp}/github-iac-environments.XXXXXX")"
environment_plan="$environment_plan_dir/plan.out"
environment_plan_json="$environment_plan_dir/plan.json"
trap 'test ! -d "$environment_plan_dir" || rm -rf -- "$environment_plan_dir"' EXIT
terragrunt --log-disable plan -input=false \
  -target='github_repository_environment.this["github-iac.github-iac-plan"]' \
  -target='github_repository_environment.this["github-iac.github-iac-production"]' \
  -out="$environment_plan"
terragrunt --log-disable show -json "$environment_plan" > "$environment_plan_json"
jq -e '
  [.resource_changes[] | select(.mode == "managed")] as $changes
  | ($changes | map(.address) | sort) == ([
      "github_repository_environment.this[\"github-iac.github-iac-plan\"]",
      "github_repository_environment.this[\"github-iac.github-iac-production\"]"
    ] | sort)
  and all($changes[];
    (.change.actions == ["no-op"] or .change.actions == ["update"])
    and .change.before.repository == "github-iac"
    and .change.after.repository == "github-iac"
    and .change.before.environment == .change.after.environment
    and (.change.after.environment == "github-iac-plan" or
         .change.after.environment == "github-iac-production")
    and .change.after.can_admins_bypass == false
    and .change.after.prevent_self_review == false
    and (.change.after.reviewers | length) == 1
    and (.change.after.reviewers[0].users | sort) == [57728706]
    and .change.after.reviewers[0].teams == []
    and .change.after.deployment_branch_policy == [{
      "custom_branch_policies": false,
      "protected_branches": true
    }]
    and ((.change.importing // null) == null)
    and ((.previous_address // null) == null))
' "$environment_plan_json"
terragrunt --log-disable show -no-color "$environment_plan"
printf 'Apply this exact environment-only plan? Type apply: '
read -r environment_confirmation
test "$environment_confirmation" = apply
terragrunt --log-disable apply "$environment_plan"

for environment in github-iac-plan github-iac-production; do
  gh api "repos/Stuhlmuller/github-iac/environments/$environment" |
    jq -e --arg environment "$environment" '
      .name == $environment
      and .can_admins_bypass == false
      and .deployment_branch_policy == {
        "protected_branches": true,
        "custom_branch_policies": false
      }
      and ([.protection_rules[].type] | sort) == [
        "branch_policy",
        "required_reviewers"
      ]
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

The commands verify both state addresses, the exact reviewer, protected-branch
restriction, and disabled administrator bypass. The ruleset-only deployment
workflow does not reconcile these two environments.

Do not dispatch while either environment is absent or while the repository secret remains; GitHub would otherwise auto-create an unprotected environment or expose the fallback repository secret.

Do not run an untargeted organization-wide apply to deliver a homelab ruleset change.

## Rollback

Create a forward commit correcting only the incompatible rule while retaining strict mode, all other protections, the isolated `github_repository_ruleset.existing` state address, and the protected workflow. A full code revert requires a separately reviewed reverse state move after both addresses and ruleset ID `14700233` are verified. Never repair live GitHub state manually.
