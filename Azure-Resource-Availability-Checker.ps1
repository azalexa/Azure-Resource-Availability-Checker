#Requires -Version 5.1
<#
.SYNOPSIS
    Azure Resource Availability Checker v2.3. Interactive, read-only regional availability checker.
.DESCRIPTION
    Uses Azure CLI and the selected subscription. Does not register providers,
    deploy resources or check SKU availability. Defaults to all resource types
    returned by Azure Resource Manager; optionally filters the report. Supports repeated
    checks and exports the last successful report only on request. Temporarily switches the local
    Azure CLI subscription and restores the previous selection on exit.
#>
$ErrorActionPreference = 'Stop'

function Invoke-AzJson {
    param([string[]]$Arguments)
    $raw = & az @Arguments --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI command failed: az $($Arguments -join ' ')" }
    if (-not $raw) { throw 'Azure CLI returned no data.' }
    ($raw -join "`n") | ConvertFrom-Json
}

function Select-Menu {
    param([string]$Title, [object[]]$Items, [string]$Label = 'Name', [switch]$Multiple)
    if ($Items.Count -eq 0) { throw "No choices available: $Title" }
    Write-Host "`n=== $Title ===" -ForegroundColor Cyan
    if ($Multiple) { Write-Host '[0] All' }
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ('[{0}] {1}' -f ($i + 1), $Items[$i].$Label)
    }
    Write-Host '[Q] Quit'
    while ($true) {
        $prompt = if ($Multiple) { 'Select numbers (e.g. 1,3,5), 0 for all' } else { 'Select a number' }
        $answer = (Read-Host $prompt).Trim()
        if ($answer -eq 'Q') { throw [System.OperationCanceledException]::new('Cancelled by user.') }
        if ($Multiple -and $answer -eq '0') { return $Items }
        $tokens = @($answer -split ',' | ForEach-Object { $_.Trim() })
        $indices = @()
        $valid = $Multiple -or $tokens.Count -eq 1
        foreach ($token in $tokens) {
            $n = 0
            if (-not [int]::TryParse($token, [ref]$n) -or $n -lt 1 -or $n -gt $Items.Count) {
                $valid = $false; break
            }
            $indices += ($n - 1)
        }
        if ($valid -and $indices.Count -gt 0) {
            foreach ($index in ($indices | Select-Object -Unique)) { $Items[$index] }
            return
        }
        Write-Host 'Invalid selection. Try again.' -ForegroundColor Yellow
    }
}

function New-Resource {
    param([string]$Name, [string]$Provider, [string]$Type)
    [pscustomobject]@{ Name = $Name; Provider = $Provider; Type = $Type }
}

