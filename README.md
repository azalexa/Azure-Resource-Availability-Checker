# Azure Resource Availability Checker

An interactive PowerShell utility that checks Azure Resource Manager resource type availability across Azure regions before infrastructure deployment. It uses Azure CLI metadata from the selected subscription and does not provision or modify Azure resources.

**Current version: 2.3**

## Features

- Interactive selection of an enabled Azure subscription.
- Dynamic geography groups and region discovery, including numbered regions such as East US 2.
- Multi-region comparison with color-coded status tables and summary counts.
- Full resource type inventory by default, including technical and child resource types.
- Optional catalog of 33 common resource types or manual provider and resource type selection.
- Provider registration status displayed separately from regional availability.
- Repeated checks in the same session with refreshed location and provider metadata.
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
6. Press Enter or `N` to run another check, `E` to export the last successful report, or `Q` to quit.

### Report scope

| Option | Description |
| --- | --- |
| Enter | All resource types returned by Azure Resource Manager |
| C | 33 common resource types |
| S | Manually select common resource types |
| P | Manually select resource providers and types |

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

## CSV export

Choose `E` from the main menu to export the last successful report to the current directory. The report includes region, resource name, status, registration state, provider, resource type, explanation and subscription ID. It is not a cumulative history. CSV delimiters follow the system locale.

**Do not publish generated reports containing subscription IDs or other private account information.** The `.gitignore` excludes the generated report filenames.

## Limitations and safety

This is a metadata checker, not a guarantee of deployability. It does not validate SKU, kind, quota, capacity, Azure Policy, permissions or service-specific constraints. Child resource types may inherit a parent location and return no location metadata. The full report can be large. Provider registration state and resource availability are separate checks.

The script does not deploy resources or register providers. It temporarily changes the locally selected Azure CLI subscription when necessary and attempts to restore the previous subscription on exit. Avoid running another process that changes the same CLI context concurrently.

## Version history

- **2.3:** Repeat checks and explicitly requested CSV exports.
- **2.2:** Full resource type report by default and bulk provider metadata retrieval.
- **2.1:** Corrected subscription switching and region discovery.
- **2.0:** Interactive geography, region and resource selection.

## License

See [LICENSE](LICENSE).
