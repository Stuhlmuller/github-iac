# GitHub Infrastructure as Code 🚀

A Terraform and Terragrunt powered solution for managing GitHub repositories as code!

## What is this? 🤔

This project uses Infrastructure as Code (IaC) principles to automate the creation and management of GitHub repositories. Instead of clicking around in the GitHub UI, you define your repositories in code and let automation do the rest!

## Features ✨

- **Repository Management**: Create, configure, and manage GitHub repositories
- **Branch Protection**: Define branch protection rules and rulesets
- **Organization Settings**: Manage organization-wide defaults
- **Secure Credentials**: Uses AWS SSM Parameter Store for secure token management

## Getting Started 🚀

### Prerequisites

- [Terraform](https://www.terraform.io/) (v1.0+)
- [Terragrunt](https://terragrunt.gruntwork.io/) (latest)
- AWS CLI configured with appropriate permissions
- GitHub Personal Access Token (stored in AWS SSM Parameter Store)

### Setup

1. Clone the repository:
   ```bash
   git clone https://github.com/rstuhlmuller/github-iac.git
   cd github-iac
   ```

2. Store your GitHub Personal Access Token in AWS SSM Parameter Store:
   ```bash
   aws ssm put-parameter --name "/github-iac/personal_access_token" --value "your-github-token" --type SecureString
   ```

3. Navigate to your organization directory and run:
   ```bash
   cd rstuhlmuller/github
   terragrunt plan
   terragrunt apply
   ```

## Project Structure 📂

- `modules/`: Terraform modules for GitHub resources
- `rstuhlmuller/`: Organization-specific configurations
- `common/`: Shared providers and configurations

## Adding New Repositories 🏗️

To add a new repository, update the `github_repositories` input in your organization's `terragrunt.hcl` file:

```hcl
inputs = {
  github_repositories = {
    my-new-repo = {
      description = "My awesome new repository"
      visibility = "public"
    }
  }
}
```

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

## Development Environment 🧰

This project includes a devcontainer configuration with all necessary tools pre-installed:

- Terraform
- Terragrunt
- AWS CLI
- GitHub CLI
- VS Code extensions for HashiCorp configuration languages

## License 📜

MIT License - See [LICENSE](LICENSE) for details.

## Contributions 👥

Contributions are welcome! Please feel free to submit a Pull Request.

---

Happy automating! 🤖
