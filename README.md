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

### Initializing `infra-tracker`

This repo is set up to provision new repositories via Terragrunt. To initialize the **infra-tracker** project repository, ensure it exists in `rstuhlmuller/github/terragrunt.hcl` under `inputs.github_repositories`, then run:

```bash
cd rstuhlmuller/github
terragrunt plan
terragrunt apply
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
