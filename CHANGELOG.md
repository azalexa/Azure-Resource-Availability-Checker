# Changelog

## 3.4

- Add explicit automation inputs and JSON configuration without menu prompts.
- Add optional JSON reports and conservative exit codes for CI/CD.
- Reuse resource, SKU, quota and policy checks with selected inputs.
- Add tests for automation options, gate decisions and prompt-free availability.

## 3.3

- Add Pester regression tests for region availability, SKU restrictions, quota boundaries, policy conditions, menus, CSV and CLI errors.
- Exercise native command argument handling with a local fake Azure CLI launcher.
- Add GitHub Actions CI for Windows PowerShell 5.1, PowerShell 7 on Windows and PowerShell 7 on Ubuntu, including syntax and analyzer checks.
- Make function loading and CSV export testable without starting an Azure session.
- Add CI, release and license badges to the README.

## 3.2.1

- Fix Windows `az.cmd` / `az.bat` argument passing for the `atScope()` filter in both policy assignment and exemption queries.
- Preserve unmodified filter arguments for native executables and non-Windows launchers.

## 3.2

- Add optional Azure Policy screening from the main menu (`P`).
- Read applicable and inherited assignments at subscription or selected resource group scope, expand initiatives and resolve simple parameters.
- Screen location and resource type conditions with conservative, three-valued logic.
- Flag potential Deny effects, audit effects, disabled or non-enforced assignments, exclusions and uncertainty.
- Attempt exemption discovery and flag unhandled selectors, overrides and version constraints.
- Allow optional CSV export of the policy report; preserve previous report if all new rows fail.
- Keep checks read-only; no full deployment or policy simulation.

## 3.1

- Add optional regional quota and usage reports for Compute, Network, Storage and SQL.
- Show used, limit, remaining, percentage and status when available.
- Preserve the previous report if all new checks fail or return no data.

## 3.0 (included in 3.1)

- Add resource search by name, namespace and type.
- Add optional SKU metadata checks for VM, disks, Storage, App Service, SQL, PostgreSQL and MySQL.
- Distinguish SKU catalog evidence, restrictions, missing data and request errors.

## 2.3

- Repeat checks within a session; export CSV only on request.

## 2.2

- Full resource-type inventory by default; bulk provider metadata retrieval.

## 2.1

- Correct Azure CLI subscription selection and region discovery.

## 2.0

- Interactive geography, region and resource selection.
