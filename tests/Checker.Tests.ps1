BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'Azure-Resource-Availability-Checker.ps1')
    $region = [pscustomobject]@{ Name='westeurope'; DisplayName='West Europe'; RegionalDisplayName='(Europe) West Europe' }
    $sub = '00000000-0000-0000-0000-000000000001'
}

Describe 'Location normalization and menu selection' {
    It 'normalizes a numbered region' {
        Normalize-Location 'East US 2' | Should -Be 'eastus2'
    }
    It 'selects all choices' {
        Mock Read-Host { '0' }
        $items = @([pscustomobject]@{Name='East US'},[pscustomobject]@{Name='East US 2'})
        @(Select-Menu -Title 'Regions' -Items $items -Multiple).Count | Should -Be 2
    }
    It 'deduplicates selected indices' {
        Mock Read-Host { '2,2,1' }
        $items = @([pscustomobject]@{Name='A'},[pscustomobject]@{Name='B'})
        $selected = @(Select-Menu -Title 'Regions' -Items $items -Multiple)
        $selected.Count | Should -Be 2
        $selected[0].Name | Should -Be 'B'
    }
    It 'cancels without querying Azure' {
        Mock Read-Host { 'Q' }
        { Select-Menu -Title 'Regions' -Items @([pscustomobject]@{Name='A'}) } | Should -Throw '*Cancelled*'
    }
}

Describe 'Regional resource availability with mocked metadata' {
    BeforeAll {
        Mock Select-AzureRegions { [pscustomobject]@{ Name='westeurope'; DisplayName='West Europe' } }
        Mock Invoke-AzJson {
            [pscustomobject]@{
                namespace='Microsoft.Example'; registrationState='NotRegistered'; resourceTypes=@(
                    [pscustomobject]@{resourceType='supported'; locations=@('West Europe')}
                    [pscustomobject]@{resourceType='other'; locations=@('East US 2')}
                    [pscustomobject]@{resourceType='global'; locations=@('global')}
                    [pscustomobject]@{resourceType='child'; locations=@()}
                )
            }
        }
        Mock Read-Host { '' }
    }
    It 'distinguishes supported, not supported, global and unknown' {
        $rows = @(Invoke-AvailabilityCheck -SubId $sub -Catalog @())
        $rows.Count | Should -Be 4
        ($rows | Where-Object ResourceType -eq 'supported').Status | Should -Be 'SUPPORTED'
        ($rows | Where-Object ResourceType -eq 'other').Status | Should -Be 'NOT_SUPPORTED'
        ($rows | Where-Object ResourceType -eq 'global').Status | Should -Be 'GLOBAL'
        ($rows | Where-Object ResourceType -eq 'child').Status | Should -Be 'UNKNOWN'
        ($rows | Where-Object ResourceType -eq 'supported').Registration | Should -Be 'NotRegistered'
        Should -Invoke Invoke-AzJson -Times 1 -Exactly -Scope It
    }
    It 'does not mistake a provider request failure for unsupported' {
        Mock Invoke-AzJson { throw 'Fake provider API failure' }
        { Invoke-AvailabilityCheck -SubId $sub -Catalog @() } | Should -Throw '*Fake provider API failure*'
    }
}

Describe 'SKU restriction classification' {
    It 'classifies regional catalog entries' {
        Get-SkuRestrictionStatus ([pscustomobject]@{locations=@('West Europe');restrictions=@()}) $region | Should -Be 'LISTED'
        Get-SkuRestrictionStatus ([pscustomobject]@{locations=@('East US 2')}) $region | Should -Be 'NOT_LISTED'
        Get-SkuRestrictionStatus ([pscustomobject]@{locations=@()}) $region | Should -Be 'UNKNOWN'
    }
    It 'detects an applicable location restriction' {
        $sku = [pscustomobject]@{locations=@('westeurope');restrictions=@([pscustomobject]@{type='Location';values=@('West Europe')})}
        Get-SkuRestrictionStatus $sku $region | Should -Be 'RESTRICTED'
    }
    It 'detects a zone restriction' {
        $sku = [pscustomobject]@{locations=@('westeurope');restrictions=@([pscustomobject]@{type='Zone';restrictionInfo=[pscustomobject]@{locations=@('westeurope')}})}
        Get-SkuRestrictionStatus $sku $region | Should -Be 'ZONE_RESTRICTED'
    }
    It 'keeps ambiguous restrictions unknown' {
        $sku = [pscustomobject]@{locations=@('westeurope');restrictions=@([pscustomobject]@{type='Location';values=@()})}
        Get-SkuRestrictionStatus $sku $region | Should -Be 'RESTRICTION_UNKNOWN'
    }
}

