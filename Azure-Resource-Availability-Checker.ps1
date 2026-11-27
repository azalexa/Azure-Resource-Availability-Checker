#Requires -Version 5.1
<#
.SYNOPSIS
    Azure Resource Availability Checker v3.8.1. Interactive, read-only regional availability checker.
.DESCRIPTION
    Uses Azure CLI and the selected subscription. Does not register providers,
    deploy resources. Includes optional SKU, quota and policy screening checks. Defaults to all resource types
    returned by Azure Resource Manager; optionally filters the report. Supports repeated
    checks and exports the last successful report only on request. Temporarily switches the local
    Azure CLI subscription and restores the previous selection on exit.
#>
[CmdletBinding()]
param(
    [switch]$NonInteractive,
    [string]$Subscription,
    [Alias('Region')][string[]]$Regions,
    [string[]]$Resources,
    [string]$SkuService,
    [string]$SkuName,
    [switch]$AppLinux,
    [switch]$CheckQuota,
    [string[]]$QuotaProviders,
    [switch]$CheckPolicy,
    [string]$ResourceGroup,
    [switch]$FailOnWarning,
    [string]$ConfigPath,
    [string]$OutputJson,
    [string[]]$SkuRequests,
    [string[]]$QuotaDemand,
    [string[]]$ZoneRequests,
    [string]$RbacGroup,
    [string[]]$RbacActions,
    [string[]]$NameRequests
)
$checkerBound = @{} + $PSBoundParameters

