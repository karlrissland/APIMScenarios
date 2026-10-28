# Promote APIM Changes With azd

This walkthrough uses separate `dev` and `test` APIM services. The same setup also
accepts `uat` and `prod`. Choose Basic v2 or Premium v2 during initial provisioning;
there is no default tier.
Only those four environment names are accepted by the current Bicep template.

## Prerequisites and Costs

Install [azd](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
1.36.0 or later and follow [APIOpsCLI.md](APIOpsCLI.md) to install the global APIOps
CLI, PowerShell 7, and Azure CLI. Authenticate both tools:

```powershell
azd auth login
az login
```

Use the same intended tenant/account for both logins. azd provisions infrastructure;
the APIOps CLI authenticates separately using its credential chain. Permissions to
create resources do not automatically imply permission to publish APIM configuration.

Review cost and region availability before running `azd up`. Each environment
provisions the selected APIM v2 service, a Linux Flex Consumption
(FC1) plan, a Function App, an LRS storage account and a private deployment container.
The Function uses 2048 MB instances, a maximum of 40 instances and no always-ready
instances. These resources incur charges. azd also deploys the included Python
Function and its APIM API.
Only `BasicV2` and `PremiumV2` are accepted; both are paid services. Basic v2 suits
the demo; Premium v2 adds enterprise capabilities including full network isolation.
Microsoft's
[region availability table](https://learn.microsoft.com/azure/api-management/api-management-region-availability)
lists Basic v2 in Sweden Central, but Premium v2 new-instance creation there is
temporarily unavailable due to capacity, as checked on 2026-10-28. Review current
availability and prices before choosing a tier and region.

The names retain the repository's existing subscription-plus-environment naming
scheme. Running `dev` against a subscription that already contains this demo will
update that deployment, not create an isolated second copy. Do not select an
existing production deployment for a trial run. Microsoft documents v2 provisioning
in minutes, but actual timing varies. Changing the ARM API version alone does not
select the v2 platform: the SKU must be a v2 SKU. The templates use the
`2025-09-01-preview` management API, whose documented SKU enum includes Premium v2,
and explicitly enable the developer portal. The management API is preview even
though the Premium v2 service tier is generally available.

Classic APIM instances cannot be upgraded to v2 in place. These choices require a
fresh APIM instance, either after a separately reviewed teardown or in a new
environment. Extract any portal changes before deleting the old service. Deleting
only local azd environment state does not delete Azure resources. A fresh interactive
azd environment prompts for the required `apimSku` Bicep parameter, presenting
`BasicV2` and `PremiumV2` from its `@allowed` list. The parameter has no default and
is omitted from the azd parameter mapping, just like the publisher parameters.
Previously saved parameter values can suppress the prompt on subsequent runs.
The earlier azd `APIM_SKU` environment-variable mapping has been removed.

The Function uses its system-assigned managed identity for both host storage and
Flex deployment storage. Bicep assigns Storage Blob Data Owner at storage-account
scope, configures `AzureWebJobsStorage__accountName` and
`AzureWebJobsStorage__credential=managedidentity`, and disables storage shared keys.
No storage key is read or stored in app settings. The deployment identity must have
`Microsoft.Authorization/roleAssignments/write` at the storage scope, for example
through Role Based Access Control Administrator alongside resource deployment
permissions; Contributor alone cannot create role assignments.

For an existing key-based Function, reprovision with the updated template before
retrying code deployment; rerunning `azd up` includes that provisioning step. No
teardown is needed for this authentication change. RBAC can take up to 10 minutes
to propagate; if a deployment initially returns a storage authorization error,
allow propagation and retry. APIM still uses the Function host key for HTTP calls;
this is independent of the Function's keyless backing-storage access.

For this public-endpoint demo, Bicep explicitly enables the storage public network
endpoint while disabling anonymous blob access and shared-key authentication.
Containers remain private and the Function authenticates with managed identity.
Managed identity does not bypass a storage firewall: a previously disabled public
endpoint still blocks deployment until infrastructure is reprovisioned.

Bicep manages the approved `apim-demo-storage-public-network` policy exemption on
the Function storage account only. It exempts only `StorageAccountPublicNetworkModify`
in the `mcapsgovdeploypolicies` assignment under management group
`499b952e-2194-4661-af36-2f39f4261f76`; other policy members remain enforced.
The exemption is a `Waiver` without an expiry and uses the same name as the existing
live exemption. This assignment ID is organization-specific: update it in
`Infrastructure/functions.bicep` before using a different policy assignment.
The deployment identity needs `Microsoft.Authorization/policyExemptions/write` at
the storage scope and `Microsoft.Authorization/policyAssignments/exempt/action`
on the policy assignment, in addition to the permissions above.

For fresh deployments, the initial storage account creation can be modified by
policy to disable public access. Bicep then creates the scoped exemption and runs
an ordered storage update to enable the endpoint before creating the private
deployment container and Function. Both storage declarations keep shared keys and
anonymous access disabled. No manual exception creation is needed for subsequent
full deployments. Other policy assignments can still deny or modify public access
and require separate approval; this exemption does not bypass them.

No VNet or private endpoints are added. Additional bindings can
require extra storage roles; Table Data Contributor is also needed to persist
host diagnostic events in Table Storage.

Existing S1 deployments need new Flex app and plan resources, not an in-place
plan change. Follow [the Flex migration steps](CreateAndDeployFunctionAndFunctionAPI.md#moving-an-existing-s1-deployment-to-flex)
to provision before deploying. Old S1 resources remain untouched and billable
until separately removed with approval.

## 1. Provision Dev and Publish Initial Artifacts

From the repository root in PowerShell 7, replace the placeholders:

```powershell
azd env new dev
azd env set AZURE_SUBSCRIPTION_ID '<subscription-id>' --environment dev
azd env set AZURE_LOCATION '<azure-region>' --environment dev
azd up --environment dev
```

azd presents the `apimSku` choices and prompts for `publisherName` (organization or
display name) and `publisherEmail` (contact email) when no values have been saved
for the selected environment. Enter your own values; no sample identity is used.
You do not need to set `APIM_PUBLISHER_NAME` or `APIM_PUBLISHER_EMAIL` for azd.

The [azd configuration](../azure.yaml) runs `package --all`, `provision`, then `deploy --all`.
The root `postdeploy` hook calls [Invoke-AzdPublish.ps1](../scripts/Invoke-AzdPublish.ps1),
which calls the standalone [publisher](../scripts/Publish-ApimArtifacts.ps1) after
the Function code is deployed. See [the Function scenario](CreateAndDeployFunctionAndFunctionAPI.md)
for target binding, authentication, required key-read permissions and verification.

The `preprovision` hook checks for the APIOps and Azure CLIs, leaving publisher
input collection to azd's native Bicep parameter prompts. Bicep emits
`AZURE_SUBSCRIPTION_ID`, `AZURE_RESOURCE_GROUP_NAME`, and
`API_MANAGEMENT_SERVICE_NAME`; azd makes those values available to the publish hook.
`FUNCTION_SERVICE_NAME` and `FUNCTION_BACKEND_URL` identify the target Function.
Its host key is looked up at publish time, never exposed as a deployment output.

Do not rerun `azd up` against dev after making portal edits until you have extracted
them: publishing repository artifacts can overwrite matching portal configuration.

## 2. Make a Portal Change

Open the dev APIM service in the Azure portal. Change a policy, operation, or API
property on the Echo API. Record a recognizable change you can later verify in test.
Do not add secrets to the API definition or policy just to demonstrate promotion.

## 3. Extract Dev Changes Locally

Read the selected dev environment's outputs and pass them explicitly to the
standalone extractor:

```powershell
$source = @{
	SubscriptionId = (azd env get-value AZURE_SUBSCRIPTION_ID --environment dev)
	ResourceGroupName = (azd env get-value AZURE_RESOURCE_GROUP_NAME --environment dev)
	ServiceName = (azd env get-value API_MANAGEMENT_SERVICE_NAME --environment dev)
}
./scripts/Extract-ApimArtifacts.ps1 @source
git diff -- src/APIM
```

The extractor itself does not depend on azd. For an arbitrary existing APIM service,
populate the same three parameters with its identifiers instead. Review extracted
files, environment-specific URLs, policies, and secrets before publishing. Extraction
does not delete stale files; consult [APIOpsCLI.md](APIOpsCLI.md) for merge semantics.
Committing is optional for this local demo and is never performed by these scripts.

## 4. Provision Test and Publish the Extracted Files

```powershell
azd env new test
azd env set AZURE_SUBSCRIPTION_ID '<subscription-id>' --environment test
azd env set AZURE_LOCATION '<azure-region>' --environment test
azd up --environment test
```

Choose the APIM SKU and enter the publisher details for this environment as well.

The test publish hook uses test outputs, not the dev service's identifiers. Verify
your portal change is present in test. The reserved sample `demo-function` backend
and its secret named value are rebound to the test Function in a temporary copy.
Other environment-specific backend URLs are not automatically rewritten; supply
explicit target overrides when needed. Calling `/function-demo/hello` through the
test gateway should return `"environment": "test"`.

## 5. Edit Artifacts and Publish Again

Edit an API definition or policy under [src/APIM](../src/APIM). Then run:

```powershell
azd up --environment test
```

Verify the new change in the test portal or by calling the test gateway. The
publisher uses current local files, including uncommitted edits. For an
update after infrastructure already exists, you can instead run
`azd deploy --all --environment test`, which runs the same `postdeploy` hook.
This also redeploys the Function. For APIM-only publishing, use the standalone
publisher, including the target Function parameters when publishing the sample.
`azd provision` only provisions infrastructure and does not publish code or artifacts.

## Per-Environment Publish Settings

| azd setting | Meaning | Default |
| --- | --- | --- |
| `APIM_ARTIFACT_PATH` | Artifact directory | Repository `src/APIM` |
| `APIM_FILTER_PATH` | CLI filter YAML file, including workspace filters | No filter |
| `APIM_OVERRIDES_PATH` | CLI-compatible target overrides YAML file | No overrides |
| `APIM_NO_TRANSITIVE` | Disable automatic dependency inclusion | `false` |
| `APIM_PUBLISH_DRY_RUN` | Preview APIM publishing without applying it | `false` |

All relative paths in the azd adapter are repository-relative. Boolean settings
must be the literal `true` or `false`. For example:

```powershell
azd env set APIM_OVERRIDES_PATH './test-overrides.yaml' --environment test
azd env set APIM_PUBLISH_DRY_RUN true --environment test
azd deploy --all --environment test
azd env set APIM_PUBLISH_DRY_RUN false --environment test
```

A publish dry run does not make `azd up` a provisioning dry run: infrastructure
can still be created or updated, and Function code is still deployed. To preview
only APIM publishing, call the standalone publisher with `-DryRun`; see the
[Function target parameters](CreateAndDeployFunctionAndFunctionAPI.md#standalone-publishing).

For workspace artifacts, follow the explicit filter examples in
[APIOpsCLI.md](APIOpsCLI.md#filters-and-workspaces) and set `APIM_FILTER_PATH` and
`APIM_NO_TRANSITIVE` appropriately in each environment. Current
[workspace documentation](https://learn.microsoft.com/azure/api-management/workspaces-overview)
confirms Basic v2 also supports workspaces, not just Premium v2. This Bicep configuration does not create workspace
gateways or bind workspaces to gateways. Select a supported tier and resolve that
topology and its costs before attempting a workspace runtime demo; there is no
automatic upgrade or paid gateway fallback.

Legacy `{#NAME#}` token substitution is not performed. Keep resolved secrets out
of tracked files. `.azure` environment state is ignored by Git; do not commit it
or copy dev environment state into test.

## Failures and Verification

Publishing failures fail the azd command; `continueOnError` is disabled. The
publisher never enables `--delete-unmatched` and clears ambient `COMMIT_ID` while
running, so local deletions do not delete live resources and uncommitted edits are
included. Failed publishing can leave partial Azure changes; it is not rolled back.
Fix the problem, review the target, and rerun the publish step. No extraction hook
or Git automation runs at any point.

Local checks:

```powershell
bicep build ./Infrastructure/main.bicep --stdout | Out-Null
pwsh -NoProfile -File ./scripts/Test-ApimScripts.ps1 -Infrastructure -AzdHooks
```

The tests use a temporary azd environment and a stub CLI. They verify the actual
hook runner, argument forwarding, repository-relative paths, Function target binding,
temporary secret cleanup and failure propagation without calling Azure. Bicep
checks additionally assert the required APIM v2 selection, allowed SKUs, omitted azd mapping,
developer portal, output compatibility and Flex configuration. azd schema validation, actual Function packaging and the installed
CLI's artifact reader were also checked. The live five-step Azure walkthrough,
RBAC, regional availability, remote build and gateway traffic remain unverified.
The noninteractive infrastructure workflow requires a GitHub environment variable
`APIM_SKU` set to `BasicV2` or `PremiumV2`, alongside the existing publisher variables;
it passes this value directly as `apimSku` rather than prompting. The API extract
and publish workflows now use the same CLI and PowerShell scripts; see
[GitHub Actions setup](APIOpsCLI.md#github-actions). Developer-portal workflows remain
unchanged. The infrastructure workflow's existing lowercase template path
also needs to match the actual `Infrastructure` directory on Linux runners before
that workflow can deploy successfully.

## Cleanup

After reviewing the selected environment and its resources, `azd down --environment
test` deletes that environment's infrastructure. This is destructive: confirm the
resource group and ensure nothing shared or manually added must be retained. Do not
run cleanup against dev, uat, or prod merely because test cleanup is complete.