Describe 'Quota boundaries with mocked CLI responses' {
    BeforeEach {
        Mock Select-AzureRegions { [pscustomobject]@{Name='westeurope';DisplayName='West Europe'} }
        Mock Select-Menu { [pscustomobject]@{Name='Compute';Command=@('vm','list-usage')} }
        Mock Assert-Subscription {}
        Mock Show-CheckTable {}
    }
    It 'handles limits, missing usage and zero limit' {
        Mock Invoke-AzJson {
            foreach ($item in @(@{n='low';u=5;l=20},@{n='near';u=16;l=20},@{n='full';u=20;l=20},@{n='zero';u=0;l=0},@{n='missing';u=$null;l=20},@{n='over';u=25;l=20})) {
                [pscustomobject]@{name=[pscustomobject]@{localizedValue=$item.n};currentValue=$item.u;limit=$item.l;unit='Count'}
            }
        }
        $rows = @(Invoke-QuotaCheck -SubId $sub)
        $rows.Count | Should -Be 6
        ($rows | Where-Object Quota -eq 'low').Status | Should -Be 'HEADROOM'
        ($rows | Where-Object Quota -eq 'near').Status | Should -Be 'NEAR_LIMIT'
        ($rows | Where-Object Quota -eq 'full').Status | Should -Be 'EXHAUSTED'
        ($rows | Where-Object Quota -eq 'zero').Status | Should -Be 'EXHAUSTED'
        ($rows | Where-Object Quota -eq 'missing').Status | Should -Be 'UNKNOWN'
        ($rows | Where-Object Quota -eq 'over').Remaining | Should -Be 0
    }
    It 'reports a failed CLI query as ERROR' {
        Mock Invoke-AzJson { throw 'Fake access denied' }
        $rows = @(Invoke-QuotaCheck -SubId $sub)
        $rows.Count | Should -Be 1
        $rows[0].Status | Should -Be 'ERROR'
    }
}

Describe 'Conservative policy conditions' {
    It 'resolves location parameter lists' {
        $condition = '{"field":"location","notIn":"[parameters(''allowedLocations'')]"}' | ConvertFrom-Json
        $parameters = @{allowedLocations=@('westeurope','northeurope')}
        Test-PolicyCondition $condition $parameters 'East US 2' '' | Should -Be 'True'
        Test-PolicyCondition $condition $parameters 'West Europe' '' | Should -Be 'False'
    }
    It 'keeps an unknown alias unknown' {
        $condition = '{"field":"tags[owner]","exists":"false"}' | ConvertFrom-Json
        Test-PolicyCondition $condition @{} 'West Europe' '' | Should -Be 'Unknown'
    }
    It 'does not assume a resource type when it is unspecified' {
        $condition = '{"field":"type","equals":"Microsoft.Storage/storageAccounts"}' | ConvertFrom-Json
        Test-PolicyCondition $condition @{} 'West Europe' '' | Should -Be 'Unknown'
    }
    It 'handles false and unknown in an allOf condition' {
        $condition = '{"allOf":[{"field":"location","equals":"eastus"},{"field":"tags[owner]","exists":"true"}]}' | ConvertFrom-Json
        Test-PolicyCondition $condition @{} 'West Europe' '' | Should -Be 'False'
    }
}

Describe 'CSV export' {
    It 'exports a row without prompting and preserves its status' {
        $row = [pscustomobject]@{Region='West Europe';Status='SUPPORTED';SubscriptionId=$sub}
        $path = Export-CheckerReport -Rows @($row) -ReportType availability -Directory $TestDrive
        Test-Path -LiteralPath $path | Should -BeTrue
        $data = Import-Csv -LiteralPath $path -UseCulture
        $data.Status | Should -Be 'SUPPORTED'
        $data.SubscriptionId | Should -Be $sub
    }
    It 'refuses an empty report' {
        { Export-CheckerReport -Rows @() -ReportType quota -Directory $TestDrive } | Should -Throw '*No successful report*'
    }
}