function Invoke-AzJson {
    param([string[]]$Arguments, [string]$CliPath)
    # Windows Azure CLI may resolve to a batch launcher. cmd.exe parses
    # unquoted parentheses again; preserve literal quotes for that launcher.
    if (-not $CliPath) { $CliPath = (Get-Command az -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path }
    $cliArguments = @($Arguments)
    if ($CliPath -match '\.(cmd|bat)$') {
        # PowerShell 7 uses legacy native argument passing for batch files.
        # Set it locally even if the caller has chosen Standard mode.
        $PSNativeCommandArgumentPassing = 'Legacy'
        for ($i = 0; $i -lt $cliArguments.Count; $i++) {
            if ($cliArguments[$i] -eq 'atScope()') {
                $cliArguments[$i] = '"atScope()"'
            } elseif ($cliArguments[$i] -match '^https?://[^"\r\n]+$' -and $cliArguments[$i].Contains('&')) {
                $cliArguments[$i] = '"' + $cliArguments[$i] + '"'
            }
        }
    }
    $stderrPath = [IO.Path]::GetTempFileName()
    try {
        # Keep native stderr separate from JSON; Windows PowerShell can surface stderr as error records.
        $ErrorActionPreference = 'Continue'
        $PSNativeCommandUseErrorActionPreference = $false
        $raw = & $CliPath @cliArguments --only-show-errors --output json 2> $stderrPath
        $nativeExit = $LASTEXITCODE
        if ($nativeExit -ne 0) {
            $diagnostic = (Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue)
            if ($diagnostic) { $diagnostic = ($diagnostic -replace '\s+',' ').Trim() }
            throw "Azure CLI command failed (exit $nativeExit): az $($Arguments -join ' '). $diagnostic"
        }
    } finally { Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue }
    if (-not $raw) { throw 'Azure CLI returned no data.' }
    ($raw -join "`n") | ConvertFrom-Json -ErrorAction Stop
}

function Resolve-SubscriptionSelection {
    param([object[]]$Subscriptions,[string]$Requested)
    $matches = @($Subscriptions | Where-Object Id -eq $Requested)
    if (-not $matches.Count) { $matches = @($Subscriptions | Where-Object AccountName -eq $Requested) }
    if (-not $matches.Count) { throw "Subscription not found among enabled subscriptions: $Requested" }
    if ($matches.Count -gt 1) { throw 'Multiple subscriptions match this name; use its ID.' }
    return $matches[0]
}

function Test-AppServiceSku {
    param([string]$Sku)
    # Azure CLI list-locations accepted values observed in v3.8 live testing.
    return ($Sku -match '^(F1|FREE|D1|SHARED|B[1-3]|S[1-3]|P[1-3]V2|P[0-3]V[34]|P[1-5]MV[34]|I[1-6]V2|I[1-5]MV2|WS[1-3])$')
}

function Get-ProviderCheckStatus {
    param([string]$Namespace,[string]$SubId)
    try {
        $provider = Invoke-AzJson @('provider','show','--namespace',$Namespace,'--subscription',$SubId)
        $state = [string]$provider.registrationState
        $status = switch ($state) {
            'Registered' { 'REGISTERED' }
            'NotRegistered' { 'NOT_REGISTERED' }
            'Registering' { 'REGISTERING' }
            'Unregistering' { 'REGISTRATION_UNKNOWN' }
            default { 'REGISTRATION_UNKNOWN' }
        }
        [pscustomobject]@{Status=$status;Detail="$Namespace registration: $state. No automatic registration performed."}
    } catch {
        [pscustomobject]@{Status='REGISTRATION_UNKNOWN';Detail="$Namespace registration query failed: $($_.Exception.Message)"}
    }
}

function Get-SqlSkuStatus {
    param($Sku,[string]$Name,$Edition)
    if (-not $Name -or $Name -eq '(unparsed)') { return 'UNKNOWN' }
    # A visible catalog entry is not necessarily provisionable. Explicit
    # negative capability metadata at either level takes precedence.
    foreach ($entry in @($Sku,$Edition)) {
        if ($null -eq $entry) { continue }
        if (($entry.available -is [bool] -and -not $entry.available) -or $entry.status -in @('Visible','Disabled','Unavailable','NotAvailable')) { return 'UNAVAILABLE' }
    }
    if ($null -ne $Edition -and $Edition.status -and $Edition.status -notin @('Available','Default')) { return 'UNKNOWN' }
    if ($Sku.status -and $Sku.status -notin @('Available','Default')) { return 'UNKNOWN' }
    if (($Sku.available -is [bool] -and $Sku.available) -or $Sku.status -in @('Available','Default')) { return 'LISTED' }
    return 'UNKNOWN'
}

function Get-SqlSkuRows {
    param([object[]]$Data,$Region,[string]$SubId)
    foreach ($edition in $Data) {
        if ($null -eq $edition) { continue }
        if ($edition.PSObject.Properties['supportedServiceLevelObjectives']) {
            $objectives = @($edition.supportedServiceLevelObjectives | Where-Object { $_ })
            if (-not $objectives.Count) {
                New-SkuRow $Region 'SQL Database' '(unparsed)' $edition.name 'UNKNOWN' (ConvertTo-Json -InputObject $edition -Depth 30 -Compress) $SubId
                continue
            }
            foreach ($objective in $objectives) {
                # The service objective name includes capacity (e.g. GP_Gen5_2).
                $name = if ($objective.name) { $objective.name } elseif ($objective.serviceObjectiveName) { $objective.serviceObjectiveName } else { '(unparsed)' }
                $tier = if ($objective.sku.tier) { $objective.sku.tier } else { $edition.name }
                $status = Get-SqlSkuStatus $objective $name $edition
                $detail = ConvertTo-Json -InputObject ([pscustomobject]@{Edition=$edition.name;EditionStatus=$edition.status;EditionReason=$edition.reason;Objective=$objective}) -Depth 30 -Compress
                New-SkuRow $Region 'SQL Database' $name $tier $status $detail $SubId
            }
        } else {
            # Retain compatibility with flat CLI response shapes.
            $name = if ($edition.serviceObjective) { $edition.serviceObjective } elseif ($edition.serviceObjectiveName) { $edition.serviceObjectiveName } elseif ($edition.sku.name) { $edition.sku.name } elseif ($edition.name) { $edition.name } else { '(unparsed)' }
            $tier = if ($edition.edition) { $edition.edition } else { $edition.sku.tier }
            New-SkuRow $Region 'SQL Database' $name $tier (Get-SqlSkuStatus $edition $name) (ConvertTo-Json -InputObject $edition -Depth 30 -Compress) $SubId
        }
    }
}

function Test-InformationalQuota {
    param([string]$Provider,[string]$Label,[string]$Metric)
    # Remaining entitlement counters are not consumed resource capacity.
    return ($Provider -eq 'SQL' -and ($Label -match '(Days|Months|Tokens)Left$' -or $Metric -match '(Days|Months|Tokens)Left$'))
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

function Assert-Subscription {
    param([string]$SubId)
    if ((Invoke-AzJson @('account','show')).id -ne $SubId) {
        throw 'Active Azure CLI subscription has changed. Restart the checker.'
    }
}

function Select-AzureRegions {
    param([string]$SubId)
    Assert-Subscription $SubId
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
    Select-Menu -Title 'Azure regions' -Items $possibleRegions -Label 'Label' -Multiple
}

function New-SkuRow {
    param($Region, [string]$Service, [string]$Sku, [string]$Tier, [string]$Status, [string]$Detail, [string]$SubId)
    [pscustomobject]@{ Region=$Region.DisplayName; RegionCode=$Region.Name; Service=$Service; SKU=$Sku; Tier=$Tier; Status=$Status; Detail=$Detail; SubscriptionId=$SubId }
}

function Get-SkuRestrictionStatus {
    param($Sku, $Region)
    $aliases = @(@($Region.Name, $Region.DisplayName, $Region.RegionalDisplayName) | Where-Object { $_ } | ForEach-Object { Normalize-Location $_ })
    $locations = @($Sku.locations | Where-Object { $_ } | ForEach-Object { Normalize-Location $_ })
    if (-not $locations.Count) { return 'UNKNOWN' }
    if (-not @($locations | Where-Object { $_ -in $aliases }).Count) { return 'NOT_LISTED' }
    $status = 'LISTED'
    foreach ($restriction in @($Sku.restrictions | Where-Object { $_ })) {
        $scopes = @(@($restriction.values) + @($restriction.restrictionInfo.locations) | Where-Object { $_ } | ForEach-Object { Normalize-Location $_ })
        if ($restriction.type -eq 'Location') {
            if (-not $scopes.Count) { $status = 'RESTRICTION_UNKNOWN' }
            elseif (@($scopes | Where-Object { $_ -in $aliases }).Count) { return 'RESTRICTED' }
        } elseif ($restriction.type -eq 'Zone') {
            $zoneLocations = @($restriction.restrictionInfo.locations | Where-Object { $_ } | ForEach-Object { Normalize-Location $_ })
            if ((-not $zoneLocations.Count -or @($zoneLocations | Where-Object { $_ -in $aliases }).Count) -and $status -eq 'LISTED') { $status = 'ZONE_RESTRICTED' }
        } elseif ($status -eq 'LISTED') { $status = 'RESTRICTION_UNKNOWN' }
    }
    return $status
}

function Show-CheckTable {
    param([object[]]$Rows, [string[]]$Columns)
    $width = 140
    try { $width = [Math]::Min(180,[Math]::Max(80, $Host.UI.RawUI.WindowSize.Width)) } catch { }
    $table = $Rows | Format-Table -Property $Columns -AutoSize -Wrap | Out-String -Stream -Width $width
    foreach ($line in $table) {
        $color = switch -Regex ($line) {
            '^\s*(LISTED|HEADROOM|FITS|AVAILABLE)\s' { 'Green'; break }
            '^\s*(RESTRICTED|EXHAUSTED|ERROR|NOT_LISTED|POTENTIAL_DENY|UNAVAILABLE|INSUFFICIENT|NOT_REGISTERED)\s' { 'Red'; break }
            '^\s*(ZONE_RESTRICTED|RESTRICTION_UNKNOWN|UNKNOWN|NEAR_LIMIT|NO_DATA|REGISTERING|REGISTRATION_UNKNOWN|INFORMATIONAL|REVIEW|AUDIT|NO_ASSIGNMENTS|GRANT_LISTED|GRANT_NOT_LISTED|NOT_FOUND)\s' { 'Yellow'; break }
            default { 'Gray' }
        }
        Write-Host $line -ForegroundColor $color
    }
}

function Invoke-SkuCheck {
    param([string]$SubId, [object[]]$SelectedRegions, [string]$RequestedService, [string]$RequestedSku, [switch]$LinuxWorkers)
    $regions = if ($SelectedRegions.Count) { @($SelectedRegions) } else { @(Select-AzureRegions $SubId) }
    $menu = @('Virtual Machine','Managed Disk','Storage Account','App Service Plan','SQL Database','PostgreSQL Flexible Server','MySQL Flexible Server','API Management','Azure OpenAI','Azure AI Services' | ForEach-Object { [pscustomobject]@{Name=$_} })
    $services = if ($RequestedService) { @($menu | Where-Object Name -eq $RequestedService) } else { @(Select-Menu -Title 'SKU services' -Items $menu -Multiple) }
    if (-not $services) { throw 'Unknown SKU service.' }
    $appSku = $null; $appLinux = $false
    if ($RequestedService) {
        $appSku = $RequestedSku
        if ($RequestedService -eq 'App Service Plan' -and -not (Test-AppServiceSku $appSku)) { throw 'Invalid App Service SKU.' }
        $appLinux = $LinuxWorkers.IsPresent
    } elseif ('App Service Plan' -in $services.Name) {
        do {
            $appSku = (Read-Host 'App Service SKU (e.g. B1, P1V3; Enter to skip)').Trim().ToUpperInvariant()
            if ($appSku -and -not (Test-AppServiceSku $appSku)) { Write-Host 'Invalid App Service SKU. Enter a supported SKU or press Enter to skip.' -ForegroundColor Yellow }
        } until (-not $appSku -or (Test-AppServiceSku $appSku))
        if (-not $appSku) { $services = @($services | Where-Object Name -ne 'App Service Plan') }
        else { $appLinux = ((Read-Host 'Linux workers? [y/N]').Trim() -eq 'Y') }
        if (-not $services.Count) { Write-Host 'No SKU services selected.'; return }
    }
    $filter = if ($RequestedService) { $RequestedSku } else { (Read-Host 'Filter SKU names (optional, Enter for all)').Trim() }
    $storageCache = $null
    $providerMap = @{'Virtual Machine'='Microsoft.Compute';'Managed Disk'='Microsoft.Compute';'Storage Account'='Microsoft.Storage';'App Service Plan'='Microsoft.Web';'SQL Database'='Microsoft.Sql';'PostgreSQL Flexible Server'='Microsoft.DBforPostgreSQL';'MySQL Flexible Server'='Microsoft.DBforMySQL';'API Management'='Microsoft.ApiManagement';'Azure OpenAI'='Microsoft.CognitiveServices';'Azure AI Services'='Microsoft.CognitiveServices'}
    $providerCache = @{}
    $results = @(foreach ($region in $regions) {
        foreach ($service in $services.Name) {
            Write-Host "Checking $service SKU metadata in $($region.DisplayName)..." -ForegroundColor Cyan
            try {
                Assert-Subscription $SubId
                $namespace = $providerMap[$service]
                if (-not $providerCache.ContainsKey($namespace)) { $providerCache[$namespace] = Get-ProviderCheckStatus $namespace $SubId }
                $registration = $providerCache[$namespace]
                # Skip the deployment-oriented SKU query if registration is not confirmed; do not label the SKU unavailable.
                if ($registration.Status -ne 'REGISTERED') {
                    New-SkuRow $region $service $filter '' $registration.Status $registration.Detail $SubId
                    continue
                }
                $rows = @(switch ($service) {
                    { $_ -in @('Virtual Machine','Managed Disk') } {
                        $resourceType = if ($service -eq 'Virtual Machine') { 'virtualMachines' } else { 'disks' }
                        $data = @(Invoke-AzJson @('vm','list-skus','--location',$region.Name,'--resource-type',$resourceType,'--all','--subscription',$SubId))
                        foreach ($sku in $data) {
                            if (-not $sku.name) { continue }
                            $status = Get-SkuRestrictionStatus $sku $region
                            $detail = if ($sku.restrictions) { ConvertTo-Json -InputObject @($sku.restrictions) -Depth 12 -Compress } else { 'No restrictions returned; capacity not verified.' }
                            New-SkuRow $region $service $sku.name $sku.tier $status $detail $SubId
                        }
                    }
                    { $_ -in @('API Management','Azure OpenAI','Azure AI Services') } {
                        Get-ExtendedSkuRows -Region $region -Service $service -SubId $SubId
                    }
                    'Storage Account' {
                        if ($null -eq $storageCache) {
                            # A relative ARM URL allows Azure CLI to select the current cloud endpoint.
                            $url = "/subscriptions/$SubId/providers/Microsoft.Storage/skus?api-version=2025-06-01"
                            $all = @()
                            do {
                                $page = Invoke-AzJson @('rest','--method','get','--url',$url,'--subscription',$SubId)
                                if ($null -eq $page.PSObject.Properties['value']) { throw 'Unexpected Storage SKU response.' }
                                $all += @($page.value | Where-Object { $_ })
                                $url = $page.nextLink
                            } while ($url)
                            $storageCache = @($all)
                        }
                        foreach ($sku in $storageCache) {
                            if (-not $sku.name -or ($sku.resourceType -and $sku.resourceType -ne 'storageAccounts')) { continue }
                            $status = Get-SkuRestrictionStatus $sku $region
                            $detail = "Kind: $($sku.kind); Restrictions: $(ConvertTo-Json -InputObject @($sku.restrictions) -Depth 12 -Compress)"
                            New-SkuRow $region $service $sku.name "$($sku.tier) / $($sku.kind)" $status $detail $SubId
                        }
                    }
                    'App Service Plan' {
                        $cliArgs = @('appservice','list-locations','--sku',$appSku,'--subscription',$SubId)
                        if ($appLinux) { $cliArgs += '--linux-workers-enabled' }
                        $data = @(Invoke-AzJson $cliArgs)
                        $names = @($data | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.name; $_.displayName } } | Where-Object { $_ } | ForEach-Object { Normalize-Location $_ })
                        $aliases = @(@($region.Name,$region.DisplayName,$region.RegionalDisplayName) | Where-Object { $_ } | ForEach-Object { Normalize-Location $_ })
                        $status = if (@($aliases | Where-Object { $_ -in $names }).Count) { 'LISTED' } elseif (-not $names.Count) { 'UNKNOWN' } else { 'NOT_LISTED' }
                        $tier = if ($appLinux) { 'Linux workers' } else { 'Default (no Linux filter)' }
                        New-SkuRow $region $service $appSku $tier $status 'App Service location list for requested SKU; not a capacity check.' $SubId
                    }
                    'SQL Database' {
                        $data = @(Invoke-AzJson @('sql','db','list-editions','--location',$region.Name,'--subscription',$SubId))
                        Get-SqlSkuRows -Data $data -Region $region -SubId $SubId
                    }
                    { $_ -in @('PostgreSQL Flexible Server','MySQL Flexible Server') } {
                        $engine = if ($service -eq 'PostgreSQL Flexible Server') { 'postgres' } else { 'mysql' }
                        $data = @(Invoke-AzJson @($engine,'flexible-server','list-skus','--location',$region.Name,'--subscription',$SubId))
                        foreach ($entry in $data) {
                            $editions = @($entry.supportedFlexibleServerEditions | Where-Object { $_ })
                            if (-not $editions.Count) { $editions = @($entry.supportedServerEditions | Where-Object { $_ }) }
                            if (-not $editions.Count -and $entry.supportedServerSkus) { $editions = @($entry) }
                            if (-not $editions.Count -and $entry.supportedSkus) { $editions = @($entry) }
                            $found = $false
                            foreach ($edition in $editions) {
                                $editionSkus = @($edition.supportedServerSkus | Where-Object { $_ })
                                if (-not $editionSkus.Count) { $editionSkus = @($edition.supportedSkus | Where-Object { $_ }) }
                                foreach ($sku in $editionSkus) {
                                    $name = if ($sku.name) { $sku.name } elseif ($sku.skuName) { $sku.skuName } else { $null }
                                    if (-not $name) { continue }
                                    $found = $true
                                    $status = if ($sku.status -in @('Disabled','Unavailable','NotAvailable')) { 'RESTRICTED' } else { 'LISTED' }
                                    New-SkuRow $region $service $name $edition.name $status (ConvertTo-Json -InputObject $sku -Depth 20 -Compress) $SubId
                                }
                            }
                            if (-not $found -and ($entry.skuName -or ($entry.name -and ($entry.vCores -or $entry.tier)))) {
                                $name = if ($entry.skuName) { $entry.skuName } else { $entry.name }
                                $status = if ($entry.status -in @('Disabled','Unavailable','NotAvailable')) { 'RESTRICTED' } else { 'LISTED' }
                                New-SkuRow $region $service $name $entry.tier $status (ConvertTo-Json -InputObject $entry -Depth 20 -Compress) $SubId
                                $found = $true
                            }
                            if (-not $found) {
                                New-SkuRow $region $service '(unparsed)' '' 'UNKNOWN' (ConvertTo-Json -InputObject $entry -Depth 50 -Compress) $SubId
                            }
                        }
                    }
                })
                if (-not $rows.Count) { New-SkuRow $region $service '' '' 'NO_DATA' 'No SKU records returned.' $SubId }
                else {
                    $matched = @($rows | Where-Object { -not $filter -or ($RequestedService -and $_.SKU -eq $filter) -or (-not $RequestedService -and $_.SKU.IndexOf($filter,[StringComparison]::OrdinalIgnoreCase) -ge 0) -or $_.Status -eq 'UNKNOWN' })
                    if ($matched.Count) { $matched }
                    else { New-SkuRow $region $service $filter '' 'NO_DATA' 'No matching SKU in returned records; not a definitive deployment denial.' $SubId }
                }
            } catch { New-SkuRow $region $service '' '' 'ERROR' $_.Exception.Message $SubId }
        }
    })
    foreach ($region in $regions) {
        Write-Host "`n=== SKU report: $($region.DisplayName) ===" -ForegroundColor Cyan
        Show-CheckTable -Rows @($results | Where-Object RegionCode -eq $region.Name | Sort-Object Service,SKU,Tier) -Columns @('Status','Service','SKU','Tier')
    }
    Show-ReportDiagnostics $results
    Write-Host 'LISTED is catalog evidence only. Restrictions, quotas, policy and capacity can prevent deployment. UNKNOWN means unparsed or missing metadata; export CSV for raw details.' -ForegroundColor Yellow
    return $results
}

