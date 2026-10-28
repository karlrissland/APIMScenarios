# Deploy a Function and Its APIM API

The repository includes a Python HTTP Function and a separate `Demo Function API`
alongside the original Echo API. Follow [the dev/test setup](DeployChangesDevToProd.md)
first for explicit subscription, region, publisher identity, authentication and cost
settings. Nothing in this scenario provisions resources until you run azd yourself.

## Deployment Order

`azd up --environment dev` runs these steps:

1. Package [src/Function](../src/Function) with azd. Python dependencies are built
	remotely on Azure, not vendored into the repository.
2. Provision APIM, a Linux Flex Consumption (FC1) Function hosting plan, storage,
	and a private deployment container.
3. Deploy the Function code to `FUNCTION_SERVICE_NAME`.
4. Run the root PowerShell `postdeploy` hook. It passes the selected environment's
	Function name and `FUNCTION_BACKEND_URL` to the standalone APIM publisher.
5. Resolve that Function's default host key using Azure CLI, prepare a temporary
	artifact copy, and publish its APIM configuration.

The Function uses Python 3.14 on Functions runtime v4 and the v2 programming model.
Python 3.14 is GA in the current [supported language matrix](https://learn.microsoft.com/azure/azure-functions/supported-languages).
Flex uses 2048 MB instances, a maximum of 40 instances and no always-ready instances.
HTTPS is required. Runtime and deployment storage are configured through
`functionAppConfig`; the existing storage connection-string authentication is
retained. This is not a managed-identity migration. The `remoteBuild: true` azd
setting is supported on this plan; legacy Oryx build app settings are not needed.

## Moving an Existing S1 Deployment to Flex

Azure does not support [in-place migration to Flex](https://learn.microsoft.com/azure/azure-functions/functions-how-to-use-azure-function-app-settings#plan-migration).
The template therefore uses new names: `FuncApp-flex-<suffix>` and
`hpn-flex-<suffix>`. The existing storage account is reused, with a private
`function-releases` blob container for deployments.

For an existing dev environment, run these steps from the repository root:

```powershell
azd provision --environment dev
azd deploy --all --environment dev
```

Provisioning must run first: it creates the Flex resources and refreshes
`FUNCTION_SERVICE_NAME` and `FUNCTION_BACKEND_URL`. Running only `azd deploy`
before provisioning still targets the old S1 app. The deploy step then publishes
APIM using the new Function URL and key. For a new environment, use `azd up`.
Sweden Central and Python 3.14 Flex availability were verified on 2026-10-28;
check availability and quota for other subscriptions or regions.

The old app and S1 plan are not deleted or stopped. The S1 plan remains billable
until you explicitly remove it after verifying the new app. No cleanup is
automated; preserve any apps or data you still need.

## Authentication

Both `azd auth login` and `az login` are required for this local workflow. The
Azure CLI identity needs `Microsoft.Web/sites/host/listkeys/action` on the target
Function, in addition to the APIOps identity's APIM write access. A Reader role
alone cannot retrieve Function keys. No roles are assigned by the scripts.

## Verify the Target

The Function exposes `GET /api/hello?name=Demo`. Through APIM, the route is
`GET /function-demo/hello?name=Demo` on the selected gateway. In the Azure portal,
open **Demo Function API**, select **hello**, and use the test console. This API
requires an APIM subscription key. Use an API-scoped or all-APIs subscription;
the new API is not automatically added to the Starter or Unlimited products.

A test deployment should return:

```json
{
  "message": "Hello, Demo!",
  "environment": "test"
}
```

The Function itself also requires a Function key; APIM supplies it through the
backend's `x-functions-key` header. Clients need only their APIM subscription key,
not the Function key. Function-key authentication does not restrict network access
to APIM: a caller possessing a valid Function key can invoke the Function directly.

## Promotion and Local Edits

Extract dev using [Extract-ApimArtifacts.ps1](../scripts/Extract-ApimArtifacts.ps1),
then run `azd up --environment test`. Extraction redacts the secret named value.
The publisher resolves the test Function key and replaces the dev backend URL in
its temporary copy, so the extracted URL never causes test to call dev.

Edit [the Function](../src/Function/function_app.py), its
[OpenAPI definition](../src/APIM/apis/demo-function-api/specification.yaml), or its
[APIM policy](../src/APIM/apis/demo-function-api/policy.xml), then rerun
`azd up --environment test`. Committing is not required. Once provisioned,
`azd deploy --all --environment test` deploys Function code and republishes APIM.
Do not use `azd provision` alone to publish code or API artifacts.

## Standalone Publishing

No azd is required. After deploying your Function code separately, pass explicit
target identifiers from the repository root:

```powershell
$target = @{
	 SubscriptionId = '<subscription-id>'
	 ResourceGroupName = '<target-apim-resource-group>'
	 ServiceName = '<target-apim-name>'
	 FunctionAppName = '<target-function-app-name>'
	 FunctionResourceGroupName = '<target-function-resource-group>'
	 FunctionBackendUrl = 'https://<target-function-hostname>/api'
}
./scripts/Publish-ApimArtifacts.ps1 @target -DryRun
./scripts/Publish-ApimArtifacts.ps1 @target
```

The Function resource group defaults to the APIM resource group if omitted. The
URL must be the target's HTTPS `/api` base URL, without a key or query string.
The scripts do not infer a Function name from an extracted URL.

Binding is opt-in for standalone publishing. Generic artifact sets and workspace
filters do not require Function credentials. To publish this sample, supply the
Function parameters above or complete CLI-compatible target overrides. The
checked-in redacted secret and placeholder URL are not deployable credentials.
Only the reserved `demo-function` backend and `demo-function-key` named value are
rebound; other backends require your explicit overrides. Renaming those reserved
resources requires updating the binding code. Explicit overrides are applied
after binding and can supersede it; review them for stale URLs or keys.

## Secrets and Workspaces

The actual key is captured in memory, written only to a temporary artifact copy,
and removed with that copy in `finally`, including on a failed publish. The source
artifacts are never rewritten. On Unix the temporary directory is owner-only; on
Windows it inherits the current user's temporary-directory ACLs. This is cleanup,
not secure disk erasure; process termination can bypass it. Do not retain, upload,
or debug-log temporary publish artifacts. No key is placed in azd outputs, azd
environment settings, command arguments, or committed overrides.

`-DryRun` still reads the Function key and may read Azure state. The azd
`APIM_PUBLISH_DRY_RUN` setting affects only APIM: azd still deploys Function code,
and `azd up` can still provision infrastructure. To preview only APIM publishing,
use the standalone command above rather than `azd deploy` or `azd up`.

The binder also recognizes `demo-function` and `demo-function-key` under each
`workspaces/<name>` artifact scope. A workspace API must use its own backend and
named value, not service-level ones. Use the explicit workspace-only filter in
[APIOpsCLI.md](APIOpsCLI.md#filters-and-workspaces), and review its dry run.
This does not provision workspace gateways or grant access to them. Developer SKU
does not support workspaces; an approved compatible tier and gateway association
must already exist. Preserve and verify workspace gateway connectivity when
publishing workspace metadata. No live workspace routing is claimed here.

## Local Verification and Failures

With a supported Python interpreter and the requirements installed:

```powershell
Push-Location ./src/Function
python -m pip install -r requirements.txt
python -m unittest discover -s tests -v
Pop-Location
pwsh -NoProfile -File ./scripts/Test-ApimScripts.ps1 -AzdHooks -Infrastructure
```

The optional `-Infrastructure` checks require the Bicep CLI. They compile both
templates and verify the Flex plan, runtime, private deployment container and
creation dependency, scaling, separate resource names and azd output contract.

Local verification covered Function behavior on Python 3.12 with SDK 1.24.0,
actual azd packaging, the installed CLI's artifact reader, Bicep compilation and
actual azd hooks with stub CLIs. It did not exercise Azure's Python 3.14 remote
build or live gateway traffic. A key lookup failure stops APIM publishing; ensure
the Function deployment is healthy and the CLI identity has permission, then rerun.
An APIM failure can leave partial changes and fails the azd command; no rollback
or key rotation is performed.
