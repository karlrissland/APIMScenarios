# APIM Scenarios

## What
Showcase common scenarios in a way that makes it simple to get up and running with the tool.  Specifically, the following scenarios provided;

- DevOps capabilities for APIs and artifacts with APIOps CLI filters and overrides
- DevOps Capabilities for Developer Portal Customizations
- Use of GitHub Code Spaces for development
- Use of a Development APIM instance for development
- Deploying APIs along with the supporting backend services

## Why
While working with customers, these are commong scenarios they typically need to implement.  While the documentation has all the information needed to build each of these scenarios, you have to assemble information from multiple sources and there may or may not be working solutions to study.

The goal is to provide a simple working implementation of each scenario and documentation to get a team up and running quickly.

## How (Setup)

Install the new APIOps CLI globally (Node.js 22+ required):

```powershell
npm install --global @azure-tools/apiops-cli@1.0.5
apiops --version
```

Use PowerShell 7 to run [scripts/Extract-ApimArtifacts.ps1](scripts/Extract-ApimArtifacts.ps1)
and [scripts/Publish-ApimArtifacts.ps1](scripts/Publish-ApimArtifacts.ps1).
See [docs/APIOpsCLI.md](docs/APIOpsCLI.md) for authentication, standalone extraction,
publishing, workspace filters, and installation troubleshooting. No repository-local
npm project or JavaScript helper is required.

### Switch From the Legacy Toolkit

API extraction and publishing now use
[@azure-tools/apiops-cli](https://github.com/Azure/apiops-cli), pinned to `1.0.5`,
instead of downloading the legacy `Azure/apiops` extractor and publisher binaries.
Local runs, azd publishing, and the GitHub API workflows share the same PowerShell
scripts. The npm package version is independent of the old toolkit release numbers.

This is not a drop-in replacement for the old configuration files: API filters now
use `apis` instead of `apiNames`, target service selection is explicit, and legacy
`{#NAME#}` token replacement no longer runs. Developer-portal workflows are unchanged.
See [the migration guide](docs/APIOpsCLI.md#migrating-from-the-legacy-toolkit) for
the old-to-new mapping, artifact review steps, and GitHub setup changes.

### Azure Developer CLI

The repository is enabled for azd through [azure.yaml](azure.yaml), using the
existing [Infrastructure/main.bicep](Infrastructure/main.bicep). `azd up` provisions
the selected environment, deploys the Python Function, then runs the PowerShell
APIM publish hook with the target Function's backend and key. Extraction
is always manual. Follow [docs/DeployChangesDevToProd.md](docs/DeployChangesDevToProd.md)
for the dev-to-test demo, required environment settings, costs, and current limits.

## Scenarios

### Deploy changes in Dev to prod
In this scenario you will make changes to the development APIM instance via the Azure portal.  After updating via the portal, you will export those changes, merge them with main via a pull request, then publish them to your production environment.

### Creating new API in VSCode, deploying to Prod
While the Azure Portal is easy to use, it may be easier to work with your APIs and APIM configuration via code.  We will leverage CodeSpaces and Visual Studio Code Extensions in this scenario.

### Deploy DevPortal Customizations to prod
In this scenario you will make changes to the development APIM instances developer portal.  After publishing your customizations, you will export those changes, merge them with main via a pull request, then publish them to your production environments developer portal.

### Develop and Deploy Function and Function API
Here we will show how to build a function app along with it's Azure APIM definition and deploy them together.  This will touch on what is needed to parameterize an API deployment across environments.

Follow [docs/CreateAndDeployFunctionAndFunctionAPI.md](docs/CreateAndDeployFunctionAndFunctionAPI.md)
for the included HTTP Function, environment-specific APIM binding, standalone
publishing parameters, secret handling and local checks.

## Architecture Overviews

- GitHub Workflows
- GitHub Repo Structure
- APIM Export Structure