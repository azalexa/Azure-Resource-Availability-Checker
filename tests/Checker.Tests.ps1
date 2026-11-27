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