Describe 'Native CLI launcher regression (no Azure access)' {
    BeforeAll {
        $fakeArgs = @('policy','assignment','list','--filter','atScope()','--expand','EffectiveDefinitionVersion,LatestDefinitionVersion')
        if ($env:OS -eq 'Windows_NT') {
            $fakeCli = Join-Path $TestDrive 'fake-az.cmd'
            @'
@echo off
if not "%~5"=="atScope()" exit /b 7
if not "%~6"=="--expand" exit /b 8
if 1==1 (
  echo %* > nul
)
echo {"ok":true}
exit /b 0
'@ | Set-Content -LiteralPath $fakeCli -Encoding ASCII
            $fakeError = Join-Path $TestDrive 'fake-fail.cmd'
            '@exit /b 9' | Set-Content -LiteralPath $fakeError -Encoding ASCII
            $fakeInvalid = Join-Path $TestDrive 'fake-invalid.cmd'
            '@echo not-json' | Set-Content -LiteralPath $fakeInvalid -Encoding ASCII
        } else {
            $fakeCli = Join-Path $TestDrive 'fake-az'
            $fakeError = Join-Path $TestDrive 'fake-fail'
            $fakeInvalid = Join-Path $TestDrive 'fake-invalid'
            [IO.File]::WriteAllText($fakeCli, '#!/bin/sh' + "`n" + '[ "$5" = "atScope()" ] && [ "$6" = "--expand" ] || exit 7' + "`n" + 'printf ''%s\n'' ''{"ok":true}''' + "`n")
            [IO.File]::WriteAllText($fakeError, "#!/bin/sh`nexit 9`n")
            [IO.File]::WriteAllText($fakeInvalid, "#!/bin/sh`necho not-json`n")
            & chmod +x $fakeCli $fakeError $fakeInvalid
            if ($LASTEXITCODE -ne 0) { throw 'Cannot prepare fake CLI.' }
        }
    }
    It 'passes atScope and the following expand argument through the real local launcher' {
        (Invoke-AzJson -Arguments $fakeArgs -CliPath $fakeCli).ok | Should -BeTrue
    }
    It 'throws for nonzero CLI exit codes' {
        { Invoke-AzJson -Arguments $fakeArgs -CliPath $fakeError } | Should -Throw '*Azure CLI command failed*'
    }
    It 'throws for invalid JSON' {
        { Invoke-AzJson -Arguments $fakeArgs -CliPath $fakeInvalid } | Should -Throw
    }
}


