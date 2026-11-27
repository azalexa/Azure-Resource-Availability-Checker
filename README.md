# Azure Resource Availability Checker

An interactive PowerShell utility that checks Azure Resource Manager resource type availability across Azure regions before infrastructure deployment. It uses Azure CLI metadata from the selected subscription and does not provision or modify Azure resources.

**Current version: 3.1**

## Features

- Interactive selection of an enabled Azure subscription.
- Dynamic geography groups and region discovery, including numbered regions such as East US 2.
- Multi-region comparison with color-coded status tables and summary counts.
- Full resource type inventory by default, including technical and child resource types.
- Optional catalog of 33 common resource types or manual provider and resource type selection.
- Provider registration status displayed separately from regional availability.
- Repeated checks in the same session with refreshed location and provider metadata.
- Search resource names, provider namespaces and resource types.
- Optional SKU checks for seven service categories, with restriction metadata where available.
- Optional regional usage and quota checks for Compute, Network, Storage and SQL.
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

1. Choose an Azure subscription.
2. Choose one or more geography groups.
3. Choose one or more Azure regions. Enter `0` to select all listed choices.
4. Press Enter to check all returned Azure resource types, or choose a narrower report scope.
5. Review the regional availability tables and region comparison.
6. Press Enter or `N` to run another check, `K` for SKU, `U` for quota, `E` to export the last successful report, or `Q` to quit.

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

Choose regions and one or more services. Use the optional substring filter to narrow results. For App Service, enter one plan SKU (e.g. B1 or P1V3) and whether to filter for Linux workers.

| Service | Metadata source |
| --- | --- |
| Virtual Machine / Managed Disk | `az vm list-skus --all` (resource type filter) |
| Storage Account | Azure Resource Manager Storage SKUs API (GET) |
| App Service Plan | `az appservice list-locations --sku` |
| SQL Database | `az sql db list-editions --available` |
| PostgreSQL Flexible Server | `az postgres flexible-server list-skus` |
| MySQL Flexible Server | `az mysql flexible-server list-skus` |

`LISTED` means catalog evidence was returned, not a deployment guarantee. `RESTRICTED` means an applicable restriction was detected; `ZONE_RESTRICTED` flags a zone restriction (inspect details). `RESTRICTION_UNKNOWN` means restrictions cannot be safely interpreted. `NOT_LISTED` means a region is absent from the returned list. `UNKNOWN` means metadata is missing or could not be parsed; `NO_DATA` means no matching records returned. `ERROR` means the request failed. Raw details are included in the optional CSV. An API/CLI failure is never treated as proof that a SKU is unavailable. SKU checks are limited to the services above, not all ARM providers.

## Quota and usage (U)

Choose one or more regions and quota providers. The report includes used, limit, remaining, percentage and unit, when returned by Azure.

| Provider | CLI command |
| --- | --- |
| Compute | `az vm list-usage --location` |
| Network | `az network list-usages --location` |
| Storage | `az storage account show-usage --location` |
| SQL | `az sql list-usages --location` |

`HEADROOM` means usage is below 80% of a positive limit; `NEAR_LIMIT` means 80% or more but below the limit; `EXHAUSTED` means used is at least the limit (including a zero limit). Negative, missing or unparseable usage/limit values are `UNKNOWN`. Remaining is clamped at zero. A deployment may require more capacity than the reported headroom; VM family and total regional vCPU quotas both matter. These are provider-specific usage metrics, not a complete quota inventory. Some subscriptions may lack permissions or expose no usage metrics.

## CSV export

Choose `E` from the main menu to export the last successful report to the current directory. The report includes the columns for its type (availability, SKU or quota), details and subscription ID. Failed or empty SKU/quota checks do not replace the previous report; partial results can include error rows. It is not a cumulative history. CSV delimiters follow the system locale.

**Do not publish generated reports containing subscription IDs or other private account information.** The `.gitignore` excludes the generated report filenames.

## Limitations and safety

This is a metadata checker, not a guarantee of deployability. The default regional report does not validate SKU, kind or quota. The optional SKU and quota reports cover selected services only. None of the reports validate actual capacity, Azure Policy, deployment permissions or every service-specific constraint. Child resource types may inherit a parent location and return no location metadata. The full report can be large. Provider registration state and resource availability are separate checks.

The script does not deploy resources or register providers. It temporarily changes the locally selected Azure CLI subscription when necessary and attempts to restore the previous subscription on exit. Avoid running another process that changes the same CLI context concurrently.

## Version history

- **3.1:** Regional quota and usage checks; optional CSV for the latest report type.
- **3.0:** Resource search and SKU metadata checks.
- **2.3:** Repeat checks and explicitly requested CSV exports.
- **2.2:** Full resource type report by default and bulk provider metadata retrieval.
- **2.1:** Corrected subscription switching and region discovery.
- **2.0:** Interactive geography, region and resource selection.

## License

See [LICENSE](LICENSE).