function Show-ReportDiagnostics {
    param([object[]]$Rows)
    foreach ($r in @($Rows | Where-Object { $_.Status -in @('ERROR','NOT_REGISTERED','REGISTERING','REGISTRATION_UNKNOWN','NO_DATA') })) {
        Write-Host "$($r.Status) [$($r.Region) / $($r.Service)]: $($r.Detail)" -ForegroundColor Yellow
    }
}

function New-QuotaDiagnosticRow {
    param($Region,[string]$Service,[string]$Status,[string]$Detail,[string]$SubId)
    [pscustomobject]@{Region=$Region.DisplayName;RegionCode=$Region.Name;Service=$Service;Quota='';Used=$null;Limit=$null;Remaining=$null;Percent=$null;Unit='';Status=$Status;Detail=$Detail;SubscriptionId=$SubId}
}

function Invoke-QuotaCheck {
    param([string]$SubId, [object[]]$SelectedRegions, [string[]]$RequestedProviders)
    $regions = if ($SelectedRegions.Count) { @($SelectedRegions) } else { @(Select-AzureRegions $SubId) }
    $menu = @(
        [pscustomobject]@{Name='Compute (vCPU, VM families)'; Command=@('vm','list-usage')}
        [pscustomobject]@{Name='Network (public IPs, VNets, etc.)'; Command=@('network','list-usages')}
        [pscustomobject]@{Name='Storage (account counts)'; Command=@('storage','account','show-usage')}
        [pscustomobject]@{Name='SQL (regional subscription usage)'; Command=@('sql','list-usages')}
        [pscustomobject]@{Name='CognitiveServices (regional usage)'; Command=@('cognitiveservices','usage','list')}
        [pscustomobject]@{Name='ContainerApps (regional usage; CLI extension may be required)'; Command=@('containerapp','list-usages')}
    )
    $services = if ($RequestedProviders.Count) { @($menu | Where-Object { ($_.Name -split ' ',2)[0] -in $RequestedProviders }) } else { @(Select-Menu -Title 'Quota providers' -Items $menu -Multiple) }
    if (-not $services) { throw 'No quota providers selected.' }
    $providerMap = @{Compute='Microsoft.Compute';Network='Microsoft.Network';Storage='Microsoft.Storage';SQL='Microsoft.Sql';CognitiveServices='Microsoft.CognitiveServices';ContainerApps='Microsoft.App'}
    $providerCache = @{}
    $results = @(foreach ($region in $regions) {
        foreach ($service in $services) {
            Write-Host "Checking $($service.Name) in $($region.DisplayName)..." -ForegroundColor Cyan
            try {
                Assert-Subscription $SubId
                $providerKey = ($service.Name -split ' ',2)[0]
                $namespace = $providerMap[$providerKey]
                if (-not $providerCache.ContainsKey($namespace)) { $providerCache[$namespace] = Get-ProviderCheckStatus $namespace $SubId }
                $registration = $providerCache[$namespace]
                if ($registration.Status -ne 'REGISTERED') {
                    New-QuotaDiagnosticRow $region $service.Name $registration.Status $registration.Detail $SubId
                    continue
                }
                $data = @(Invoke-AzJson ($service.Command + @('--location',$region.Name,'--subscription',$SubId)))
                $data = @(foreach ($entry in $data) { if ($entry.PSObject.Properties['value'] -and $entry.value -is [array]) { $entry.value } else { $entry } })
                if (-not $data.Count) {
                    [pscustomobject]@{Region=$region.DisplayName; RegionCode=$region.Name; Service=$service.Name; Quota=''; Used=$null; Limit=$null; Remaining=$null; Percent=$null; Unit=''; Status='NO_DATA'; Detail='No quota rows returned.'; SubscriptionId=$SubId}
                }
                foreach ($rawItem in $data) {
                    $item = if ($rawItem.properties -and $null -ne $rawItem.properties.limit) { $rawItem.properties } else { $rawItem }
                    $name = if ($item.name.localizedValue) { $item.name.localizedValue } elseif ($item.name.value) { $item.name.value } elseif ($item.name -is [string]) { $item.name } else { '(unknown)' }
                    $used = $null; $limit = $null; $remaining = $null; $pct = $null; $status = 'UNKNOWN'
                    $u = 0.0; $l = 0.0
                    $rawUsed = if ($null -ne $item.currentValue) { $item.currentValue } else { $item.currentUsage }
                    if ($null -ne $rawUsed -and $null -ne $item.limit -and [double]::TryParse([string]$rawUsed,[ref]$u) -and [double]::TryParse([string]$item.limit,[ref]$l) -and $u -ge 0 -and $l -ge 0) {
                        $used=$u; $limit=$l; $remaining=[Math]::Max(0,$l-$u)
                        if ($l -gt 0) { $pct=[Math]::Round(100*$u/$l,1) }
                        $status = if ($u -ge $l) { 'EXHAUSTED' } elseif ($pct -ge 80) { 'NEAR_LIMIT' } else { 'HEADROOM' }
                    }
                    if (Test-InformationalQuota $providerKey $name ([string]$item.name.value)) { $status='INFORMATIONAL'; $remaining=$null; $pct=$null }
                    [pscustomobject]@{Region=$region.DisplayName; RegionCode=$region.Name; Service=$service.Name; Quota=$name; Used=$used; Limit=$limit; Remaining=$remaining; Percent=$pct; Unit=$item.unit; Status=$status; Detail=(ConvertTo-Json -InputObject $item -Depth 12 -Compress); SubscriptionId=$SubId}
                }
            } catch {
                [pscustomobject]@{Region=$region.DisplayName; RegionCode=$region.Name; Service=$service.Name; Quota=''; Used=$null; Limit=$null; Remaining=$null; Percent=$null; Unit=''; Status='ERROR'; Detail=$_.Exception.Message; SubscriptionId=$SubId}
            }
        }
    })
    foreach ($region in $regions) {
        Write-Host "`n=== Quota report: $($region.DisplayName) ===" -ForegroundColor Cyan
        $displayRows = @($results | Where-Object RegionCode -eq $region.Name | Sort-Object Service,Quota | Select-Object Status,@{Name='Service';Expression={($_.Service -split ' ',2)[0]}},Quota,Used,Limit,Remaining,Percent,@{Name='Unit';Expression={if ([string]$_.Unit -eq $_.Quota -or ([string]$_.Unit).Length -gt 20) {'(raw)'} else {$_.Unit}}})
        Show-CheckTable -Rows $displayRows -Columns @('Status','Service','Quota','Used','Limit','Remaining','Percent','Unit')
    }
    Show-ReportDiagnostics $results
    Write-Host 'INFORMATIONAL: Used is the raw reported counter, not consumed capacity. (raw) units are preserved in CSV/JSON.' -ForegroundColor Yellow
    Write-Host 'NEAR_LIMIT starts at 80%. HEADROOM does not mean a proposed deployment fits. Compute total and family quotas must both be checked.' -ForegroundColor Yellow
    return $results
}

# Policy screening uses three-valued logic. It never executes policy expressions.
function Get-PolicyProperties {
    param($Object)
    if ($Object.properties) { return $Object.properties }
    return $Object
}

function Get-PolicyValue {
    param($Value, [hashtable]$Parameters)
    if ($Value -is [string] -and $Value -match '^\[parameters\(''([^'']+)''\)\]$') {
        if ($Parameters.ContainsKey($Matches[1])) { return [pscustomobject]@{Known=$true; Value=$Parameters[$Matches[1]]} }
        return [pscustomobject]@{Known=$false; Value=$null}
    }
    if ($Value -is [string] -and $Value.StartsWith('[')) { return [pscustomobject]@{Known=$false; Value=$null} }
    if ($null -eq $Value) { return [pscustomobject]@{Known=$false; Value=$null} }
    return [pscustomobject]@{Known=$true; Value=$Value}
}

function Get-PolicyParameters {
    param($Definitions, $Supplied, [hashtable]$Parent = @{})
    $result = @{}
    foreach ($prop in $Definitions.PSObject.Properties) {
        if ($prop.Value.PSObject.Properties['defaultValue']) { $result[$prop.Name] = $prop.Value.defaultValue }
    }
    foreach ($prop in $Supplied.PSObject.Properties) {
        $resolved = Get-PolicyValue -Value $prop.Value.value -Parameters $Parent
        if ($resolved.Known) { $result[$prop.Name] = $resolved.Value }
        else { [void]$result.Remove($prop.Name) }
    }
    return $result
}

function Test-PolicyCondition {
    param($Condition, [hashtable]$Parameters, [string]$Location, [string]$ResourceType)
    if (-not $Condition) { return 'Unknown' }
    if ($Condition.PSObject.Properties['allOf']) {
        if (@($Condition.PSObject.Properties).Count -ne 1) { return 'Unknown' }
        $children = @($Condition.allOf | ForEach-Object { Test-PolicyCondition $_ $Parameters $Location $ResourceType })
        if (-not $children.Count) { return 'Unknown' }
        if ('False' -in $children) { return 'False' }
        if ('Unknown' -in $children) { return 'Unknown' }
        return 'True'
    }
    if ($Condition.PSObject.Properties['anyOf']) {
        if (@($Condition.PSObject.Properties).Count -ne 1) { return 'Unknown' }
        $children = @($Condition.anyOf | ForEach-Object { Test-PolicyCondition $_ $Parameters $Location $ResourceType })
        if (-not $children.Count) { return 'Unknown' }
        if ('True' -in $children) { return 'True' }
        if ('Unknown' -in $children) { return 'Unknown' }
        return 'False'
    }
    if ($Condition.PSObject.Properties['not']) {
        if (@($Condition.PSObject.Properties).Count -ne 1) { return 'Unknown' }
        $child = Test-PolicyCondition $Condition.not $Parameters $Location $ResourceType
        if ($child -eq 'True') { return 'False' }
        if ($child -eq 'False') { return 'True' }
        return 'Unknown'
    }
    if ($Condition.field -eq 'location') { $actual = $Location }
    elseif ($Condition.field -eq 'type' -and $ResourceType) { $actual = $ResourceType }
    else { return 'Unknown' }
    $operators = @('equals','notEquals','in','notIn' | Where-Object { $Condition.PSObject.Properties[$_] })
    if ($operators.Count -ne 1 -or @($Condition.PSObject.Properties).Count -ne 2) { return 'Unknown' }
    $op = $operators[0]
    $resolved = Get-PolicyValue -Value $Condition.$op -Parameters $Parameters
    if (-not $resolved.Known) { return 'Unknown' }
    $values = @($resolved.Value)
    if (@($values | Where-Object { $_ -isnot [string] -or $_.StartsWith('[') }).Count) { return 'Unknown' }
    if ($op -in @('equals','notEquals') -and ($resolved.Value -isnot [string])) { return 'Unknown' }
    if ($op -in @('in','notIn') -and $resolved.Value -isnot [System.Array]) { return 'Unknown' }
    if ($Condition.field -eq 'location') {
        $actual = Normalize-Location $actual
        $values = @($values | ForEach-Object { Normalize-Location $_ })
    }
    $match = $actual -in $values
    if ($op -in @('notEquals','notIn')) { $match = -not $match }
    if ($match) { return 'True' }
    return 'False'
}

