# APIOps CLI and PowerShell

Use the [new APIOps CLI](https://github.com/Azure/apiops-cli) through simple,
standalone PowerShell scripts. They do not require azd and can target an existing
APIM service in any resource group or subscription you can access.

## Migrating From the Legacy Toolkit

Previously, the API workflows downloaded platform-specific `extractor` and
`publisher` binaries from [Azure/apiops](https://github.com/Azure/apiops), using
toolkit release `v4.1.2`. They selected behavior through environment variables and
performed token replacement in the publishing configuration.

They now install the Node.js-based
[@azure-tools/apiops-cli](https://github.com/Azure/apiops-cli), pinned to `1.0.5`,
and call `apiops extract` or `apiops publish` through the repository's PowerShell
scripts. These version numbers belong to different projects; `1.0.5` is not a
downgrade of the legacy toolkit. The same scripts serve local runs, GitHub Actions,
and the azd publish hook, so target selection and failure handling are shared.
No repository-local npm project is needed.

### What Changes

| Legacy behavior | Current behavior |
| --- | --- |
| Download `extractor.*.exe` or `publisher.*.exe` | Install the pinned global npm package on Node.js 22+ |
| Run a downloaded binary | Run the PowerShell wrappers, which invoke `apiops extract` or `apiops publish` |
| `CONFIGURATION_YAML_PATH` selects configuration implicitly | Pass `-FilterPath` or `-OverridesPath`; GitHub's `USE_CONFIG_FILE` switch passes the corresponding file explicitly |
| Extraction config uses `apiNames` | CLI filters use `apis` and can include workspace selection |
| Override config uses `apimServiceName` | Select the target with `-ServiceName` or `API_MANAGEMENT_SERVICE_NAME` |
| `{#NAME#}` tokens are replaced before publishing | Use CLI-compatible property overrides or the sample's explicit Function binding; no legacy token substitution runs |
| Workflow input selects API specification format | Input removed because this CLI version has no corresponding extraction option |
| Ambient `COMMIT_ID` can influence publishing | Wrapper clears it temporarily and publishes the full source directory without destructive deletion |

For example, replace this legacy extraction configuration:

```yaml
apiNames:
  - echo-api
```

with a CLI filter:

```yaml
apis:
  - echo-api
```

This filters APIs only. Omitted resource-type keys still include all resources of
those types; it is not an API-only or workspace-only export. See
[Filters and Workspaces](#filters-and-workspaces) for explicit scope control.

### Migration Checklist

1. Install Node.js 22+, PowerShell 7, Azure CLI, and the pinned global package using
    the instructions below. Authenticate the identity that can access your APIM target.
2. Convert extraction filters from `apiNames` to `apis`. Remove `apimServiceName`
    from overrides and supply the target explicitly. Review each override against
    the [CLI override schema](https://github.com/Azure/apiops-cli/blob/v1.0.5/docs/guides/environment-overrides.md);
    changing these two field names alone does not migrate every legacy configuration.
3. Extract to a fresh directory first and compare the result with your existing
    artifacts. Do not assume the old toolkit's files are directly interchangeable.
    For example, the new CLI uses `namedValues/`; check legacy directories such as
    `named values/` rather than expecting the scripts to rename or remove them.
    Normal extraction merges files and does not delete obsolete artifact paths.
4. Review target URLs, named values and secret placeholders. Keep real secrets out
    of committed artifacts. For the bundled Function API, use the target Function
    parameters or GitHub variables documented below; the publisher stages its key
    temporarily rather than replacing tokens in tracked files.
5. Run the standalone publisher with `-DryRun` against the intended target and
    review its selected resources before publishing. A dry run still accesses Azure;
    it is not an offline compatibility check. A failed publish can leave partial changes.
6. Update reusable-workflow callers to stop passing `API_SPECIFICATION_FORMAT`.
    Follow [GitHub Actions](#github-actions) for secrets, environment variables,
    config selection and the new `DRY_RUN` input. Existing service-principal secrets
    are reused; the workflows do not automatically configure OIDC.

### What Stays the Same

The API GitHub workflows still support manual runs and reusable calls, select a
GitHub environment, and operate on `src/APIM`. Extraction still uploads artifacts
and opens a review PR; publishing uses the checked-out artifacts. The standalone
scripts do not require azd, create commits, or open PRs themselves.

The azd workflow still provisions infrastructure, deploys the Python Function,
then publishes APIM artifacts through its hook. Extraction is a separate, explicit
operation. The GitHub API workflows do not provision infrastructure or deploy
Function code. Developer-portal extraction/publishing uses its existing separate
workflows and has not been migrated to this CLI.

## Install

Prerequisites:

- [Node.js](https://nodejs.org/) 22 or later, including npm.
- [PowerShell](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) 7 or later.
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) for local authentication.

Run once on your machine, from any directory:

```powershell
node --version
pwsh --version
npm install --global @azure-tools/apiops-cli@1.0.5
apiops --version
apiops extract --help
apiops publish --help
```

The expected CLI version is `1.0.5`. This is a global installation: npm manages its
dependencies outside this repository. Do not run `npm install` in this repository;
no package manifest, local modules, or JavaScript helper is needed. Repeat the
pinned global installation command on a new developer machine or CI runner.

If `apiops` is not recognized, open a new PowerShell terminal. Use
`npm config get prefix` to locate npm's global installation directory and ensure
its executable directory is on `PATH` (the prefix itself on Windows, `bin` under
the prefix on Linux/macOS). On Windows, `apiops.cmd --version` can help distinguish
a PowerShell execution-policy issue from a missing installation. Follow your
organization's execution policy rather than disabling it globally.

## Authenticate

```powershell
az login
```

The CLI uses `DefaultAzureCredential`. Existing managed identity, workload identity,
or service-principal environment credentials may take precedence over your local
login. Verify which identity has access; choosing a subscription in the script
does not select a different identity. Extraction needs read access to the selected
APIM resources; publishing needs write access. No roles are assigned by the scripts.
See the CLI's [authentication guide](https://github.com/Azure/apiops-cli/blob/v1.0.5/docs/guides/authentication.md).

## Extract From an Existing Service

From the repository root in PowerShell 7, replace the example target values:

```powershell
$source = @{
    SubscriptionId = '<subscription-id>'
    ResourceGroupName = '<source-resource-group>'
    ServiceName = '<source-apim-name>'
}
./scripts/Extract-ApimArtifacts.ps1 @source
```

The default destination is this repository's [src/APIM](../src/APIM), even when
you invoke the script from another directory. To extract elsewhere:

```powershell
./scripts/Extract-ApimArtifacts.ps1 @source -ArtifactPath './exported artifacts'
```

Extraction stages its output in a temporary directory. CLI exit codes `1` (partial
failure) and `2` (fatal failure) cause a terminating error and leave the destination
unchanged. Successful results are merged into the destination, overwriting matching
files. Files absent from the extraction are not deleted. Use a fresh output directory
when you need a clean snapshot, and review the diff before publishing. The final file
copy is not transactional if a local disk error occurs. Temporary staging is cleaned
up on success or failure.

Without a filter, the CLI selects all supported service and workspace resources.
Review extracted artifacts for sensitive information before committing them. These
scripts never commit, push, create a pull request, or modify the source Azure service.

## Publish to a Target Service

Use the target's identifiers, not the source's:

```powershell
$target = @{
    SubscriptionId = '<subscription-id>'
    ResourceGroupName = '<target-resource-group>'
    ServiceName = '<target-apim-name>'
}
./scripts/Publish-ApimArtifacts.ps1 @target -ArtifactPath './exported artifacts' -DryRun
./scripts/Publish-ApimArtifacts.ps1 @target -ArtifactPath './exported artifacts'
```

These commands publish an arbitrary extraction, not the bundled sample. Publishing
the bundled Function API also requires its target Function binding parameters or
complete explicit overrides; see [the Function scenario](CreateAndDeployFunctionAndFunctionAPI.md#standalone-publishing).
No azd dependency is introduced. Binding is opt-in for standalone use; arbitrary
extraction or filtered publishing does not trigger a Function key lookup.

`-DryRun` delegates to the CLI; it is not an offline validator and may require Azure
access. Publishing uses the current files, including uncommitted changes. The script
temporarily clears `COMMIT_ID` to prevent accidental incremental publishing, then
restores it even on failure. Both nonzero CLI exit codes cause terminating errors;
a failed publish can leave partial changes in Azure and is not rolled back.
When Function binding is enabled, `-DryRun` also reads the target Function key;
neither a dry run nor key lookup is an offline operation.

Neither script enables destructive synchronization. Removing local files does not
delete corresponding Azure resources. They do not provision APIM services or
gateways, and do not deploy developer-portal content. The CLI can publish workspace
definitions present in the selected artifacts; that does not configure gateway connectivity.

## Filters and Workspaces

Both scripts accept `-FilterPath` and `-NoTransitive`. A filter key omitted from YAML
means **include all** resources of that type, not none. An empty list means exclude
that type. By default, referenced dependencies may also be included; use
`-NoTransitive` when selection must be exact, ensuring required dependencies already
exist in the target or are explicitly selected.

For a workspace-only operation, use this filter, changing `team-a` to the actual
workspace name. Save it as a local YAML filter file, for example
`workspace-filter.yaml`:

```yaml
apis: []
backends: []
products: []
namedValues: []
loggers: []
diagnostics: []
tags: []
policyFragments: []
gateways: []
versionSets: []
groups: []
subscriptions: []
schemas: []
policies: []
policyRestrictions: []
documentations: []
workspaces:
  - team-a: {}
```

The nested empty map includes all supported resources within `team-a`. To select
only certain workspace resources, specify nested allowlists and explicitly exclude
the other workspace types; see the upstream [filter reference](https://github.com/Azure/apiops-cli/blob/v1.0.5/docs/commands/extract.md#filter-configuration).

```powershell
./scripts/Extract-ApimArtifacts.ps1 @source `
    -FilterPath './workspace-filter.yaml' -NoTransitive
./scripts/Publish-ApimArtifacts.ps1 @target `
    -FilterPath './workspace-filter.yaml' -NoTransitive -DryRun
./scripts/Publish-ApimArtifacts.ps1 @target `
    -FilterPath './workspace-filter.yaml' -NoTransitive
```

Workspace artifacts live under `src/APIM/workspaces/<workspace-name>`. There is no
standalone CLI workspace flag. The scripts pass the filter through unchanged; they
do not infer scope or rename workspaces. Confirm the dry-run includes only intended
resources. Workspace serving requires a supported APIM tier and gateway association;
the Developer tier does not support workspaces. Live scope isolation and gateway
behavior have not been tested against an Azure deployment in this change.

For service-level resources only, use a filter containing `workspaces: []`.

## Overrides and Parameters

Pass a CLI-compatible YAML file explicitly to override target-specific values:

```powershell
./scripts/Publish-ApimArtifacts.ps1 @target `
    -OverridesPath './target-overrides.yaml' -DryRun
```

For example, the file can contain a literal target backend URL:

```yaml
apis:
  - name: echo-api
    properties:
      serviceUrl: https://target-backend.example/api
```

Workspace overrides must be nested under `workspaces`, not service-level `apis` or
`backends`. See [environment overrides](https://github.com/Azure/apiops-cli/blob/v1.0.5/docs/guides/environment-overrides.md).
Keep secrets out of committed overrides and command arguments. Neither the CLI nor
these wrappers performs legacy `{#NAME#}` token substitution.

Target parameters fall back to these environment variables when omitted:

| Parameter | Environment variable |
| --- | --- |
| `SubscriptionId` | `AZURE_SUBSCRIPTION_ID` |
| `ResourceGroupName` | `AZURE_RESOURCE_GROUP_NAME` |
| `ServiceName` | `API_MANAGEMENT_SERVICE_NAME` |

Explicit parameters take precedence. `-ArtifactPath` defaults to the repository's
artifact directory. Other relative paths are resolved from the caller's working
directory. Optional filters and overrides are never loaded implicitly from the repo.

The scripts load filters and overrides only when explicitly requested. Filters use
`apis`, not the legacy `apiNames`; service selection comes from `-ServiceName`, not
`apimServiceName` in an overrides file. azd invokes the same publisher through a
root `postdeploy` hook; see [DeployChangesDevToProd.md](DeployChangesDevToProd.md)
for setup and the dev/test workflow.

## GitHub Actions

The [extract workflow](../.github/workflows/APIM-Extract-APIs-and-Artifacts.yml)
and [publish workflow](../.github/workflows/APIM-Publish-APIs-and-Artifacts.yml)
install the pinned global CLI on Node.js 22 and invoke the same PowerShell scripts
as local runs. Both retain manual and reusable-workflow triggers and the selected
GitHub environment. No azd environment is needed on the runner.

Configure these secrets in each selected GitHub environment:

- `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`.

Set these GitHub environment variables:

- `AZURE_RESOURCE_GROUP_NAME`: target APIM resource group.
- `API_MANAGEMENT_SERVICE_NAME`: target APIM instance name.
- `FUNCTION_SERVICE_NAME` and `FUNCTION_BACKEND_URL`: set both when publishing the
    bundled Function API; use the corresponding azd outputs, with the URL ending in
    `/api`. The Function must already be deployed. The publishing identity needs
    permission to read its host keys in addition to writing APIM resources.
- `FUNCTION_RESOURCE_GROUP_NAME`: optional, if the Function is in a different group.
- `APIM_FILTER_PATH`: optional repository-relative CLI filter, including workspace
    selection. For extraction this overrides the sample filter selected by
    `USE_CONFIG_FILE`; publishing applies it alongside any selected overrides.
- `APIM_NO_TRANSITIVE`: optional, set to `true` for exact filter selection.

`azure/login` signs in using the existing service-principal secrets. This migration
does not create federated credentials or change the Azure identity. Publishing
requests only read access to repository contents; extraction additionally needs
contents and pull-request write permissions. Enable GitHub Actions to create pull
requests in the repository settings.

With `USE_CONFIG_FILE=true`, extraction loads
[src/apim-extract-configuration.yaml](../src/apim-extract-configuration.yaml), now a
CLI filter using `apis`. Replace its sample API names before use. Publishing loads
[src/apim-publish-configuration.yaml](../src/apim-publish-configuration.yaml), whose
default empty map applies no overrides. Replace `{}` with CLI-compatible overrides
as needed. Legacy `{#NAME#}` token replacement no longer runs, and the APIM target
always comes from the environment variables above.

The new CLI has no API specification-format switch. The old
`API_SPECIFICATION_FORMAT` workflow input was removed; reusable-workflow callers
must stop passing it. Extraction uses the CLI's native export behavior.

Extraction still merges into `src/APIM`, uploads `artifacts-from-portal`, and creates
an artifacts-only PR on `apim-extract-<environment>`. It does not delete stale files;
review the PR and secret redaction before merging. Publishing sends the complete
checked-out artifacts without destructive deletion or commit-only selection.
Select `DRY_RUN=true` to preview a publish; this still accesses Azure and, when
Function binding is configured, reads its target host key.

The developer-portal and infrastructure workflows are unchanged by this migration.
These API workflows publish configuration only; they do not provision resources or
deploy Function code.

## Offline Checks

```powershell
pwsh -NoProfile -File ./scripts/Test-ApimScripts.ps1
pwsh -NoProfile -File ./scripts/Test-ApimScripts.ps1 -AzdHooks
pwsh -NoProfile -File ./scripts/Test-ApimScripts.ps1 -GitHubWorkflows -AzdHooks
```

The checks replace the CLI with a test stub. They cover argument forwarding, paths
with spaces, staging and cleanup, partial/fatal failures, environment precedence,
`COMMIT_ID` restoration, Function target selection and temporary secret cleanup.
The optional `-AzdHooks` check also runs the actual azd hook runner in an isolated
temporary project with stub APIOps and Azure CLIs. They neither
contact APIM nor prove live artifact compatibility, workspace isolation, or gateway
connectivity.

`-GitHubWorkflows` uses the globally installed CLI's YAML parser, validates the
workflow/configuration contracts, and executes the workflows' actual PowerShell
steps with stub CLIs. It covers config selection, true/false switches, workspace
filter forwarding, Function binding, secret cleanup and failure propagation. It
does not run GitHub-hosted actions or verify Azure authentication or live publishing.