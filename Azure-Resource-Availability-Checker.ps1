#Requires -Version 5.1
<#
.SYNOPSIS
    Azure Resource Availability Checker v3.2.1. Interactive, read-only regional availability checker.
.DESCRIPTION
    Uses Azure CLI and the selected subscription. Does not register providers,
    deploy resources. Includes optional SKU, quota and policy screening checks. Defaults to all resource types
    returned by Azure Resource Manager; optionally filters the report. Supports repeated
    checks and exports the last successful report only on request. Temporarily switches the local
    Azure CLI subscription and restores the previous selection on exit.
#>
$ErrorActionPreference = 'Stop'

function Invoke-AzJson {
    param([string[]]$Arguments)
    # Windows Azure CLI may resolve to a batch launcher. cmd.exe parses
    # unquoted parentheses again; preserve literal quotes for that launcher.
    $azCommand = Get-Command az -ErrorAction Stop
    $cliArguments = @($Arguments)
    if ($azCommand.Path -match '\.(cmd|bat)$') {
        # PowerShell 7 uses legacy native argument passing for batch files.
        # Set it locally even if the caller has chosen Standard mode.
        $PSNativeCommandArgumentPassing = 'Legacy'
        for ($i = 0; $i -lt $cliArguments.Count; $i++) {
            if ($cliArguments[$i] -eq 'atScope()') {
                $cliArguments[$i] = '"atScope()"'
            }
        }
    }
    $raw = & az @cliArguments --only-show-errors --output json
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
    try { $width = [Math]::Max(90, $Host.UI.RawUI.BufferSize.Width) } catch { }
    $table = $Rows | Format-Table -Property $Columns -AutoSize -Wrap | Out-String -Stream -Width $width
    foreach ($line in $table) {
        $color = switch -Regex ($line) {
            '^\s*(LISTED|HEADROOM)\s' { 'Green'; break }
            '^\s*(RESTRICTED|EXHAUSTED|ERROR|NOT_LISTED|POTENTIAL_DENY)\s' { 'Red'; break }
            '^\s*(ZONE_RESTRICTED|RESTRICTION_UNKNOWN|UNKNOWN|NEAR_LIMIT|NO_DATA|REVIEW|AUDIT|NO_ASSIGNMENTS)\s' { 'Yellow'; break }
            default { 'Gray' }
        }
        Write-Host $line -ForegroundColor $color
    }
}