function Get-PolicyDefinitionCached {
    param([string]$Id, [hashtable]$Cache)
    if ($Cache.ContainsKey($Id)) { return $Cache[$Id] }
    # ARM resource IDs are accepted by az rest; only allow definition paths.
    if ($Id -notmatch '^/(?:subscriptions/[^/]+/|providers/Microsoft\.Management/managementGroups/[^/]+/)?providers/Microsoft\.Authorization/policy(?:Set)?Definitions/[^/?#]+(?:/versions/[^/?#]+)?$') {
        throw 'Unexpected policy definition ID.'
    }
    $data = Invoke-AzJson @('rest','--method','get','--url',"${Id}?api-version=2025-11-01")
    if (-not $data) { throw 'Empty policy definition response.' }
    $Cache[$Id] = Get-PolicyProperties $data
    return $Cache[$Id]
}

function New-PolicyRow {
    param($Region,[string]$TargetType,[string]$TargetScope,[string]$Assignment,[string]$AssignmentId,[string]$AssignmentScope,[string]$Definition,[string]$DefinitionId,[string]$Reference,[string]$Effect,[string]$Enforcement,[string]$Condition,[string]$Status,[string]$Detail,[string]$SubId)
    [pscustomobject]@{Region=$Region.DisplayName; RegionCode=$Region.Name; ResourceType=$TargetType; TargetScope=$TargetScope; Assignment=$Assignment; AssignmentId=$AssignmentId; AssignmentScope=$AssignmentScope; Definition=$Definition; DefinitionId=$DefinitionId; ReferenceId=$Reference; Effect=$Effect; Enforcement=$Enforcement; Condition=$Condition; Status=$Status; Detail=$Detail; SubscriptionId=$SubId}
}

function Invoke-PolicyCheck {
    param([string]$SubId, [object[]]$SelectedRegions, [string]$RequestedGroup, [string]$RequestedType)
    $regions = if ($SelectedRegions.Count) { @($SelectedRegions) } else { @(Select-AzureRegions $SubId) }
    $targetScope = "/subscriptions/$SubId"
    $group = if ($SelectedRegions.Count) { $RequestedGroup } else { (Read-Host 'Existing resource group name (Enter for subscription scope only)').Trim() }
    if ($group) {
        Assert-Subscription $SubId
        $rg = Invoke-AzJson @('group','show','--name',$group,'--subscription',$SubId)
        if (-not $rg.id) { throw 'Resource group could not be identified.' }
        $targetScope = $rg.id
    }
    $targetType = if ($SelectedRegions.Count) { $RequestedType } else { (Read-Host 'Resource type (e.g. Microsoft.Storage/storageAccounts; Enter for location only)').Trim() }
    if ($targetType -and $targetType -notmatch '^[A-Za-z0-9.]+/[A-Za-z0-9._/-]+$') { throw 'Use a full ARM resource type, e.g. Microsoft.Storage/storageAccounts.' }
    Assert-Subscription $SubId
    Write-Host 'Reading applicable policy assignments and definitions...' -ForegroundColor Cyan
    $assignments = @(Invoke-AzJson @('policy','assignment','list','--scope',$targetScope,'--filter','atScope()','--expand','EffectiveDefinitionVersion,LatestDefinitionVersion') | Where-Object { $_ })
    $exemptionsKnown = $true
    $exemptions = @()
    try { $exemptions = @(Invoke-AzJson @('policy','exemption','list','--scope',$targetScope,'--filter','atScope()') | Where-Object { $_ }) }
    catch { $exemptionsKnown = $false; Write-Warning 'Exemptions could not be read. Policy applicability requires additional review.' }
    $cache = @{}
    $entries = @(foreach ($assignment in $assignments) {
        $a = Get-PolicyProperties $assignment
        $assignmentId = [string]$assignment.id
        $assignmentName = if ($a.displayName) { $a.displayName } else { $assignment.name }
        $assignmentScope = [string]$a.scope
        if (-not $assignmentScope) { $assignmentScope = $assignmentId -replace '/providers/Microsoft.Authorization/policyAssignments/[^/]+$','' }
        $enforcement = if ($a.enforcementMode) { [string]$a.enforcementMode } else { 'Default (implicit)' }
        $notes = @()
        if ($a.notScopes) { $notes += 'Assignment has scope exclusions; resource-specific exclusions are not evaluated.' }
        if ($a.resourceSelectors) { $notes += 'Assignment has resource selectors; applicability requires review.' }
        if ($a.overrides) { $notes += 'Assignment has overrides; effect may differ from definition.' }
        if (-not $group) { $notes += 'Subscription scope only; resource group and resource-level rules/exemptions not included.' }
        if (-not $exemptionsKnown) { $notes += 'Exemption visibility unknown.' }
        elseif (@($exemptions | Where-Object { (Get-PolicyProperties $_).policyAssignmentId -eq $assignmentId }).Count) { $notes += 'One or more visible exemptions reference this assignment; expiration, scope and selectors not evaluated.' }
        $excluded = $false
        foreach ($notScope in @($a.notScopes | Where-Object { $_ })) {
            if ($targetScope -eq $notScope -or $targetScope.StartsWith("$($notScope.TrimEnd('/'))/",[StringComparison]::OrdinalIgnoreCase)) { $excluded = $true }
        }
        try {
            $id = [string]$a.policyDefinitionId
            if (-not $id) { throw 'Assignment has no policy definition ID.' }
            $versionNote = @($notes)
            $fetchId = $id
            $effectiveVersion = if ($a.effectiveDefinitionVersion -match '^\d+\.\d+\.\d+$') { $a.effectiveDefinitionVersion } elseif ($a.definitionVersion -match '^\d+\.\d+\.\d+$') { $a.definitionVersion } else { '' }
            if ($effectiveVersion -and $id -notmatch '/versions/') { $fetchId = "$id/versions/$effectiveVersion" }
            elseif ($id -notmatch '/versions/' -and ($a.definitionVersion -or $a.effectiveDefinitionVersion)) { $versionNote += 'Assigned/effective version may differ from fetched definition; version pinning is not resolved.' }
            $definition = Get-PolicyDefinitionCached $fetchId $cache
            $assignmentParams = Get-PolicyParameters $definition.parameters $a.parameters
            if ($id -match '/policySetDefinitions/') {
                $members = @($definition.policyDefinitions | Where-Object { $_ })
                if (-not $members.Count) { throw 'Initiative contains no readable policy definitions.' }
                foreach ($member in $members) {
                    $memberNotes = @($versionNote)
                    $childId = [string]$member.policyDefinitionId
                    if ($childId -notmatch '/versions/' -and $member.definitionVersion -match '^\d+\.\d+\.\d+$') { $childId = "$childId/versions/$($member.definitionVersion)" }
                    elseif ($childId -notmatch '/versions/' -and $member.definitionVersion) { $memberNotes += 'Initiative member version is not resolved.' }
                    try {
                        $child = Get-PolicyDefinitionCached $childId $cache
                        $childParams = Get-PolicyParameters $child.parameters $member.parameters $assignmentParams
                        [pscustomobject]@{Name=$assignmentName; Id=$assignmentId; Scope=$assignmentScope; Enforcement=$enforcement; Definition=$child; DefinitionId=$childId; Reference=$member.policyDefinitionReferenceId; Parameters=$childParams; Notes=$memberNotes; Excluded=$excluded; Error=''; Initiative=$definition.displayName}
                    } catch {
                        [pscustomobject]@{Name=$assignmentName; Id=$assignmentId; Scope=$assignmentScope; Enforcement=$enforcement; Definition=$null; DefinitionId=$childId; Reference=$member.policyDefinitionReferenceId; Parameters=@{}; Notes=$memberNotes; Excluded=$excluded; Error=$_.Exception.Message; Initiative=$definition.displayName}
                    }
                }
            } else {
                [pscustomobject]@{Name=$assignmentName; Id=$assignmentId; Scope=$assignmentScope; Enforcement=$enforcement; Definition=$definition; DefinitionId=$fetchId; Reference=''; Parameters=$assignmentParams; Notes=$versionNote; Excluded=$excluded; Error=''; Initiative=''}
            }
        } catch {
            [pscustomobject]@{Name=$assignmentName; Id=$assignmentId; Scope=$assignmentScope; Enforcement=$enforcement; Definition=$null; DefinitionId=$a.policyDefinitionId; Reference=''; Parameters=@{}; Notes=$notes; Excluded=$excluded; Error=$_.Exception.Message; Initiative=''}
        }
    })
    $results = @(foreach ($region in $regions) {
        if (-not $entries.Count) {
            New-PolicyRow $region $targetType $targetScope '' '' '' '' '' '' '' '' '' 'NO_ASSIGNMENTS' 'No applicable assignments returned at requested scope. This is not a deployment approval.' $SubId
        }
        foreach ($entry in $entries) {
            $name = if ($entry.Definition.displayName) { $entry.Definition.displayName } else { $entry.DefinitionId }
            $effect = 'Unknown'; $condition = 'Unknown'; $status = 'REVIEW'
            $detail = @($entry.Notes)
            if ($entry.Initiative) { $detail += "Initiative: $($entry.Initiative)" }
            if ($entry.Error) { $status='ERROR'; $detail += $entry.Error }
            else {
                $resolved = Get-PolicyValue -Value $entry.Definition.policyRule.then.effect -Parameters $entry.Parameters
                if ($resolved.Known -and $resolved.Value -is [string]) { $effect = $resolved.Value }
                $condition = Test-PolicyCondition $entry.Definition.policyRule.if $entry.Parameters $region.Name $targetType
                if ($entry.Definition.mode -notin @('All','Indexed')) { $detail += 'Provider-specific or unknown policy mode is not evaluated.'; $condition = 'Unknown' }
                if ($entry.Definition.mode -eq 'Indexed') { $detail += 'Indexed mode applicability depends on resource support for tags and location.' }
                if ($entry.Excluded) { $status = 'SCOPE_EXCLUDED' }
                elseif ($entry.Enforcement -eq 'DoNotEnforce') { $status = 'NOT_ENFORCED' }
                elseif ($effect -eq 'Disabled' -and -not @($entry.Notes | Where-Object { $_ -match 'override|version' }).Count) { $status = 'DISABLED' }
                elseif ($effect -eq 'Deny' -and $condition -eq 'True') { $status = 'POTENTIAL_DENY' }
                elseif ($effect -in @('Deny','DenyAction','Unknown') -or @($entry.Notes | Where-Object { $_ -match 'override|version' }).Count) {
                    if ($condition -eq 'False' -and -not @($entry.Notes | Where-Object { $_ -match 'version' }).Count) { $status='NO_MATCH' }
                    else { $status='REVIEW' }
                }
                elseif ($condition -eq 'False') { $status='NO_MATCH' }
                elseif ($effect -in @('Audit','AuditIfNotExists')) { $status='AUDIT' }
                else { $status='REVIEW' }
                $detail += 'Partial condition evaluation only (location/type); no deployment simulation.'
            }
            New-PolicyRow $region $targetType $targetScope $entry.Name $entry.Id $entry.Scope $name $entry.DefinitionId $entry.Reference $effect $entry.Enforcement $condition $status ($detail -join ' ') $SubId
        }
    })
    foreach ($region in $regions) {
        Write-Host "`n=== Policy report: $($region.DisplayName) ===" -ForegroundColor Cyan
        Show-CheckTable -Rows @($results | Where-Object RegionCode -eq $region.Name | Sort-Object Status,Assignment,Definition) -Columns @('Status','Assignment','Definition','Effect','Condition','Enforcement')
    }
    Write-Host "`n=== Policy summary ===" -ForegroundColor Cyan
    $results | Group-Object Region,Status | ForEach-Object { [pscustomobject]@{Region=$_.Group[0].Region; Status=$_.Group[0].Status; Count=$_.Count} } | Format-Table -AutoSize | Out-Host
    Write-Host 'POTENTIAL_DENY is a warning, not a definitive block. NO_MATCH is limited to the supplied fields and fetched definition. Review exemptions, overrides, versions and scope before deploying.' -ForegroundColor Yellow
    Write-Host 'Use optional CSV export for assignment IDs, scope and per-row caveats. No assignments are created, changed or removed.' -ForegroundColor Yellow
    return $results
}

