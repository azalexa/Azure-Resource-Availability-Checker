# Azure Resource Availability Checker

An interactive PowerShell utility that checks Azure Resource Manager resource type availability across Azure regions before infrastructure deployment. It uses Azure CLI metadata from the selected subscription and does not provision or modify Azure resources.

**Current version: 3.8.1**

[![CI](https://github.com/azalexa/Azure-Resource-Availability-Checker/actions/workflows/ci.yml/badge.svg)](https://github.com/azalexa/Azure-Resource-Availability-Checker/actions/workflows/ci.yml) [![Release](https://img.shields.io/github/v/release/azalexa/Azure-Resource-Availability-Checker)](https://github.com/azalexa/Azure-Resource-Availability-Checker/releases) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## Features

- Non-interactive preflight mode for CI/CD with explicit inputs, JSON configuration, exit codes and optional structured JSON reports.

- Interactive selection of an enabled Azure subscription.
- Dynamic geography groups and region discovery, including numbered regions such as East US 2.
- Multi-region comparison with color-coded status tables and summary counts.
- Full resource type inventory by default, including technical and child resource types.
- Optional catalog of 33 common resource types or manual provider and resource type selection.
- Provider registration status displayed separately from regional availability.
- Repeated checks in the same session with refreshed location and provider metadata.
- Search resource names, provider namespaces and resource types.
- Optional SKU checks for ten service categories, with restriction metadata where available.
- Optional regional usage and quota checks for Compute, Network, Storage, SQL, Cognitive Services and Container Apps.
- Optional Azure Policy screening for a selected scope, region and resource type.
- Optional CSV export of the last successful report, only when requested.

## Requirements

- PowerShell 5.1 or later.
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli).
- An authenticated Azure account with access to an enabled subscription and permission to read resource provider metadata.

## Getting started

Download or clone this repository, open its directory in PowerShell, and run:

```powershell
az login
.\Azure-Resource-Availability-Checker.ps1
```

If Windows blocks the downloaded script, review its contents first, then use:

```powershell
Unblock-File .\Azure-Resource-Availability-Checker.ps1
```

## Usage

1. Choose an enabled Azure subscription. The main menu opens immediately.
2. Press Enter or `N` for regional availability, `K` for SKU, `U` for quota, `P` for policy, `Z` for zones, `R` for RBAC, `A` for names, or `D` for quota demand.
3. For regional availability, choose geography groups, regions and report scope. Enter `0` to select all choices in multi-select menus.
4. Review the report. Use `E` to export the last usable report, `S` to switch subscriptions, or `Q` to quit. Switching subscriptions clears the in-memory report to avoid mixing subscription data; previously saved files are not deleted. The original Azure CLI subscription is restored on exit if the checker changed it.

### Report scope

| Option | Description |
| --- | --- |
| Enter | All resource types returned by Azure Resource Manager |
| C | 33 common resource types |
| S | Manually select common resource types |
| P | Manually select resource providers and types |
| F | Search by resource name, provider namespace or resource type |

### Example output (illustrative, not live Azure data)

```text
=== Example Region ===
Status          Resource                       Registration
------          --------                       ------------
SUPPORTED       Storage Account                Registered
SUPPORTED       Key Vault                      Registered
GLOBAL          Azure DNS Zone                 Registered
UNKNOWN         SQL Database                   Registered
NOT_SUPPORTED   Example resource type          NotRegistered
```

| Status | Meaning |
| --- | --- |
| SUPPORTED | The region is listed in the resource type's location metadata. |
| NOT_SUPPORTED | The region is absent from a nonempty location list; this is not a definitive deployment denial. |
| GLOBAL | Global location is listed but the selected region is not explicitly listed. |
| UNKNOWN | Location or resource type metadata is missing or inconclusive. |
| ERROR | An error occurred while retrieving or processing metadata, if applicable. |

## SKU availability (K)

Choose regions and one or more services. Use the optional substring filter to narrow results. For App Service, enter one supported plan SKU (e.g. B1 or P1V3) and whether to filter for Linux workers. Press Enter at the SKU prompt to skip App Service. The local allowlist follows the Azure CLI values observed in live testing; future CLI versions may introduce new values.

| Service | Metadata source |
| --- | --- |
| Virtual Machine / Managed Disk | `az vm list-skus --all` (resource type filter) |
| Storage Account | Azure Resource Manager Storage SKUs API (GET) |
| App Service Plan | `az appservice list-locations --sku` |
| SQL Database | `az sql db list-editions` (unfiltered) |
| PostgreSQL Flexible Server | `az postgres flexible-server list-skus` |
| MySQL Flexible Server | `az mysql flexible-server list-skus` |
| API Management | ARM subscription SKU list (2024-05-01) |
| Azure OpenAI / Azure AI Services | `az cognitiveservices account list-skus --kind --location` (account tiers only, not model deployments) |

`LISTED` means catalog evidence was returned, not a deployment guarantee. `RESTRICTED` means an applicable restriction was detected; `ZONE_RESTRICTED` flags a zone restriction (inspect details). `RESTRICTION_UNKNOWN` means restrictions cannot be safely interpreted. `NOT_LISTED` means a region is absent from the returned list. `UNKNOWN` means metadata is missing or could not be parsed; `NO_DATA` means no matching records returned. `ERROR` means the request failed. Raw details are included in the optional CSV. For SQL Database, nested `supportedServiceLevelObjectives` are expanded using the capacity-specific objective name. `Available` and `Default` indicate catalog availability; `Visible`, `Disabled` or explicit `available: false` at objective or edition level are `UNAVAILABLE`. Unknown or missing capability metadata remains `UNKNOWN` unless another explicit field establishes availability. Edition and objective reasons are retained in raw details. An API/CLI failure is never treated as proof that a SKU is unavailable. SKU checks are limited to the services above, not all ARM providers.

Before SKU and quota queries, the checker reads provider registration state once per provider per report. `NOT_REGISTERED` means registration is explicitly absent, `REGISTERING` means registration is in progress, and `REGISTRATION_UNKNOWN` covers unconfirmed states or failed registration queries. These statuses skip the affected SKU/usage query; they do not establish regional or SKU unavailability. The separate resource and zone checks can still return catalog metadata. No provider is automatically registered. Diagnostic messages are shown below the report.

## Quota and usage (U)

Choose one or more regions and quota providers. The report includes used, limit, remaining, percentage and unit, when returned by Azure.

| Provider | CLI command |
| --- | --- |
| Compute | `az vm list-usage --location` |
| Network | `az network list-usages --location` |
| Storage | `az storage account show-usage --location` |
| SQL | `az sql list-usages --location` |
| CognitiveServices | `az cognitiveservices usage list --location` |
| ContainerApps | `az containerapp list-usages --location` (CLI version/extension may be required; regional quotas only) |

`HEADROOM` means usage is below 80% of a positive limit; `NEAR_LIMIT` means 80% or more but below the limit; `EXHAUSTED` means used is at least the limit (including a zero limit). Negative, missing or unparseable usage/limit values are `UNKNOWN`. Remaining is clamped at zero. A deployment may require more capacity than the reported headroom; VM family and total regional vCPU quotas both matter. These are provider-specific usage metrics, not a complete quota inventory. Some subscriptions may lack permissions or expose no usage metrics. SQL remaining-entitlement counters ending in DaysLeft, MonthsLeft or TokensLeft are `INFORMATIONAL`: the raw reported Used and Limit are preserved, but remaining/percent calculations and demand comparisons are disabled. Long unit names are abbreviated in the console; CSV/JSON retain the original units.

## Azure Policy screening (P)

Choose one or more regions, then optionally enter an existing resource group name and a full ARM resource type (for example `Microsoft.Storage/storageAccounts`). Leave the resource group blank to inspect subscription-level and inherited assignments only; resource-group and resource-level assignments are not included in that mode. Leave the type blank for a location-only screen. The resource group is a scope, not the region of a proposed resource.

The checker lists applicable assignments using `az policy assignment list --scope ... --filter atScope()`, retrieves definitions (including initiative members) using read-only ARM GET requests, resolves simple parameter references and evaluates a subset of policy conditions. It also attempts to list visible exemptions. Definition lookups are cached for the current check. Exact definition versions are requested when available; unresolved version constraints are flagged. No policy is assigned, modified, deleted or evaluated by the Azure Policy service.

| Status | Meaning |
| --- | --- |
| POTENTIAL_DENY | The fetched rule has a Deny effect and its supported condition evaluates true for the supplied fields. This is a warning, not proof of a deployment block. |
| REVIEW | Effect or applicability is uncertain, or the rule needs further review (for example tags, SKU, aliases, resource selectors or unresolved expressions). |
| AUDIT | A fetched audit effect is present and the supported condition is true or unknown. |
| NO_MATCH | The supported condition evaluates false for supplied fields and the fetched rule. This is not deployment approval. |
| NOT_ENFORCED | The assignment reports DoNotEnforce. |
| DISABLED | The fetched effect is Disabled and no unresolved override/version was detected. |
| SCOPE_EXCLUDED | The selected scope is covered by a reported assignment exclusion. |
| NO_ASSIGNMENTS | No applicable assignments were returned at the requested scope. This does not prove that no policy can affect deployment. |
| ERROR | A definition or initiative member could not be retrieved or processed. |

Only `location` and `type` with `equals`, `notEquals`, `in`, `notIn`, and Boolean combinations (`allOf`, `anyOf`, `not`) are screened. Unsupported fields, functions and expressions become unknown; policy expressions are never executed. Indexed mode applicability, exact resource IDs, tags, full aliases, resource payloads, initiative overrides, selectors, exemptions and wildcard version resolution are not fully evaluated. Review the actual policy in Azure Portal or use deployment validation before relying on any result. The CSV contains assignment IDs, scope, effect, condition result and explanatory caveats. Permissions to read assignments, definitions and exemptions are required for complete metadata visibility.

References: [Azure CLI policy assignments](https://learn.microsoft.com/cli/azure/policy/assignment), [assignment structure](https://learn.microsoft.com/azure/governance/policy/concepts/assignment-structure), [policy applicability](https://learn.microsoft.com/azure/governance/policy/concepts/policy-applicability).

## CSV export

Choose `E` from the main menu to export the last successful report to the current directory. The report includes the columns for its type (availability, SKU, quota, policy, zones, RBAC, names or demand), details and subscription ID. Failed or empty SKU/quota/policy checks do not replace the previous report; partial results can include error rows. It is not a cumulative history. CSV delimiters follow the system locale.

**Do not publish generated reports containing subscription IDs or other private account information.** The `.gitignore` excludes the generated report filenames.

## Limitations and safety

This is a metadata checker, not a guarantee of deployability. The default regional report does not validate SKU, kind or quota. The optional SKU and quota reports cover selected services only. The optional policy report is a partial metadata screen, not full Azure Policy evaluation. None of the reports validate actual capacity or every service-specific constraint. RBAC screens caller control-plane permission metadata; it does not prove effective authorization. Child resource types may inherit a parent location and return no location metadata. The full report can be large. Provider registration state and resource availability are separate checks.

The script does not deploy resources or register providers. It temporarily changes the locally selected Azure CLI subscription when necessary and attempts to restore the previous subscription on exit. Avoid running another process that changes the same CLI context concurrently.

## Development and testing

GitHub Actions runs syntax validation, PSScriptAnalyzer and Pester on Windows PowerShell 5.1, PowerShell 7 on Windows, and PowerShell 7 on Ubuntu for pushes to `main`, pull requests targeting `main`, and manual runs. No Azure credentials are required. Analyzer errors fail CI; warnings are reported for review. Test reports are uploaded even on failure.

Run the same checks locally from the repository root:

```powershell
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module PSScriptAnalyzer -RequiredVersion 1.24.0 -Scope CurrentUser -Force
.\tests\Invoke-CI.ps1
```

The test suite uses Pester mocks for Azure metadata and a local fake CLI launcher to exercise argument passing and error handling. It covers selected region, SKU, quota, policy, menu and export scenarios. The mocks are never used in normal execution. This is not full end-to-end Azure validation: manually verify provider-specific API behavior on an authorized test subscription before releasing changes.

Dot-sourcing the main script loads its functions for tests without starting the interactive session. Normal users should execute the script with `&` or directly by path, not dot-source it.


## Non-interactive mode (v3.4 and later)

The existing interactive menu is unchanged. For automation, authenticate Azure CLI first and invoke the script in a separate PowerShell process. Supply a subscription name or ID, one or more region names/codes and one or more full ARM resource types. The mode never prompts for selections.

```powershell
./Azure-Resource-Availability-Checker.ps1 -NonInteractive `
    -Subscription 'Your subscription' -Regions 'westeurope','eastus2' `
    -Resources 'Microsoft.Storage/storageAccounts','Microsoft.KeyVault/vaults' `
    -OutputJson './azure-preflight-report.json'
$code = $LASTEXITCODE
if ($code -ne 0) { exit $code }
```

Optional switches: `-SkuService` and `-SkuName` together (one exact SKU and service per invocation; `-AppLinux` for App Service), `-CheckQuota` with optional `-QuotaProviders Compute,Network,Storage,SQL` (defaults to all four), `-CheckPolicy` with optional `-ResourceGroup` (existing group, or subscription scope only), and `-FailOnWarning`. Policy screening runs per requested resource type; the SKU is a separate explicit check and is not inferred from resource types. Quota is advisory unless explicit additional demand is provided (see below). Names are not a substitute for resource kind, tier or actual capacity validation. Region matching is exact after normalization.

Alternatively, copy [examples/preflight.example.json](examples/preflight.example.json), replace the placeholder subscription, and run:

```powershell
./Azure-Resource-Availability-Checker.ps1 -ConfigPath ./examples/preflight.example.json
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
```

Configuration uses the named parameters as JSON keys, string arrays for Regions/Resources/QuotaProviders, and true/false for switches. ConfigPath and explicit options cannot be combined (except NonInteractive). Copy the example to `preflight.local.json` and replace the placeholder subscription and regions before running it. The example output file name and private local config are ignored by Git. Do not publish reports or private configs containing subscription IDs. JSON report output is optional and written only after checks return; early failures may produce no file. Use a fresh file path for each run and always inspect the process exit code.

| Exit code | Meaning |
| --- | --- |
| 0 | No blocking or inconclusive checks; warnings may remain. Not a deployment approval. |
| 1 | Regional support missing, provider not registered, SKU restriction/not listed, potential policy denial, or warnings in strict mode. |
| 2 | Invalid configuration, CLI/metadata error, missing/unknown required results, unconfirmed registration or subscription restoration failure. Takes precedence over 1. |

GLOBAL is inconclusive for a regional deployment and returns 2. Quota NEAR_LIMIT/EXHAUSTED, zone restrictions, audit and policy review/no assignments are warnings; `-FailOnWarning` makes these return 1. Quota errors/unknown data return 2. Explicit `NOT_REGISTERED` and SQL SKU `UNAVAILABLE` are blocking findings; pending or unknown registration returns 2. `INFORMATIONAL` quota rows do not create warnings or blocking findings by themselves. The gate is deliberately conservative; use specific resources rather than the full catalog. A green result is **not** a guarantee of deployability. Policy exemptions, overrides and conditions may require manual review. The caller must authenticate the CLI, arrange permissions, and stop deployment on nonzero codes. No Azure deployment, policy enforcement or provider registration is performed.

For a pipeline, authenticate using its supported Azure identity mechanism (prefer workload identity federation) before this step; do not commit credentials. The existing Pester CI remains offline and uses mocks. No live Azure pipeline has been configured by this update.

## Extended checks (v3.5–v3.8)

- **K:** Ten SKU categories. API Management uses the subscription SKU API; the two AI entries check account SKU tiers, not model or deployment type availability. Interactive selection supports multiple services and regional tables. Automation supports multiple exact service/SKU pairs via `SkuRequests`.
- **U:** Six quota providers, with the original four retained as the automation default for compatibility. Explicitly select `CognitiveServices` or `ContainerApps` to query the additional providers. The CLI or an extension may be required; install it separately if needed.
- **D:** Compare additional requested units with regional quota headroom. In interactive mode, select a quota from the numbered list and enter additional units (decimal dot). The prompt is skipped if there are no usable quotas. In automation, continue to use `Provider|quota label|additional units` (decimal dot). Supply the total additional units for each quota, in its reported unit. Check both total and family vCPU quotas where applicable. `FITS`, `INSUFFICIENT`, `UNKNOWN`. Duplicate demand for the same provider and label is rejected.
- **Z:** Virtual Machine, Managed Disk and API Management SKU zone metadata. The interactive view checks logical zones 1, 2 and 3; automation accepts explicit zone numbers. `LISTED`, `RESTRICTED`, `NOT_LISTED`, `UNKNOWN`, `ERROR`. Empty zone metadata does not prove lack of zone support. No live capacity check, no physical zone mapping across subscriptions.
- **R:** Query the current caller's management-plane grants at an existing resource group with the Azure Authorization permissions API. Use exact ARM actions, such as `Microsoft.Storage/storageAccounts/write`. `GRANT_LISTED` and `GRANT_NOT_LISTED` are evidence, not a complete authorization evaluation. Deny assignments, ABAC conditions, PIM changes, data-plane, locks, dependent actions and child scopes are not evaluated.
- **A:** Name availability for Storage Account, Key Vault, Container Registry, API Management and Cosmos DB. `AVAILABLE`, `UNAVAILABLE`, `NOT_FOUND`, `UNKNOWN`, `ERROR`. Cosmos DB checks name existence; `NOT_FOUND` is inconclusive for availability and returns exit 2 in automation. A nonexisting name can still be invalid. Names are checked at the service namespace, not per region, and are not reserved.

All additional reports support optional CSV export. Some services return partial data or require additional permissions. The tool never creates resources or changes RBAC, policy or quotas. It does not automatically register resource providers.

### Extended automation example

```powershell
.\Azure-Resource-Availability-Checker.ps1 `
    -NonInteractive `
    -Subscription 'Your subscription' `
    -Regions 'westeurope' `
    -Resources 'Microsoft.Storage/storageAccounts','Microsoft.Compute/virtualMachines' `
    -SkuRequests 'Storage Account|Standard_LRS','Virtual Machine|Standard_D2s_v5' `
    -ZoneRequests 'Virtual Machine|Standard_D2s_v5|1' `
    -CheckQuota -QuotaProviders Compute `
    -QuotaDemand 'Compute|Total Regional vCPUs|2' `
    -RbacGroup 'existing-rg' `
    -RbacActions 'Microsoft.Storage/storageAccounts/write' `
    -NameRequests 'Storage Account|examplecheck12345' `
    -OutputJson 'azure-preflight-report.json'
```

Adapt the quota label to the actual report, the group to an existing RG and the names to candidates you intend to use. `SkuRequests` replaces the legacy `SkuService`/`SkuName` pair if provided; do not combine the two forms. `AppLinux` applies to all App Service Plan requests in one invocation. Optional arrays `SkuRequests`, `ZoneRequests`, `QuotaDemand`, `RbacActions`, `NameRequests` and string `RbacGroup` are also valid JSON keys. See `examples/preflight.extended.example.json`.

An explicit zone restriction, unavailable name or insufficient requested quota produces a blocking finding (exit 1 unless an error takes precedence). Unknown or failed extra checks return exit 2. Missing RBAC grant evidence returns exit 2; listed grants remain warnings (strict mode blocks). This screening does not guarantee a deployment succeeds. No region is automatically recommended as deployable.

### API references

- [API Management SKU list](https://learn.microsoft.com/en-us/rest/api/apimanagement/api-management-skus/list?view=rest-apimanagement-2024-05-01)
- [Compute SKU and zone metadata](https://learn.microsoft.com/en-us/rest/api/compute/resource-skus/list?view=rest-compute-2025-02-01)
- [Resource group permissions](https://learn.microsoft.com/en-us/rest/api/authorization/permissions/list-for-resource-group?view=rest-authorization-2022-04-01)
- [Azure AI account SKUs](https://learn.microsoft.com/en-us/cli/azure/cognitiveservices/account#az-cognitiveservices-account-list-skus)

## Version history

- **3.8.1:** Live-test fixes for subscription selection, provider registration, SKU and quota interpretation, diagnostics and interactive workflow.
- **3.8:** Resource name availability.
- **3.7:** Caller RBAC grant screening.
- **3.6:** SKU availability zones.
- **3.5:** More SKU and quota providers, multi-SKU requests and explicit quota demand.
- **3.4:** Non-interactive preflight mode, JSON configuration and reports, gate exit codes.

- **3.3:** Pester regression tests, cross-platform GitHub Actions CI, test reports and README badges.

- **3.2.1:** Fix Windows Azure CLI batch-launcher quoting for policy assignment and exemption filters.
- **3.2:** Azure Policy assignment, initiative and partial location/type screening with optional CSV.
- **3.1:** Regional quota and usage checks; optional CSV for the latest report type.
- **3.0:** Resource search and SKU metadata checks.
- **2.3:** Repeat checks and explicitly requested CSV exports.
- **2.2:** Full resource type report by default and bulk provider metadata retrieval.
- **2.1:** Corrected subscription switching and region discovery.
- **2.0:** Interactive geography, region and resource selection.

## License

See [LICENSE](LICENSE).
