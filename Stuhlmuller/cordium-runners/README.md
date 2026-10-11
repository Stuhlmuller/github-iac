# Cordium runner App installation

This unit owns the complete repository selection for the private
`stuhlmuller-cordium-runners` GitHub App: only `Stuhlmuller/homelab`.
App ID `5270069` and installation ID `170148721` are public identifiers.
The GitHub provider cannot create an App or its initial organization
installation; those were bootstrapped from the homelab repository manifest.
No private key or installation token is an input to this unit.

Use the existing operator GitHub authentication, not App installation
authentication, which this resource does not support. The committed import
block adopts the existing installation; do not create a duplicate state owner:

```sh
cd Stuhlmuller/cordium-runners
terragrunt plan
```

The adoption plan must show one import and no repository access changes. After review and
merge, apply through the existing Terragrunt delivery path. The App key is
held by the homelab runner provisioner through its separate secret contract.
This unit does not deploy runners or grant access to other repositories.

Live adoption is pending. The 2026-10-10 operator plan initialized the declared
S3 backend and verified App ID `5270069`, but GitHub rejected
`GET /user/installations/170148721/repositories` with HTTP 403 because the
GitHub CLI uses an OAuth token. The provider requires a supported personal
access token or App user access token for this endpoint. The existing deploy
workflow uses App installation authentication and targets only the repositories
unit; it cannot deliver this unit unchanged. Add a reviewed credential and
delivery path before applying. Do not replace the existing deployment token
or widen its permissions to work around this boundary.

`prevent_destroy` blocks accidental retirement. For deliberate retirement,
stop the provisioner, verify runner and Workspace cleanup, then remove that
guard in a reviewed change before uninstalling the App. Restore a previous
reviewed repository selection through this unit to roll back access changes.