function Invoke-AvailabilityCheck {
    param([string]$SubId, [object[]]$Catalog, [object[]]$SelectedRegions, [object[]]$SelectedResources)

    $chosenRegions = if ($SelectedRegions.Count) { @($SelectedRegions) } else { @(Select-AzureRegions $SubId) }
    if ($SelectedResources.Count) { $mode = 'EXPLICIT' } else {

    Write-Host "`n=== Report scope ===" -ForegroundColor Cyan
    Write-Host '[Enter] All Azure resource types (default)'
    Write-Host '[C] Common services (33 built-in resource types)'
    Write-Host '[S] Select common services manually'
    Write-Host '[P] Select resource providers and types manually'
    Write-Host '[F] Search services by name, provider or resource type'
    Write-Host '[Q] Quit'
    do {
        $mode = (Read-Host 'Report scope [Enter for all]').Trim().ToUpperInvariant()
        if ($mode -eq 'Q') { throw [System.OperationCanceledException]::new('Cancelled by user.') }
        if ($mode -notin @('', 'C', 'S', 'P', 'F')) { Write-Host 'Invalid selection.' -ForegroundColor Yellow }
    } until ($mode -in @('', 'C', 'S', 'P', 'F'))
    }

    $cache = @{}
    $typeIndex = @{}
    $friendlyNames = @{}
    foreach ($item in $Catalog) { $friendlyNames["$($item.Provider)/$($item.Type)"] = $item.Name }

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

    if ($mode -eq 'EXPLICIT') {
        $chosenResources = @($SelectedResources)
    } elseif ($mode -eq 'C') {
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
    if ($mode -eq 'F') {
        do { $term = (Read-Host 'Search (e.g. Key Vault, Microsoft.Sql, storageAccounts)').Trim() } until ($term)
        $chosenResources = @($chosenResources | Where-Object {
            $_.Name.IndexOf($term,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $_.Provider.IndexOf($term,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $_.Type.IndexOf($term,[StringComparison]::OrdinalIgnoreCase) -ge 0
        })
        if (-not $chosenResources.Count) { throw 'No matching resource types. Start a new check to try another search.' }
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

function Export-CheckerReport {
    param([object[]]$Rows, [string]$ReportType, [string]$Directory = (Get-Location).Path)
    if (-not $Rows.Count) { throw 'No successful report to export.' }
    if ($ReportType -notin @('availability','sku','quota','policy','zones','rbac','names','demand')) { throw 'Invalid report type.' }
    $path = Join-Path $Directory ('azure-availability-{0}-{1}.csv' -f $ReportType,(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    $Rows | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8 -UseCulture -ErrorAction Stop
    return $path
}

# Additional checks share the same authenticated CLI context. No Azure mutations.
function Get-ExtendedSkuRows {
    param($Region,[string]$Service,[string]$SubId)
    if ($Service -eq 'API Management') {
        $url = "/subscriptions/$SubId/providers/Microsoft.ApiManagement/skus?api-version=2024-05-01"
        foreach ($sku in @(Get-ArmList -Url $url -SubId $SubId)) {
            if (-not $sku.name) { New-SkuRow $Region $Service '(unparsed)' '' 'UNKNOWN' 'Missing SKU name.' $SubId; continue }
            New-SkuRow $Region $Service $sku.name $sku.tier (Get-SkuRestrictionStatus $sku $Region) (ConvertTo-Json -InputObject $sku -Depth 20 -Compress) $SubId
        }
    } else {
        $kind = if ($Service -eq 'Azure OpenAI') { 'OpenAI' } else { 'AIServices' }
        foreach ($item in @(Invoke-AzJson @('cognitiveservices','account','list-skus','--kind',$kind,'--location',$Region.Name,'--subscription',$SubId))) {
            $sku = if ($item.sku) { $item.sku } else { $item }
            $status = if (-not $sku.name) { 'UNKNOWN' } elseif ($item.locations) { Get-SkuRestrictionStatus $item $Region } elseif ($item.restrictions) { 'RESTRICTION_UNKNOWN' } else { 'LISTED' }
            New-SkuRow $Region $Service $sku.name $sku.tier $status (ConvertTo-Json -InputObject $item -Depth 20 -Compress) $SubId
        }
    }
}

function Get-ArmList {
    param([string]$Url,[string]$SubId)
    $seen = @{}
    while ($Url) {
        if ($seen.ContainsKey($Url)) { throw 'Repeated ARM pagination URL.' }
        $seen[$Url] = $true
        $page = Invoke-AzJson @('rest','--method','get','--url',$Url,'--subscription',$SubId)
        if ($null -eq $page.PSObject.Properties['value']) { throw 'Unexpected ARM list response.' }
        foreach ($item in @($page.value | Where-Object { $_ })) { $item }
        $Url = $page.nextLink
    }
}

function Get-ZoneStatus {
    param($Sku,$Region,[string]$Zone)
    $regional = Get-SkuRestrictionStatus $Sku $Region
    if ($regional -eq 'RESTRICTED') { return 'RESTRICTED' }
    if ($regional -eq 'NOT_LISTED') { return 'NOT_LISTED' }
    if ($regional -in @('UNKNOWN','RESTRICTION_UNKNOWN')) { return 'UNKNOWN' }
    $aliases = @(@($Region.Name,$Region.DisplayName,$Region.RegionalDisplayName) | Where-Object { $_ } | ForEach-Object { Normalize-Location $_ })
    $info = @($Sku.locationInfo | Where-Object { (Normalize-Location $_.location) -in $aliases })
    $zones = @($info | ForEach-Object { $_.zones } | Where-Object { $_ })
    if (-not $zones.Count) { return 'UNKNOWN' }
    if ($Zone -notin $zones) { return 'NOT_LISTED' }
    foreach ($r in @($Sku.restrictions | Where-Object { $_ -and $_.type -eq 'Zone' })) {
        $locations = @($r.restrictionInfo.locations | Where-Object { $_ } | ForEach-Object { Normalize-Location $_ })
        if ($locations.Count -and -not @($locations | Where-Object { $_ -in $aliases }).Count) { continue }
        $restrictedZones = @($r.restrictionInfo.zones | Where-Object { $_ })
        if (-not $locations.Count -or -not $restrictedZones.Count) { return 'UNKNOWN' }
        if ($Zone -in $restrictedZones) { return 'RESTRICTED' }
    }
    'LISTED'
}

function Invoke-ZoneCheck {
    param([string]$SubId,[object[]]$SelectedRegions,[string[]]$Requests)
    $regions = if ($SelectedRegions.Count) { @($SelectedRegions) } else { @(Select-AzureRegions $SubId) }
    if (-not $Requests.Count) {
        $service = Select-Menu -Title 'Zonal service' -Items @('Virtual Machine','Managed Disk','API Management' | ForEach-Object { [pscustomobject]@{Name=$_} })
        $sku = (Read-Host 'Exact SKU name').Trim()
        $Requests = @('1','2','3' | ForEach-Object { "$($service.Name)|$sku|$_" })
    }
    $rows = @(foreach ($request in $Requests) {
        $p = $request -split '\|',3
        if ($p.Count -ne 3 -or $p[0] -notin @('Virtual Machine','Managed Disk','API Management') -or $p[1] -notmatch '^[A-Za-z0-9._ -]+$' -or $p[2] -notmatch '^[1-9][0-9]*$') { throw 'Zone request must be Service|SKU|zone.' }
        foreach ($region in $regions) {
            $status = 'UNKNOWN'; $detail = ''
            try {
                Assert-Subscription $SubId
                $data = if ($p[0] -eq 'API Management') { @(Get-ArmList -Url "/subscriptions/$SubId/providers/Microsoft.ApiManagement/skus?api-version=2024-05-01" -SubId $SubId) } else {
                    $type = if ($p[0] -eq 'Virtual Machine') { 'virtualMachines' } else { 'disks' }
                    @(Invoke-AzJson @('vm','list-skus','--location',$region.Name,'--resource-type',$type,'--all','--subscription',$SubId))
                }
                $match = @($data | Where-Object name -eq $p[1])
                if ($match.Count -eq 1) { $status = Get-ZoneStatus $match[0] $region $p[2]; $detail = 'Logical zone SKU metadata; capacity not verified.' }
                else { $detail = 'No unique matching SKU; cannot infer zone support.' }
            } catch { $status='ERROR'; $detail=$_.Exception.Message }
            [pscustomobject]@{Region=$region.DisplayName;Service=$p[0];SKU=$p[1];Zone=$p[2];Status=$status;Detail=$detail;SubscriptionId=$SubId}
        }
    })
    Show-CheckTable -Rows $rows -Columns @('Status','Region','Service','SKU','Zone','Detail')
    return $rows
}

function Test-ArmActionGrant {
    param([object[]]$Permissions,[string]$Action)
    foreach ($permission in $Permissions) {
        # NotActions subtract from this permission entry, not from other grants.
        $allowed = @($permission.actions | Where-Object { $_ -and $Action -like $_ }).Count -gt 0
        $excluded = @($permission.notActions | Where-Object { $_ -and $Action -like $_ }).Count -gt 0
        if ($allowed -and -not $excluded) { return $true }
    }
    return $false
}

function Invoke-RbacCheck {
    param([string]$SubId,[string]$Group,[string[]]$Actions)
    if (-not $Group) { $Group = (Read-Host 'Existing resource group name').Trim() }
    if (-not $Actions.Count) { $Actions = @((Read-Host 'ARM actions separated by commas (e.g. Microsoft.Storage/storageAccounts/write)') -split ',' | ForEach-Object { $_.Trim() }) }
    if ($Group -notmatch '^[A-Za-z0-9_.-]+$') { throw 'Invalid or unsupported resource group name.' }
    foreach ($action in $Actions) { if ($action -notmatch '^[A-Za-z0-9.]+/[A-Za-z0-9._/-]+$') { throw 'Use exact ARM actions, without wildcards.' } }
    $scope = "/subscriptions/$SubId/resourceGroups/$Group"
    $problem = $null
    try {
        Assert-Subscription $SubId
        $permissions = @(Get-ArmList -Url "$scope/providers/Microsoft.Authorization/permissions?api-version=2022-04-01" -SubId $SubId)
    } catch { $problem = $_.Exception.Message }
    $rows = @(foreach ($action in $Actions) {
        $status = if ($problem) { 'ERROR' } elseif (Test-ArmActionGrant $permissions $action) { 'GRANT_LISTED' } else { 'GRANT_NOT_LISTED' }
        $detail = if ($problem) { $problem } else { 'Caller control-plane permission metadata only; deny assignments, conditions, locks, data-plane and other scopes are not evaluated.' }
        [pscustomobject]@{Region='(scope)';Scope=$scope;Action=$action;Status=$status;Detail=$detail;SubscriptionId=$SubId}
    })
    Write-Host "Scope: $scope"
    Show-CheckTable -Rows $rows -Columns @('Status','Action')
    if ($problem) { Write-Host $problem -ForegroundColor Red }
    else { Write-Host 'Caller control-plane permission metadata only; deny assignments, conditions, locks, data-plane and other scopes are not evaluated.' -ForegroundColor Yellow }
    return $rows
}

function Get-NameCheckStatus {
    param($Response,[switch]$ExistsResponse)
    if ($ExistsResponse -and $Response -is [bool]) { if ($Response) { return 'UNAVAILABLE' }; return 'NOT_FOUND' }
    foreach ($key in @('nameAvailable','available')) {
        if ($null -ne $Response -and $Response.$key -is [bool]) { if ($Response.$key) { return 'AVAILABLE' }; return 'UNAVAILABLE' }
    }
    return 'UNKNOWN'
}

function Invoke-NameCheck {
    param([string]$SubId,[string[]]$Requests)
    $commands = @{
        'Storage Account'=@('storage','account','check-name'); 'Key Vault'=@('keyvault','check-name'); 'Container Registry'=@('acr','check-name'); 'API Management'=@('apim','check-name'); 'Cosmos DB'=@('cosmosdb','check-name-exists')
    }
    if (-not $Requests.Count) {
        $service = Select-Menu -Title 'Name check service' -Items @($commands.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{Name=$_} })
        $Requests = @((Read-Host 'Candidate names, separated by commas') -split ',' | ForEach-Object { "$($service.Name)|$($_.Trim())" })
    }
    $rows = @(foreach ($request in $Requests) {
        $p = $request -split '\|',2
        if ($p.Count -ne 2 -or -not $commands.ContainsKey($p[0]) -or $p[1] -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,127}$') { throw 'Name request must be Service|candidate-name; use only letters, numbers and hyphens.' }
        try {
            Assert-Subscription $SubId
            $response = Invoke-AzJson ($commands[$p[0]] + @('--name',$p[1],'--subscription',$SubId))
            $status = Get-NameCheckStatus $response -ExistsResponse:($p[0] -eq 'Cosmos DB')
            $detail = ConvertTo-Json -InputObject $response -Depth 12 -Compress
        } catch { $status='ERROR'; $detail=$_.Exception.Message }
        [pscustomobject]@{Region='(namespace)';Service=$p[0];Name=$p[1];Status=$status;Detail=$detail;SubscriptionId=$SubId}
    })
    Show-CheckTable -Rows $rows -Columns @('Status','Service','Name','Detail')
    Write-Host 'Name availability is a point-in-time result, not a reservation or deployment guarantee. NOT_FOUND only means no existing name was reported.' -ForegroundColor Yellow
    return $rows
}

function Get-QuotaDemandRows {
    param([object[]]$Quota,[object[]]$Regions,[string[]]$Requests,[string]$SubId)
    $seen = @{}
    foreach ($request in $Requests) {
        $p = $request -split '\|',3
        $amount = 0.0
        if ($p.Count -ne 3 -or -not $p[0].Trim() -or -not $p[1].Trim() -or $p[2] -notmatch '^[0-9]+(\.[0-9]+)?$' -or -not [double]::TryParse($p[2],[Globalization.NumberStyles]::AllowDecimalPoint,[Globalization.CultureInfo]::InvariantCulture,[ref]$amount) -or [double]::IsInfinity($amount) -or $amount -le 0) { throw 'Quota demand must be Provider|exact quota label|positive additional units.' }
        $key = "$($p[0])|$($p[1])"
        if ($seen.ContainsKey($key)) { throw 'Duplicate quota demand. Supply total additional units once per quota.' }
        $seen[$key] = $true
        foreach ($region in $Regions) {
            $match = @($Quota | Where-Object { $_.Region -eq $region.DisplayName -and ($_.Service -split ' ',2)[0] -eq $p[0] -and $_.Quota -eq $p[1] })
            $remaining=$null; $status='UNKNOWN'; $unit=''
            if ($match.Count -eq 1 -and $match[0].Status -in @('HEADROOM','NEAR_LIMIT','EXHAUSTED') -and $null -ne $match[0].Remaining) {
                $remaining=$match[0].Remaining; $unit=$match[0].Unit
                $status = if ($remaining -ge $amount) { 'FITS' } else { 'INSUFFICIENT' }
            }
            [pscustomobject]@{Region=$region.DisplayName;Service=$p[0];Quota=$p[1];Requested=$amount;Remaining=$remaining;Unit=$unit;Status=$status;Detail='Additional units in provider-reported quota units; not a capacity reservation.';SubscriptionId=$SubId}
        }
    }
}

function Select-QuotaDemandRequest {
    param([object[]]$Quota)
    $choices = @($Quota | Where-Object { $_.Status -in @('HEADROOM','NEAR_LIMIT','EXHAUSTED') -and $null -ne $_.Remaining -and $_.Quota } | ForEach-Object {
        $provider = ($_.Service -split ' ',2)[0]
        [pscustomobject]@{Name="$provider | $($_.Quota)";Provider=$provider;Quota=$_.Quota}
    } | Sort-Object Name -Unique)
    if (-not $choices.Count) { Write-Host 'No usable quota data; demand comparison skipped.' -ForegroundColor Yellow; return }
    $choice = Select-Menu -Title 'Quota to compare' -Items $choices
    do {
        $amount = (Read-Host 'Additional units (decimal dot)').Trim()
        $value = 0.0
        $valid = $amount -match '^[0-9]+(\.[0-9]+)?$' -and [double]::TryParse($amount,[Globalization.NumberStyles]::AllowDecimalPoint,[Globalization.CultureInfo]::InvariantCulture,[ref]$value) -and -not [double]::IsInfinity($value) -and $value -gt 0
        if (-not $valid) { Write-Host 'Enter a positive number, using a decimal dot.' -ForegroundColor Yellow }
    } until ($valid)
    return "$($choice.Provider)|$($choice.Quota)|$amount"
}

function Get-ExtendedFindings {
    param([string]$Kind,[object[]]$Rows)
    if (-not $Rows.Count) { [pscustomobject]@{Check=$Kind;Region='';Subject='';Severity='ERROR';Reason='No report rows returned.'}; return }
    foreach ($row in $Rows) {
        $severity = switch ($row.Status) {
            { $_ -in @('ERROR','UNKNOWN','NO_DATA') } { 'ERROR'; break }
            { $_ -in @('RESTRICTED','NOT_LISTED','UNAVAILABLE','INSUFFICIENT') } { 'BLOCK'; break }
            'GRANT_NOT_LISTED' { 'ERROR'; break }
            'NOT_FOUND' { 'ERROR'; break }
            'GRANT_LISTED' { 'WARNING'; break }
            { $_ -in @('LISTED','AVAILABLE','FITS') } { ''; break }
            default { 'ERROR' }
        }
        if ($severity) { [pscustomobject]@{Check=$Kind;Region=$row.Region;Subject=(@($row.Service,$row.SKU,$row.Zone,$row.Name,$row.Action,$row.Quota) | Where-Object { $_ }) -join ' ';Severity=$severity;Reason=$row.Status} }
    }
}

# Automation mode is intentionally explicit: no menu or Read-Host calls.
function Get-CheckerOptions {
    param([System.Collections.IDictionary]$Bound)
    $keys = @('Subscription','Regions','Resources','SkuService','SkuName','AppLinux','CheckQuota','QuotaProviders','CheckPolicy','ResourceGroup','FailOnWarning','OutputJson','SkuRequests','QuotaDemand','ZoneRequests','RbacGroup','RbacActions','NameRequests')
    $boolKeys = @('AppLinux','CheckQuota','CheckPolicy','FailOnWarning')
    $arrayKeys = @('Regions','Resources','QuotaProviders','SkuRequests','QuotaDemand','ZoneRequests','RbacActions','NameRequests')
    $opts = @{}
    foreach ($key in $keys) { $opts[$key] = $null }
    if ($Bound['ConfigPath']) {
        foreach ($key in $keys) { if ($Bound.Contains($key)) { throw 'Use either ConfigPath or explicit options, not both.' } }
        $config = Get-Content -LiteralPath $Bound['ConfigPath'] -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($config -isnot [pscustomobject]) { throw 'Configuration must be a JSON object.' }
        foreach ($prop in $config.PSObject.Properties) {
            if ($prop.Name -notin $keys) { throw "Unknown config field: $($prop.Name)" }
            if ($prop.Name -in $boolKeys -and $prop.Value -isnot [bool]) { throw "$($prop.Name) must be a JSON boolean." }
            if ($prop.Name -in $arrayKeys -and $prop.Value -isnot [array]) { throw "$($prop.Name) must be a JSON string array." }
            if ($prop.Name -notin ($boolKeys + $arrayKeys) -and $prop.Value -isnot [string]) { throw "$($prop.Name) must be a JSON string." }
            $opts[$prop.Name] = $prop.Value
        }
    } else {
        foreach ($key in $keys) { if ($Bound.Contains($key)) { $opts[$key] = $Bound[$key] } }
    }
    if (-not $opts.Subscription -or -not @($opts.Regions | Where-Object { $_ }).Count -or -not @($opts.Resources | Where-Object { $_ }).Count) { throw 'Subscription, Regions and Resources are required in non-interactive mode.' }
    foreach ($key in $arrayKeys) {
        foreach ($value in @($opts[$key] | Where-Object { $null -ne $_ })) {
            if ($value -isnot [string] -or -not $value.Trim()) { throw "$key must contain nonempty strings." }
        }
        $opts[$key] = @($opts[$key] | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Select-Object -Unique)
    }
    foreach ($value in $opts.Resources) { if ($value -notmatch '^[A-Za-z0-9.]+/[A-Za-z0-9._/-]+$') { throw "Invalid full ARM resource type: $value" } }
    foreach ($value in $opts.Regions) { if ($value -notmatch '^[A-Za-z0-9 ]+$') { throw "Invalid region: $value" } }
    if ([bool]$opts.SkuService -ne [bool]$opts.SkuName) { throw 'SkuService and SkuName must be provided together.' }
    if ($opts.SkuService -and $opts.SkuService -notin @('Virtual Machine','Managed Disk','Storage Account','App Service Plan','SQL Database','PostgreSQL Flexible Server','MySQL Flexible Server','API Management','Azure OpenAI','Azure AI Services')) { throw 'Unsupported SKU service.' }
    if ($opts.SkuName -and $opts.SkuName -notmatch '^[A-Za-z0-9._ -]+$') { throw 'Invalid SKU name.' }
    if ($opts.SkuService -eq 'App Service Plan' -and -not (Test-AppServiceSku $opts.SkuName)) { throw 'Invalid App Service SKU.' }
    if ($opts.AppLinux -and $opts.SkuService -ne 'App Service Plan' -and -not @($opts.SkuRequests | Where-Object { $_ -like 'App Service Plan|*' }).Count) { throw 'AppLinux requires App Service Plan.' }
    if ($opts.QuotaProviders.Count -and -not $opts.CheckQuota) { throw 'QuotaProviders requires CheckQuota.' }
    if ($opts.CheckQuota -and -not $opts.QuotaProviders.Count) { $opts.QuotaProviders = @('Compute','Network','Storage','SQL') }
    foreach ($value in $opts.QuotaProviders) { if ($value -notin @('Compute','Network','Storage','SQL','CognitiveServices','ContainerApps')) { throw "Unsupported quota provider: $value" } }
    if ($opts.ResourceGroup -and (-not $opts.CheckPolicy -or $opts.ResourceGroup -notmatch '^[\p{L}\p{N}_.()-]+$' -or $opts.ResourceGroup -match '[()]')) { throw 'ResourceGroup requires CheckPolicy and a group name without parentheses in automation mode.' }
    if ($opts.SkuRequests.Count -and $opts.SkuService) { throw 'Use SkuRequests or SkuService/SkuName, not both.' }
    foreach ($request in $opts.SkuRequests) {
        $parts = $request -split '\|',2
        if ($parts.Count -ne 2 -or $parts[0] -notin @('Virtual Machine','Managed Disk','Storage Account','App Service Plan','SQL Database','PostgreSQL Flexible Server','MySQL Flexible Server','API Management','Azure OpenAI','Azure AI Services') -or $parts[1] -notmatch '^[A-Za-z0-9._ -]+$' -or ($parts[0] -eq 'App Service Plan' -and -not (Test-AppServiceSku $parts[1]))) { throw 'SkuRequests entries must be Service|exact SKU.' }
    }
    if ($opts.QuotaDemand.Count -and -not $opts.CheckQuota) { throw 'QuotaDemand requires CheckQuota.' }
    if ([bool]$opts.RbacActions.Count -ne [bool]$opts.RbacGroup) { throw 'RbacGroup and RbacActions must be supplied together.' }
    return $opts
}

function Resolve-CheckerRegions {
    param([string]$SubId, [string[]]$Requested)
    Assert-Subscription $SubId
    $available = @(Invoke-AzJson @('account','list-locations') | Where-Object {
        ($_.metadata.regionType -eq 'Physical' -or (-not $_.metadata.regionType -and $_.type -eq 'Region')) -and (-not $_.type -or $_.type -eq 'Region')
    })
    $chosen = @{}
    foreach ($name in $Requested) {
        $normalized = Normalize-Location $name
        $matches = @($available | Where-Object { (Normalize-Location $_.name) -eq $normalized -or (Normalize-Location $_.displayName) -eq $normalized })
        if ($matches.Count -ne 1) { throw "Region not uniquely found in subscription: $name" }
        $r = $matches[0]
        if (-not $chosen.ContainsKey($r.name)) {
            $chosen[$r.name] = $true
            [pscustomobject]@{Name=$r.name;DisplayName=$r.displayName;RegionalDisplayName=$r.regionalDisplayName}
        }
    }
}

function Get-PreflightDecision {
    param([object[]]$Availability, [object[]]$Sku, [object[]]$Quota, [object[]]$Policy, [switch]$ExpectSku, [switch]$ExpectQuota, [switch]$ExpectPolicy, [switch]$Strict)
    $findings = @(foreach ($kind in @('availability','sku','quota','policy')) {
        $rows = switch ($kind) { 'availability' { $Availability } 'sku' { $Sku } 'quota' { $Quota } 'policy' { $Policy } }
        $expected = $kind -eq 'availability' -or ($kind -eq 'sku' -and $ExpectSku) -or ($kind -eq 'quota' -and $ExpectQuota) -or ($kind -eq 'policy' -and $ExpectPolicy)
        if (-not @($rows | Where-Object { $_ }).Count -and $expected) { [pscustomobject]@{Check=$kind;Region='';Subject='';Severity='ERROR';Reason='No report rows returned.'} }
        foreach ($row in @($rows | Where-Object { $_ })) {
            $severity = ''; $reason = [string]$row.Status
            if ($row.Status -in @('ERROR','NO_DATA','UNKNOWN','RESTRICTION_UNKNOWN','REGISTERING','REGISTRATION_UNKNOWN')) { $severity = 'ERROR' }
            elseif ($row.Status -eq 'NOT_REGISTERED') { $severity='BLOCK' }
            elseif ($kind -eq 'availability') {
                if ($row.Status -eq 'NOT_SUPPORTED') { $severity = 'BLOCK' }
                elseif ($row.Status -ne 'SUPPORTED') { $severity = 'ERROR' }
                if ($row.Registration -eq 'NotRegistered' -and -not $severity) { $severity='BLOCK'; $reason='Provider not registered.' }
                elseif ($row.Registration -ne 'Registered' -and -not $severity) { $severity='ERROR'; $reason='Provider registration not confirmed.' }
            } elseif ($kind -eq 'sku') {
                if ($row.Status -in @('RESTRICTED','NOT_LISTED','UNAVAILABLE')) { $severity='BLOCK' }
                elseif ($row.Status -eq 'ZONE_RESTRICTED') { $severity='WARNING' }
                elseif ($row.Status -ne 'LISTED') { $severity='ERROR' }
            } elseif ($kind -eq 'quota') {
                if ($row.Status -in @('NEAR_LIMIT','EXHAUSTED')) { $severity='WARNING'; $reason += ' (deployment demand not supplied)' }
                elseif ($row.Status -notin @('HEADROOM','INFORMATIONAL')) { $severity='ERROR' }
            } elseif ($kind -eq 'policy') {
                if ($row.Status -eq 'POTENTIAL_DENY') { $severity='BLOCK' }
                elseif ($row.Status -in @('REVIEW','NO_ASSIGNMENTS','AUDIT')) { $severity='WARNING' }
                elseif ($row.Status -notin @('NO_MATCH','NOT_ENFORCED','DISABLED','SCOPE_EXCLUDED')) { $severity='ERROR' }
            }
            if ($severity) {
                $subject = switch ($kind) { 'availability' { "$($row.Provider)/$($row.ResourceType)" } 'sku' { "$($row.Service): $($row.SKU)" } 'quota' { "$($row.Service): $($row.Quota)" } 'policy' { [string]$row.Assignment } }
                [pscustomobject]@{Check=$kind;Region=$row.Region;Subject=$subject;Severity=$severity;Reason=$reason}
            }
        }
    })
    $code = if (@($findings | Where-Object Severity -eq 'ERROR').Count) { 2 } elseif (@($findings | Where-Object Severity -eq 'BLOCK').Count -or ($Strict -and @($findings | Where-Object Severity -eq 'WARNING').Count)) { 1 } else { 0 }
    [pscustomobject]@{ExitCode=$code;Findings=$findings}
}

function Invoke-CheckerPreflight {
    param([string]$SubId, [hashtable]$Options, [object[]]$Catalog)
    $selected = @(Resolve-CheckerRegions -SubId $SubId -Requested $Options.Regions)
    if (-not $selected.Count) { throw 'No regions resolved.' }
    $requested = @(foreach ($key in $Options.Resources) {
        $parts = $key -split '/',2
        $friendly = @($Catalog | Where-Object { $_.Provider -eq $parts[0] -and $_.Type -eq $parts[1] })
        $name = if ($friendly.Count) { $friendly[0].Name } else { $key }
        New-Resource $name $parts[0] $parts[1]
    })
    $availability = @(Invoke-AvailabilityCheck -SubId $SubId -Catalog $Catalog -SelectedRegions $selected -SelectedResources $requested)
    $sku = @(); $quota = @(); $policy = @()
    if ($Options.SkuService) { $sku = @(Invoke-SkuCheck -SubId $SubId -SelectedRegions $selected -RequestedService $Options.SkuService -RequestedSku $Options.SkuName -LinuxWorkers:([bool]$Options.AppLinux)) }
    if ($Options.SkuRequests.Count) {
        $sku = @(foreach ($request in $Options.SkuRequests) {
            $parts = $request -split '\|',2
            Invoke-SkuCheck -SubId $SubId -SelectedRegions $selected -RequestedService $parts[0] -RequestedSku $parts[1] -LinuxWorkers:([bool]$Options.AppLinux)
        })
    }
    if ($Options.CheckQuota) { $quota = @(Invoke-QuotaCheck -SubId $SubId -SelectedRegions $selected -RequestedProviders $Options.QuotaProviders) }
    if ($Options.CheckPolicy) {
        $policy = @(foreach ($r in $requested) { Invoke-PolicyCheck -SubId $SubId -SelectedRegions $selected -RequestedGroup $Options.ResourceGroup -RequestedType "$($r.Provider)/$($r.Type)" })
    }
    $decision = Get-PreflightDecision -Availability $availability -Sku $sku -Quota $quota -Policy $policy -ExpectSku:([bool]($Options.SkuService -or $Options.SkuRequests.Count)) -ExpectQuota:([bool]$Options.CheckQuota) -ExpectPolicy:([bool]$Options.CheckPolicy) -Strict:([bool]$Options.FailOnWarning)
    $zones = @(); $rbac = @(); $names = @(); $demand = @(); $extra = @()
    if ($Options.ZoneRequests.Count) { $zones = @(Invoke-ZoneCheck -SubId $SubId -SelectedRegions $selected -Requests $Options.ZoneRequests); $extra += @(Get-ExtendedFindings zones $zones) }
    if ($Options.RbacActions.Count) { $rbac = @(Invoke-RbacCheck -SubId $SubId -Group $Options.RbacGroup -Actions $Options.RbacActions); $extra += @(Get-ExtendedFindings rbac $rbac) }
    if ($Options.NameRequests.Count) { $names = @(Invoke-NameCheck -SubId $SubId -Requests $Options.NameRequests); $extra += @(Get-ExtendedFindings names $names) }
    if ($Options.QuotaDemand.Count) { $demand = @(Get-QuotaDemandRows -Quota $quota -Regions $selected -Requests $Options.QuotaDemand -SubId $SubId); $extra += @(Get-ExtendedFindings demand $demand); Show-CheckTable -Rows $demand -Columns @('Status','Region','Service','Quota','Requested','Remaining','Unit') }
    $decision.Findings = @($decision.Findings) + @($extra)
    $decision.ExitCode = if (@($decision.Findings | Where-Object Severity -eq 'ERROR').Count) { 2 } elseif (@($decision.Findings | Where-Object Severity -eq 'BLOCK').Count -or ($Options.FailOnWarning -and @($decision.Findings | Where-Object Severity -eq 'WARNING').Count)) { 1 } else { 0 }
    $report = [pscustomobject]@{Version='3.8.1';GeneratedUtc=[DateTime]::UtcNow.ToString('o');SubscriptionId=$SubId;ExitCode=$decision.ExitCode;Findings=@($decision.Findings);Availability=$availability;Sku=$sku;Quota=$quota;Policy=$policy;Zones=$zones;Rbac=$rbac;Names=$names;QuotaDemand=$demand}
    if ($Options.OutputJson) { ConvertTo-Json -InputObject $report -Depth 30 | Set-Content -LiteralPath $Options.OutputJson -Encoding UTF8 -ErrorAction Stop }
    if ($decision.Findings.Count) { $decision.Findings | Format-Table Check,Region,Severity,Subject,Reason -Wrap -AutoSize | Out-Host }
    Write-Host "Preflight exit code: $($decision.ExitCode). Metadata screening only; no deployment guarantee."
    return $decision.ExitCode
}

# Loading functions for Pester must not start an interactive Azure session.
if ($MyInvocation.InvocationName -eq '.') { return }
$ErrorActionPreference = 'Stop'

$previousSubId = $null
$restoreSubscription = $false
$exitCode = 0
$automation = $NonInteractive -or [bool]$ConfigPath

try {
    if ($automation) { $options = Get-CheckerOptions -Bound $checkerBound }
    elseif (@($checkerBound.Keys | Where-Object { $_ -in @('Subscription','Regions','Resources','SkuService','SkuName','AppLinux','CheckQuota','QuotaProviders','CheckPolicy','ResourceGroup','FailOnWarning','OutputJson','SkuRequests','QuotaDemand','ZoneRequests','RbacGroup','RbacActions','NameRequests') }).Count) { throw 'Use NonInteractive when supplying automation options.' }
    Write-Host 'AZURE RESOURCE AVAILABILITY CHECKER v3.8.1' -ForegroundColor Cyan
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI not found. Install it first.' }
    $subscriptions = @(Invoke-AzJson @('account','list') | Where-Object { $_.state -eq 'Enabled' } | Sort-Object name | ForEach-Object {
        [pscustomobject]@{ Name = "$($_.name) ($($_.id))"; AccountName = $_.name; Id = $_.id }
    })
    if ($subscriptions.Count -eq 0) { throw 'No enabled subscription found. Run az login first.' }
    if ($automation) {
        $selectedSubscription = Resolve-SubscriptionSelection -Subscriptions $subscriptions -Requested $options.Subscription
    } else { $selectedSubscription = Select-Menu -Title 'Subscription' -Items $subscriptions }
    $subId = $selectedSubscription.Id

    $previousSubId = (Invoke-AzJson @('account','show')).id
    if (-not $previousSubId) { throw 'Cannot determine the current Azure CLI subscription.' }
    if ($previousSubId -ne $subId) {
        $restoreSubscription = $true
        & az account set --subscription $subId --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw 'Cannot select the requested subscription.' }
    }
    $activeSubId = (Invoke-AzJson @('account','show')).id
    if ($activeSubId -ne $subId) { throw 'Active Azure CLI subscription does not match the selection.' }

    if ($automation) { $exitCode = Invoke-CheckerPreflight -SubId $subId -Options $options -Catalog $catalog }
    else {
    # Show the menu immediately after selection.
    $lastResults = @()
    $lastReportType = 'availability'
    $action = ''
    while ($true) {
        if ($action -eq 'Q') { break }
        if ($action -eq 'N') {
            try {
                $newResults = @(Invoke-AvailabilityCheck -SubId $subId -Catalog $catalog)
                if ($newResults.Count -gt 0) { $lastResults = $newResults; $lastReportType = 'availability' }
            } catch [System.OperationCanceledException] {
                throw
            } catch {
                Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
                if ($lastResults.Count -gt 0) {
                    Write-Host 'The last successful report is still available for export.' -ForegroundColor Yellow
                }
            }
        } elseif ($action -in @('K','U','P','Z','R','A','D')) {
            try {
                $newResults = switch ($action) {
                    'K' { Invoke-SkuCheck -SubId $subId }
                    'U' { Invoke-QuotaCheck -SubId $subId }
                    'P' { Invoke-PolicyCheck -SubId $subId }
                    'Z' { Invoke-ZoneCheck -SubId $subId }
                    'R' { Invoke-RbacCheck -SubId $subId }
                    'A' { Invoke-NameCheck -SubId $subId }
                    'D' {
                        $demandRegions = @(Select-AzureRegions $subId)
                        $usageRows = @(Invoke-QuotaCheck -SubId $subId -SelectedRegions $demandRegions)
                        $request = Select-QuotaDemandRequest $usageRows
                        if ($request) {
                            $demandRows = @(Get-QuotaDemandRows -Quota $usageRows -Regions $demandRegions -Requests @($request) -SubId $subId)
                            Show-CheckTable -Rows $demandRows -Columns @('Status','Region','Service','Quota','Requested','Remaining','Unit')
                            $demandRows
                        }
                    }
                }
                if (@($newResults | Where-Object { $_.Status -notin @('ERROR','NO_DATA','NOT_REGISTERED','REGISTERING','REGISTRATION_UNKNOWN') }).Count -gt 0) {
                    $lastResults = @($newResults)
                    $lastReportType = switch ($action) { 'K' {'sku'} 'U' {'quota'} 'P' {'policy'} 'Z' {'zones'} 'R' {'rbac'} 'A' {'names'} 'D' {'demand'} }
                } else { Write-Host 'No usable new report; previous report retained.' -ForegroundColor Yellow }
            } catch [System.OperationCanceledException] { throw } catch {
                Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
            }
        } elseif ($action -eq 'S') {
            # Always restore the original CLI context on exit, even after multiple switches.
            try {
                Assert-Subscription $subId
                $nextSubscription = Select-Menu -Title 'Subscription' -Items $subscriptions
                if ($nextSubscription.Id -ne $subId) {
                    $restoreSubscription = $true
                    & az account set --subscription $nextSubscription.Id --only-show-errors
                    if ($LASTEXITCODE -ne 0) { throw 'Cannot select the requested subscription.' }
                    Assert-Subscription $nextSubscription.Id
                    $selectedSubscription = $nextSubscription
                    $subId = $selectedSubscription.Id
                    $lastResults = @()
                    $lastReportType = 'availability'
                    Write-Host 'Subscription switched; previous report cleared.' -ForegroundColor Green
                }
            } catch [System.OperationCanceledException] { Write-Host 'Subscription switch cancelled.' } catch {
                Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
                # Do not continue if the CLI context is no longer the expected one.
                Assert-Subscription $subId
            }
        } elseif ($action -eq 'E') {
            if ($lastResults.Count -eq 0) {
                Write-Host 'No successful report to export. Run a check first.' -ForegroundColor Yellow
            } else {
                try {
                    $path = Export-CheckerReport -Rows $lastResults -ReportType $lastReportType
                    Write-Host "Saved: $path" -ForegroundColor Green
                } catch {
                    Write-Host "Export failed: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }

        Write-Host "`n=== Main menu ===" -ForegroundColor Cyan
        Write-Host "Subscription: $($selectedSubscription.Name)"
        Write-Host '[Enter / N] New availability check (choose regions and scope)'
        Write-Host '[K] Check SKU availability'
        Write-Host '[U] Check quota and usage'
        Write-Host '[P] Check Azure Policy assignments'
        Write-Host '[Z] Check SKU availability zones'
        Write-Host '[R] Check caller RBAC grants in resource group'
        Write-Host '[A] Check resource name availability'
        Write-Host '[D] Compare additional demand against quota'
        if ($lastResults.Count -gt 0) {
            $reportRegions = @($lastResults | Select-Object -ExpandProperty Region -Unique) -join ', '
            Write-Host "[E] Export last successful report to CSV ($lastReportType; $($lastResults.Count) rows; $reportRegions)"
        } else {
            Write-Host '[E] Export last report (no report available)' -ForegroundColor DarkGray
        }
        Write-Host '[S] Switch subscription'
        Write-Host '[Q] Quit'
        do {
            $action = (Read-Host 'Select action [Enter for new check]').Trim().ToUpperInvariant()
            if ($action -eq '') { $action = 'N' }
            if ($action -notin @('N','K','U','P','Z','R','A','D','E','S','Q')) { Write-Host 'Invalid selection. Try again.' -ForegroundColor Yellow }
        } until ($action -in @('N','K','U','P','Z','R','A','D','E','S','Q'))
    }
    }
} catch [System.OperationCanceledException] {
    Write-Host 'Cancelled.'
    if ($automation) { $exitCode = 2 }
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = if ($automation) { 2 } else { 1 }
} finally {
    if ($restoreSubscription -and $previousSubId) {
        try {
            & az account set --subscription $previousSubId --only-show-errors
            if ($LASTEXITCODE -ne 0) { throw 'Azure CLI returned an error.' }
            Write-Host 'Previous Azure CLI subscription restored.' -ForegroundColor Gray
        } catch {
            Write-Warning "Could not restore previous subscription. Run: az account set --subscription $previousSubId"
            if ($automation) { $exitCode = 2 }
        }
    }
}

if ($automation -or $exitCode -ne 0) { exit $exitCode }