Describe 'Automation configuration and gate decisions' {
    BeforeAll {
        $good = [pscustomobject]@{Region='West Europe';Status='SUPPORTED';Registration='Registered';Provider='Microsoft.Storage';ResourceType='storageAccounts'}
        $inputOptions = @{Subscription='Example';Regions=@('westeurope');Resources=@('Microsoft.Storage/storageAccounts')}
    }
    It 'validates options without Azure or prompts' {
        $opts = Get-CheckerOptions -Bound $inputOptions
        $opts.Regions[0] | Should -Be 'westeurope'
        $opts.Resources[0] | Should -Be 'Microsoft.Storage/storageAccounts'
    }
    It 'rejects missing required values' {
        { Get-CheckerOptions -Bound @{Subscription='Example';Regions=@('westeurope')} } | Should -Throw '*required*'
    }
    It 'reads a JSON file and rejects mixing configuration with flags' {
        $file = Join-Path $TestDrive 'config.json'
        @{Subscription='Example';Regions=@('westeurope');Resources=@('Microsoft.Storage/storageAccounts');CheckQuota=$true} | ConvertTo-Json | Set-Content $file
        $opts = Get-CheckerOptions -Bound @{ConfigPath=$file}
        $opts.QuotaProviders.Count | Should -Be 4
        { Get-CheckerOptions -Bound @{ConfigPath=$file;Subscription='Other'} } | Should -Throw '*not both*'
    }
    It 'rejects invalid quota provider and incomplete SKU request' {
        { Get-CheckerOptions -Bound ($inputOptions + @{CheckQuota=$true;QuotaProviders=@('Other')}) } | Should -Throw '*Unsupported quota provider*'
        { Get-CheckerOptions -Bound ($inputOptions + @{SkuService='Virtual Machine'}) } | Should -Throw '*together*'
    }
    It 'passes supported and registered resources' {
        (Get-PreflightDecision -Availability @($good)).ExitCode | Should -Be 0
    }
    It 'blocks unregistered providers and unsupported regions' {
        (Get-PreflightDecision -Availability @([pscustomobject]@{Status='SUPPORTED';Registration='NotRegistered'})).ExitCode | Should -Be 1
        (Get-PreflightDecision -Availability @([pscustomobject]@{Status='NOT_SUPPORTED';Registration='Registered'})).ExitCode | Should -Be 1
    }
    It 'fails closed on missing or unknown metadata' {
        (Get-PreflightDecision -Availability @([pscustomobject]@{Status='UNKNOWN'})).ExitCode | Should -Be 2
        (Get-PreflightDecision -Availability @($good) -ExpectSku).ExitCode | Should -Be 2
    }
    It 'treats unrelated exhausted quota as advisory unless strict' {
        $quota = @([pscustomobject]@{Status='EXHAUSTED';Quota='Unrelated'})
        (Get-PreflightDecision -Availability @($good) -Quota $quota -ExpectQuota).ExitCode | Should -Be 0
        (Get-PreflightDecision -Availability @($good) -Quota $quota -ExpectQuota -Strict).ExitCode | Should -Be 1
    }
    It 'blocks potential policy denial and gives errors precedence' {
        $policy = @([pscustomobject]@{Status='POTENTIAL_DENY'})
        (Get-PreflightDecision -Availability @($good) -Policy $policy -ExpectPolicy).ExitCode | Should -Be 1
        (Get-PreflightDecision -Availability @($good) -Policy $policy -ExpectPolicy -ExpectSku).ExitCode | Should -Be 2
    }
    It 'resolves region display names and numbered region codes' {
        Mock Assert-Subscription {}
        Mock Invoke-AzJson { [pscustomobject]@{name='eastus2';displayName='East US 2';type='Region';metadata=[pscustomobject]@{regionType='Physical'}} }
        @(Resolve-CheckerRegions -SubId $sub -Requested @('East US 2','eastus2')).Count | Should -Be 1
        { Resolve-CheckerRegions -SubId $sub -Requested @('notaregion') } | Should -Throw '*not uniquely found*'
    }
    It 'checks explicit resources without calling Read-Host' {
        Mock Read-Host { throw 'Unexpected prompt' }
        Mock Invoke-AzJson { [pscustomobject]@{namespace='Microsoft.Storage';registrationState='Registered';resourceTypes=@([pscustomobject]@{resourceType='storageAccounts';locations=@('West Europe')})} }
        $items = @(New-Resource 'Storage' 'Microsoft.Storage' 'storageAccounts')
        $rows = @(Invoke-AvailabilityCheck -SubId $sub -Catalog @() -SelectedRegions @($region) -SelectedResources $items)
        $rows[0].Status | Should -Be 'SUPPORTED'
        Should -Invoke Read-Host -Times 0 -Exactly
    }
    It 'writes a structured JSON report without prompting' {
        Mock Read-Host { throw 'Unexpected prompt' }
        Mock Resolve-CheckerRegions { $region }
        Mock Invoke-AvailabilityCheck { $good }
        $file = Join-Path $TestDrive 'preflight.json'
        $opts = Get-CheckerOptions -Bound ($inputOptions + @{OutputJson=$file})
        Invoke-CheckerPreflight -SubId $sub -Options $opts -Catalog @() | Should -Be 0
        $data = Get-Content $file -Raw | ConvertFrom-Json
        $data.ExitCode | Should -Be 0
        $data.Availability[0].Status | Should -Be 'SUPPORTED'
        Should -Invoke Read-Host -Times 0 -Exactly
    }
}