function Normalize-Location {
    param([string]$Value)
    ($Value -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
}

$catalog = @(
    New-Resource 'Storage Account' 'Microsoft.Storage' 'storageAccounts'
    New-Resource 'Key Vault' 'Microsoft.KeyVault' 'vaults'
    New-Resource 'SQL Server' 'Microsoft.Sql' 'servers'
    New-Resource 'SQL Database' 'Microsoft.Sql' 'servers/databases'
    New-Resource 'PostgreSQL Flexible Server' 'Microsoft.DBforPostgreSQL' 'flexibleServers'
    New-Resource 'MySQL Flexible Server' 'Microsoft.DBforMySQL' 'flexibleServers'
    New-Resource 'Cosmos DB' 'Microsoft.DocumentDB' 'databaseAccounts'
    New-Resource 'App Service / Function App' 'Microsoft.Web' 'sites'
    New-Resource 'App Service Plan' 'Microsoft.Web' 'serverfarms'
    New-Resource 'Static Web Apps' 'Microsoft.Web' 'staticSites'
    New-Resource 'Virtual Network' 'Microsoft.Network' 'virtualNetworks'
    New-Resource 'Network Security Group' 'Microsoft.Network' 'networkSecurityGroups'
    New-Resource 'Public IP' 'Microsoft.Network' 'publicIPAddresses'
    New-Resource 'Private Endpoint' 'Microsoft.Network' 'privateEndpoints'
    New-Resource 'Application Gateway' 'Microsoft.Network' 'applicationGateways'
    New-Resource 'Log Analytics' 'Microsoft.OperationalInsights' 'workspaces'
    New-Resource 'Application Insights' 'Microsoft.Insights' 'components'
    New-Resource 'Virtual Machine' 'Microsoft.Compute' 'virtualMachines'
    New-Resource 'Managed Disk' 'Microsoft.Compute' 'disks'
    New-Resource 'Container Registry' 'Microsoft.ContainerRegistry' 'registries'
    New-Resource 'AKS' 'Microsoft.ContainerService' 'managedClusters'
    New-Resource 'Container Apps' 'Microsoft.App' 'containerApps'
    New-Resource 'Container Apps Environment' 'Microsoft.App' 'managedEnvironments'
    New-Resource 'API Management' 'Microsoft.ApiManagement' 'service'
    New-Resource 'Service Bus' 'Microsoft.ServiceBus' 'namespaces'
    New-Resource 'Event Hubs' 'Microsoft.EventHub' 'namespaces'
    New-Resource 'Recovery Services Vault' 'Microsoft.RecoveryServices' 'vaults'
    New-Resource 'Backup Vault' 'Microsoft.DataProtection' 'backupVaults'
    New-Resource 'Azure AI Services / Azure OpenAI account' 'Microsoft.CognitiveServices' 'accounts'
    New-Resource 'Azure AI Search' 'Microsoft.Search' 'searchServices'
    New-Resource 'Managed Identity' 'Microsoft.ManagedIdentity' 'userAssignedIdentities'
    New-Resource 'Azure DNS Zone' 'Microsoft.Network' 'dnszones'
    New-Resource 'Azure Front Door Standard/Premium profile' 'Microsoft.Cdn' 'profiles'
)

function Invoke-AvailabilityCheck {
    param([string]$SubId, [object[]]$Catalog)

    # Re-read locations and provider metadata on every check.
    if ((Invoke-AzJson @('account','show')).id -ne $SubId) {
        throw 'Active Azure CLI subscription has changed. Restart the checker to select a subscription.'
    }

    $regions = @(Invoke-AzJson @('account','list-locations') | Where-Object {
        ($_.metadata.regionType -eq 'Physical' -or (-not $_.metadata.regionType -and $_.type -eq 'Region')) -and (-not $_.type -or $_.type -eq 'Region')
    } | ForEach-Object {
        $group = if ($_.metadata.geographyGroup) { $_.metadata.geographyGroup } else { 'Other / Unspecified' }
        [pscustomobject]@{ Name = $_.name; DisplayName = $_.displayName; RegionalDisplayName = $_.regionalDisplayName; Group = $group; Label = "$($_.displayName) ($($_.name))" }
    } | Sort-Object DisplayName)
    if ($regions.Count -eq 0) { throw 'No physical regions returned for this subscription.' }
    $groups = @($regions | Group-Object Group | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Label = "$($_.Name) ($($_.Count) regions)" }
    })
    $chosenGroups = @(Select-Menu -Title 'Geography groups' -Items $groups -Label 'Label' -Multiple)
    $possibleRegions = @($regions | Where-Object { $_.Group -in $chosenGroups.Name })
    $chosenRegions = @(Select-Menu -Title 'Azure regions' -Items $possibleRegions -Label 'Label' -Multiple)

    Write-Host "`n=== Report scope ===" -ForegroundColor Cyan
    Write-Host '[Enter] All Azure resource types (default)'
    Write-Host '[C] Common services (33 built-in resource types)'
    Write-Host '[S] Select common services manually'
    Write-Host '[P] Select resource providers and types manually'
    Write-Host '[Q] Quit'
    do {
        $mode = (Read-Host 'Report scope [Enter for all]').Trim().ToUpperInvariant()
        if ($mode -eq 'Q') { throw [System.OperationCanceledException]::new('Cancelled by user.') }
        if ($mode -notin @('', 'C', 'S', 'P')) { Write-Host 'Invalid selection.' -ForegroundColor Yellow }
    } until ($mode -in @('', 'C', 'S', 'P'))

    $cache = @{}
    $typeIndex = @{}
    $friendlyNames = @{}
    foreach ($item in $catalog) { $friendlyNames["$($item.Provider)/$($item.Type)"] = $item.Name }

    Write-Host 'Loading Azure resource provider metadata...' -ForegroundColor Cyan
    # The provider list includes resourceTypes and locations. One bulk request
    # avoids making a separate Azure CLI invocation for every provider.
    $providers = @(Invoke-AzJson @('provider','list','--subscription',$subId,'--query','[].{namespace:namespace,registrationState:registrationState,resourceTypes:resourceTypes[].{resourceType:resourceType,locations:locations}}'))
    if ($providers.Count -eq 0) { throw 'Azure returned no resource providers.' }
    foreach ($p in $providers) {
        if (-not $p.namespace) { continue }
        $cache[$p.namespace] = @{ Data = $p; Error = $null }
        foreach ($t in @($p.resourceTypes)) {
            if ($t.resourceType) { $typeIndex["$($p.namespace)/$($t.resourceType)"] = $t }
        }
    }
    if ($typeIndex.Count -eq 0) { throw 'Azure returned no resource type metadata.' }

    if ($mode -eq 'C') {
        $chosenResources = @($catalog)
    } elseif ($mode -eq 'S') {
        $chosenResources = @(Select-Menu -Title 'Resource types' -Items $catalog -Multiple)
    } else {
        $selectedProviders = @($providers | Where-Object { $_.namespace -and $_.resourceTypes } | Sort-Object namespace)
        if ($mode -eq 'P') {
            $providerMenu = @($selectedProviders | ForEach-Object { [pscustomobject]@{ Name = $_.namespace; Data = $_ } })
            $selectedProviders = @(Select-Menu -Title 'Resource providers' -Items $providerMenu -Multiple | ForEach-Object { $_.Data })
        }
        $chosenResources = @(foreach ($p in $selectedProviders) {
            $types = @($p.resourceTypes | Where-Object { $_.resourceType } | Sort-Object resourceType -Unique | ForEach-Object {
                $key = "$($p.namespace)/$($_.resourceType)"
                $name = if ($friendlyNames.ContainsKey($key)) { $friendlyNames[$key] } else { $key }
                New-Resource $name $p.namespace $_.resourceType
            })
            if ($mode -eq 'P' -and $types.Count -gt 0) {
                Select-Menu -Title "Resource types: $($p.namespace)" -Items $types -Multiple
            } else { $types }
        })
    }
    if ($chosenResources.Count -eq 0) { throw 'No resource types selected.' }
    $chosenResources = @($chosenResources | Sort-Object Name, Provider, Type)
    Write-Host ("Checking {0} resource types across {1} region(s)..." -f $chosenResources.Count, $chosenRegions.Count) -ForegroundColor Cyan

    $results = @(foreach ($region in $chosenRegions) {
        $aliases = @(@($region.Name, $region.DisplayName, $region.RegionalDisplayName) | Where-Object { $_ } | ForEach-Object { Normalize-Location $_ })
        foreach ($resource in $chosenResources) {
            $entry = $cache[$resource.Provider]
            $registration = 'Unknown'
            $status = 'UNKNOWN'
            $detail = ''
            if (-not $entry) {
                $detail = 'Provider not returned for this subscription.'
            } elseif ($entry.Error) {
                $status = 'ERROR'; $detail = $entry.Error
            } else {
                $registration = $entry.Data.registrationState
                if (-not $registration) { $registration = 'Unknown' }
                $type = $typeIndex["$($resource.Provider)/$($resource.Type)"]
                $locations = @($type.locations | Where-Object { $_ })
                if (-not $type) { $detail = 'Resource type not returned by provider.' }
                elseif ($locations.Count -eq 0) { $detail = 'No regional metadata; may inherit parent location or use another scope.' }
                else {
                    $normalized = @($locations | ForEach-Object { Normalize-Location $_ })
                    if (@($aliases | Where-Object { $_ -in $normalized }).Count -gt 0) {
                        $status = 'SUPPORTED'; $detail = 'Region listed for resource type.'
                    } elseif ('global' -in $normalized) {
                        $status = 'GLOBAL'; $detail = 'Global location listed; not a regional availability confirmation.'
                    } else {
                        $status = 'NOT_SUPPORTED'; $detail = 'Region not listed in provider metadata.'
                    }
                }
            }
            [pscustomobject]@{
                Region = $region.DisplayName; RegionCode = $region.Name; Resource = $resource.Name
                Status = $status; Registration = $registration; Provider = $resource.Provider
                ResourceType = $resource.Type; Detail = $detail; SubscriptionId = $subId
            }
        }
    })

    $tableWidth = 120
    try { $tableWidth = [Math]::Max(80, $Host.UI.RawUI.BufferSize.Width) } catch { }
    foreach ($region in $chosenRegions) {
        $rows = @($results | Where-Object { $_.RegionCode -eq $region.Name })
        Write-Host "`n=== $($region.DisplayName) ===" -ForegroundColor Cyan
        # Keep status first so that the console can color each table row.
        $table = $rows | Format-Table Status, Resource, Registration -AutoSize -Wrap | Out-String -Stream -Width $tableWidth
        foreach ($line in $table) {
            $color = switch -Regex ($line) {
                '^\s*SUPPORTED\s' { 'Green'; break }
                '^\s*NOT_SUPPORTED\s' { 'Red'; break }
                '^\s*ERROR\s' { 'Red'; break }
                '^\s*(GLOBAL|UNKNOWN)\s' { 'Yellow'; break }
                default { 'Gray' }
            }
            Write-Host $line -ForegroundColor $color
        }
        $supported = @($rows | Where-Object { $_.Status -eq 'SUPPORTED' }).Count
        Write-Host "Regional support: $supported/$($rows.Count) resource types. GLOBAL and UNKNOWN are not counted."
    }
    Write-Host "`n=== Region comparison ===" -ForegroundColor Cyan
    $results | Group-Object Region | ForEach-Object {
        $g = $_.Group
        [pscustomobject]@{
            Region = $_.Name; Supported = @($g | Where-Object Status -eq 'SUPPORTED').Count
            NotSupported = @($g | Where-Object Status -eq 'NOT_SUPPORTED').Count
            Global = @($g | Where-Object Status -eq 'GLOBAL').Count
            Unknown = @($g | Where-Object Status -eq 'UNKNOWN').Count
            Error = @($g | Where-Object Status -eq 'ERROR').Count
            NotRegistered = @($g | Where-Object { $_.Registration -notin @('Registered','Unknown') }).Count
            RegistrationUnknown = @($g | Where-Object { $_.Registration -eq 'Unknown' }).Count
        }
    } | Sort-Object @{Expression='Supported';Descending=$true}, Region | Format-Table -AutoSize | Out-Host

    Write-Host 'NOT_SUPPORTED means the region is absent from the nonempty location list; UNKNOWN means missing metadata. GLOBAL is not regional support.' -ForegroundColor Yellow
    Write-Host 'Metadata only: SKU, kind, quota, policy, permissions and capacity are not validated.' -ForegroundColor Yellow
    return $results
}