function Invoke-SkuCheck {
    param([string]$SubId)
    $regions = @(Select-AzureRegions $SubId)
    $menu = @('Virtual Machine','Managed Disk','Storage Account','App Service Plan','SQL Database','PostgreSQL Flexible Server','MySQL Flexible Server' | ForEach-Object { [pscustomobject]@{Name=$_} })
    $services = @(Select-Menu -Title 'SKU services' -Items $menu -Multiple)
    $appSku = $null; $appLinux = $false
    if ('App Service Plan' -in $services.Name) {
        do { $appSku = (Read-Host 'App Service SKU (e.g. B1, P1V3)').Trim().ToUpperInvariant() } until ($appSku -match '^[A-Z0-9]+$')
        $appLinux = ((Read-Host 'Linux workers? [y/N]').Trim() -eq 'Y')
    }
    $filter = (Read-Host 'Filter SKU names (optional, Enter for all)').Trim()
    $storageCache = $null
    $results = @(foreach ($region in $regions) {
        foreach ($service in $services.Name) {
            Write-Host "Checking $service SKU metadata in $($region.DisplayName)..." -ForegroundColor Cyan
            try {
                Assert-Subscription $SubId
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
                        $status = if (@($aliases | Where-Object { $_ -in $names }).Count) { 'LISTED' } elseif ($data.Count -gt 0 -and -not $names.Count) { 'UNKNOWN' } else { 'NOT_LISTED' }
                        $tier = if ($appLinux) { 'Linux workers' } else { 'Default (no Linux filter)' }
                        New-SkuRow $region $service $appSku $tier $status 'App Service location list for requested SKU; not a capacity check.' $SubId
                    }
                    'SQL Database' {
                        $data = @(Invoke-AzJson @('sql','db','list-editions','--location',$region.Name,'--available','--subscription',$SubId))
                        foreach ($sku in $data) {
                            $name = if ($sku.serviceObjective) { $sku.serviceObjective } elseif ($sku.serviceObjectiveName) { $sku.serviceObjectiveName } elseif ($sku.sku.name) { $sku.sku.name } elseif ($sku.name) { $sku.name } else { '(unparsed)' }
                            $status = if ($name -eq '(unparsed)') { 'UNKNOWN' } else { 'LISTED' }
                            $tier = if ($sku.edition) { $sku.edition } else { $sku.sku.tier }
                            New-SkuRow $region $service $name $tier $status (ConvertTo-Json -InputObject $sku -Depth 30 -Compress) $SubId
                        }
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
                    $matched = @($rows | Where-Object { -not $filter -or $_.SKU.IndexOf($filter,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or $_.Status -eq 'UNKNOWN' })
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
    Write-Host 'LISTED is catalog evidence only. Restrictions, quotas, policy and capacity can prevent deployment. UNKNOWN means unparsed or missing metadata; export CSV for raw details.' -ForegroundColor Yellow
    return $results
}

function Invoke-QuotaCheck {
    param([string]$SubId)
    $regions = @(Select-AzureRegions $SubId)
    $menu = @(
        [pscustomobject]@{Name='Compute (vCPU, VM families)'; Command=@('vm','list-usage')}
        [pscustomobject]@{Name='Network (public IPs, VNets, etc.)'; Command=@('network','list-usages')}
        [pscustomobject]@{Name='Storage (account counts)'; Command=@('storage','account','show-usage')}
        [pscustomobject]@{Name='SQL (regional subscription usage)'; Command=@('sql','list-usages')}
    )
    $services = @(Select-Menu -Title 'Quota providers' -Items $menu -Multiple)
    $results = @(foreach ($region in $regions) {
        foreach ($service in $services) {
            Write-Host "Checking $($service.Name) in $($region.DisplayName)..." -ForegroundColor Cyan
            try {
                Assert-Subscription $SubId
                $data = @(Invoke-AzJson ($service.Command + @('--location',$region.Name,'--subscription',$SubId)))
                if (-not $data.Count) {
                    [pscustomobject]@{Region=$region.DisplayName; RegionCode=$region.Name; Service=$service.Name; Quota=''; Used=$null; Limit=$null; Remaining=$null; Percent=$null; Unit=''; Status='NO_DATA'; Detail='No quota rows returned.'; SubscriptionId=$SubId}
                }
                foreach ($item in $data) {
                    $name = if ($item.name.localizedValue) { $item.name.localizedValue } elseif ($item.name.value) { $item.name.value } elseif ($item.name -is [string]) { $item.name } else { '(unknown)' }
                    $used = $null; $limit = $null; $remaining = $null; $pct = $null; $status = 'UNKNOWN'
                    $u = 0.0; $l = 0.0
                    $rawUsed = if ($null -ne $item.currentValue) { $item.currentValue } else { $item.currentUsage }
                    if ($null -ne $rawUsed -and $null -ne $item.limit -and [double]::TryParse([string]$rawUsed,[ref]$u) -and [double]::TryParse([string]$item.limit,[ref]$l) -and $u -ge 0 -and $l -ge 0) {
                        $used=$u; $limit=$l; $remaining=[Math]::Max(0,$l-$u)
                        if ($l -gt 0) { $pct=[Math]::Round(100*$u/$l,1) }
                        $status = if ($u -ge $l) { 'EXHAUSTED' } elseif ($pct -ge 80) { 'NEAR_LIMIT' } else { 'HEADROOM' }
                    }
                    [pscustomobject]@{Region=$region.DisplayName; RegionCode=$region.Name; Service=$service.Name; Quota=$name; Used=$used; Limit=$limit; Remaining=$remaining; Percent=$pct; Unit=$item.unit; Status=$status; Detail=(ConvertTo-Json -InputObject $item -Depth 12 -Compress); SubscriptionId=$SubId}
                }
            } catch {
                [pscustomobject]@{Region=$region.DisplayName; RegionCode=$region.Name; Service=$service.Name; Quota=''; Used=$null; Limit=$null; Remaining=$null; Percent=$null; Unit=''; Status='ERROR'; Detail=$_.Exception.Message; SubscriptionId=$SubId}
            }
        }
    })
    foreach ($region in $regions) {
        Write-Host "`n=== Quota report: $($region.DisplayName) ===" -ForegroundColor Cyan
        Show-CheckTable -Rows @($results | Where-Object RegionCode -eq $region.Name | Sort-Object Service,Quota) -Columns @('Status','Service','Quota','Used','Limit','Remaining','Percent','Unit')
    }
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
    param([string]$SubId)
    $regions = @(Select-AzureRegions $SubId)
    $targetScope = "/subscriptions/$SubId"
    $group = (Read-Host 'Existing resource group name (Enter for subscription scope only)').Trim()
    if ($group) {
        Assert-Subscription $SubId
        $rg = Invoke-AzJson @('group','show','--name',$group,'--subscription',$SubId)
        if (-not $rg.id) { throw 'Resource group could not be identified.' }
        $targetScope = $rg.id
    }
    $targetType = (Read-Host 'Resource type (e.g. Microsoft.Storage/storageAccounts; Enter for location only)').Trim()
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
    param([string]$SubId, [object[]]$Catalog)

    $chosenRegions = @(Select-AzureRegions $SubId)

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

$previousSubId = $null
$restoreSubscription = $false

try {
    Write-Host 'AZURE RESOURCE AVAILABILITY CHECKER v3.2.1' -ForegroundColor Cyan
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
    $lastReportType = 'availability'
    $action = 'N'
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
        } elseif ($action -in @('K','U','P')) {
            try {
                $newResults = if ($action -eq 'K') { @(Invoke-SkuCheck -SubId $subId) } elseif ($action -eq 'U') { @(Invoke-QuotaCheck -SubId $subId) } else { @(Invoke-PolicyCheck -SubId $subId) }
                if (@($newResults | Where-Object { $_.Status -notin @('ERROR','NO_DATA') }).Count -gt 0) {
                    $lastResults = @($newResults)
                    $lastReportType = if ($action -eq 'K') { 'sku' } elseif ($action -eq 'U') { 'quota' } else { 'policy' }
                } else { Write-Host 'No usable new report; previous report retained.' -ForegroundColor Yellow }
            } catch [System.OperationCanceledException] { throw } catch {
                Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
            }
        } elseif ($action -eq 'E') {
            if ($lastResults.Count -eq 0) {
                Write-Host 'No successful report to export. Run a check first.' -ForegroundColor Yellow
            } else {
                try {
                    $path = Join-Path (Get-Location).Path ('azure-availability-{0}-{1}.csv' -f $lastReportType,(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
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
        Write-Host '[K] Check SKU availability'
        Write-Host '[U] Check quota and usage'
        Write-Host '[P] Check Azure Policy assignments'
        if ($lastResults.Count -gt 0) {
            $reportRegions = @($lastResults | Select-Object -ExpandProperty Region -Unique) -join ', '
            Write-Host "[E] Export last successful report to CSV ($lastReportType; $($lastResults.Count) rows; $reportRegions)"
        } else {
            Write-Host '[E] Export last report (no report available)' -ForegroundColor DarkGray
        }
        Write-Host '[Q] Quit'
        do {
            $action = (Read-Host 'Select action [Enter for new check]').Trim().ToUpperInvariant()
            if ($action -eq '') { $action = 'N' }
            if ($action -notin @('N','K','U','P','E','Q')) { Write-Host 'Invalid selection. Try again.' -ForegroundColor Yellow }
        } until ($action -in @('N','K','U','P','E','Q'))
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