Describe 'Extended preflight checks v3.8' {
    It 'distinguishes zone catalog entries and an absent zone' {
        $sku = [pscustomobject]@{locations=@('westeurope');locationInfo=@([pscustomobject]@{location='westeurope';zones=@('1','2')});restrictions=@()}
        Get-ZoneStatus $sku $region '1' | Should -Be 'LISTED'
        Get-ZoneStatus $sku $region '3' | Should -Be 'NOT_LISTED'
    }
    It 'handles a restriction in the specified zone only' {
        $sku = [pscustomobject]@{locations=@('westeurope');locationInfo=@([pscustomobject]@{location='westeurope';zones=@('1','2')});restrictions=@([pscustomobject]@{type='Zone';restrictionInfo=[pscustomobject]@{locations=@('westeurope');zones=@('2')}})}
        Get-ZoneStatus $sku $region '1' | Should -Be 'LISTED'
        Get-ZoneStatus $sku $region '2' | Should -Be 'RESTRICTED'
    }
    It 'keeps missing zone metadata unknown' {
        Get-ZoneStatus ([pscustomobject]@{locations=@('westeurope')}) $region '1' | Should -Be 'UNKNOWN'
    }
    It 'applies NotActions only to its own grant' {
        $permission = [pscustomobject]@{actions=@('Microsoft.Storage/*');notActions=@('Microsoft.Storage/storageAccounts/write')}
        Test-ArmActionGrant @($permission) 'Microsoft.Storage/storageAccounts/write' | Should -BeFalse
        Test-ArmActionGrant @($permission) 'Microsoft.Storage/storageAccounts/read' | Should -BeTrue
        $second = [pscustomobject]@{actions=@('Microsoft.Storage/storageAccounts/write');notActions=@()}
        Test-ArmActionGrant @($permission,$second) 'Microsoft.Storage/storageAccounts/write' | Should -BeTrue
    }
    It 'does not confuse data-plane grants with ARM actions' {
        Test-ArmActionGrant @([pscustomobject]@{actions=@();dataActions=@('*')}) 'Microsoft.Storage/storageAccounts/write' | Should -BeFalse
    }
    It 'interprets positive and negative name responses without assuming missing values' {
        Get-NameCheckStatus ([pscustomobject]@{nameAvailable=$true}) | Should -Be 'AVAILABLE'
        Get-NameCheckStatus ([pscustomobject]@{nameAvailable=$false}) | Should -Be 'UNAVAILABLE'
        Get-NameCheckStatus ([pscustomobject]@{nameAvailable='false'}) | Should -Be 'UNKNOWN'
        Get-NameCheckStatus $false -ExistsResponse | Should -Be 'NOT_FOUND'
        Get-NameCheckStatus $true -ExistsResponse | Should -Be 'UNAVAILABLE'
    }
    It 'reports name query failures as errors' {
        Mock Assert-Subscription {}
        Mock Invoke-AzJson { throw 'Fake name API failure' }
        Mock Show-CheckTable {}
        $rows = @(Invoke-NameCheck -SubId $sub -Requests @('Storage Account|examplename'))
        $rows[0].Status | Should -Be 'ERROR'
    }
    It 'compares exact quota demands and preserves missing data as unknown' {
        $quota = @([pscustomobject]@{Region='West Europe';Service='Compute (vCPU)';Quota='Total Regional vCPUs';Remaining=8;Unit='Count';Status='HEADROOM'})
        $a = @(Get-QuotaDemandRows -Quota $quota -Regions @($region) -Requests @('Compute|Total Regional vCPUs|8') -SubId $sub)
        $a[0].Status | Should -Be 'FITS'
        $b = @(Get-QuotaDemandRows -Quota $quota -Regions @($region) -Requests @('Compute|Total Regional vCPUs|9','Compute|missing|1') -SubId $sub)
        $b[0].Status | Should -Be 'INSUFFICIENT'
        $b[1].Status | Should -Be 'UNKNOWN'
    }
    It 'rejects duplicate quota demand rather than comparing each independently' {
        { Get-QuotaDemandRows -Quota @() -Regions @($region) -Requests @('Compute|vCPU|1','Compute|vCPU|2') -SubId $sub } | Should -Throw '*Duplicate*'
    }
    It 'maps extra results to conservative gate findings' {
        (Get-ExtendedFindings names @([pscustomobject]@{Status='UNAVAILABLE'})).Severity | Should -Be 'BLOCK'
        (Get-ExtendedFindings rbac @([pscustomobject]@{Status='GRANT_NOT_LISTED'})).Severity | Should -Be 'ERROR'
        (Get-ExtendedFindings rbac @([pscustomobject]@{Status='GRANT_LISTED'})).Severity | Should -Be 'WARNING'
        @(Get-ExtendedFindings demand @([pscustomobject]@{Status='FITS'})).Count | Should -Be 0
    }
    It 'supports multiple SKU requests while rejecting conflicting legacy options' {
        $opts = @{Subscription='Example';Regions=@('westeurope');Resources=@('Microsoft.Storage/storageAccounts');SkuRequests=@('Storage Account|Standard_LRS','API Management|Developer')}
        (Get-CheckerOptions -Bound $opts).SkuRequests.Count | Should -Be 2
        { Get-CheckerOptions -Bound ($opts + @{SkuService='Storage Account';SkuName='Standard_LRS'}) } | Should -Throw '*not both*'
    }
    It 'reads the API Management SKU catalog using its subscription API' {
        Mock Get-ArmList { [pscustomobject]@{name='Developer';tier='Developer';locations=@('West Europe');restrictions=@()} }
        $rows = @(Get-ExtendedSkuRows -Region $region -Service 'API Management' -SubId $sub)
        $rows[0].Status | Should -Be 'LISTED'
        Should -Invoke Get-ArmList -Times 1 -Exactly -ParameterFilter { $Url -like '*/Microsoft.ApiManagement/skus?api-version=2024-05-01' }
    }
    It 'parses AI account SKU metadata without making model claims' {
        Mock Invoke-AzJson { [pscustomobject]@{sku=[pscustomobject]@{name='S0';tier='Standard'}} }
        $rows = @(Get-ExtendedSkuRows -Region $region -Service 'Azure OpenAI' -SubId $sub)
        $rows[0].SKU | Should -Be 'S0'
        $rows[0].Status | Should -Be 'LISTED'
    }
}