$previousSubId = $null
$restoreSubscription = $false

try {
    Write-Host 'AZURE RESOURCE AVAILABILITY CHECKER v2.3' -ForegroundColor Cyan
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI not found. Install it first.' }
    $subscriptions = @(Invoke-AzJson @('account','list') | Where-Object { $_.state -eq 'Enabled' } | Sort-Object name | ForEach-Object {
        [pscustomobject]@{ Name = "$($_.name) ($($_.id))"; Id = $_.id }
    })
    if ($subscriptions.Count -eq 0) { throw 'No enabled subscription found. Run az login first.' }
    $subscription = Select-Menu -Title 'Subscription' -Items $subscriptions
    $subId = $subscription.Id

    $previousSubId = (Invoke-AzJson @('account','show')).id
    if (-not $previousSubId) { throw 'Cannot determine the current Azure CLI subscription.' }
    if ($previousSubId -ne $subId) {
        $restoreSubscription = $true
        & az account set --subscription $subId --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw 'Cannot select the requested subscription.' }
    }
    $activeSubId = (Invoke-AzJson @('account','show')).id
    if ($activeSubId -ne $subId) { throw 'Active Azure CLI subscription does not match the selection.' }

    # Run the first check directly. Subsequent checks and exports are independent menu actions.
    $lastResults = @()
    $action = 'N'
    while ($true) {
        if ($action -eq 'Q') { break }
        if ($action -eq 'N') {
            try {
                $newResults = @(Invoke-AvailabilityCheck -SubId $subId -Catalog $catalog)
                if ($newResults.Count -gt 0) { $lastResults = $newResults }
            } catch [System.OperationCanceledException] {
                throw
            } catch {
                Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
                if ($lastResults.Count -gt 0) {
                    Write-Host 'The last successful report is still available for export.' -ForegroundColor Yellow
                }
            }
        } elseif ($action -eq 'E') {
            if ($lastResults.Count -eq 0) {
                Write-Host 'No successful report to export. Run a check first.' -ForegroundColor Yellow
            } else {
                try {
                    $path = Join-Path (Get-Location).Path ('azure-availability-{0}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
                    $lastResults | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8 -UseCulture
                    Write-Host "Saved: $path" -ForegroundColor Green
                } catch {
                    Write-Host "Export failed: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }

        Write-Host "`n=== Main menu ===" -ForegroundColor Cyan
        Write-Host "Subscription: $($subscription.Name)"
        Write-Host '[Enter / N] New availability check (choose regions and scope)'
        if ($lastResults.Count -gt 0) {
            $reportRegions = @($lastResults | Select-Object -ExpandProperty Region -Unique) -join ', '
            Write-Host "[E] Export last successful report to CSV ($($lastResults.Count) rows; $reportRegions)"
        } else {
            Write-Host '[E] Export last report (no report available)' -ForegroundColor DarkGray
        }
        Write-Host '[Q] Quit'
        do {
            $action = (Read-Host 'Select action [Enter for new check]').Trim().ToUpperInvariant()
            if ($action -eq '') { $action = 'N' }
            if ($action -notin @('N','E','Q')) { Write-Host 'Invalid selection. Try again.' -ForegroundColor Yellow }
        } until ($action -in @('N','E','Q'))
    }
} catch [System.OperationCanceledException] {
    Write-Host 'Cancelled.'
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    if ($restoreSubscription -and $previousSubId) {
        try {
            & az account set --subscription $previousSubId --only-show-errors
            if ($LASTEXITCODE -ne 0) { throw 'Azure CLI returned an error.' }
            Write-Host 'Previous Azure CLI subscription restored.' -ForegroundColor Gray
        } catch {
            Write-Warning "Could not restore previous subscription. Run: az account set --subscription $previousSubId"
        }
    }
}
