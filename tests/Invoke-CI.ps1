#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $root 'Azure-Resource-Availability-Checker.ps1'
$report = Join-Path $root 'TestResults.xml'
Import-Module Pester -RequiredVersion 5.7.1 -ErrorAction Stop
Import-Module PSScriptAnalyzer -RequiredVersion 1.24.0 -ErrorAction Stop

$parseFailed = $false
foreach ($file in @(Get-Item $scriptPath) + @(Get-ChildItem $PSScriptRoot -Filter '*.ps1')) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    foreach ($parseError in $errors) {
        Write-Warning "$($file.Name):$($parseError.Extent.StartLineNumber): $($parseError.Message)"
        $parseFailed = $true
    }
}
if ($parseFailed) { throw 'PowerShell syntax validation failed.' }

$issues = @(Invoke-ScriptAnalyzer -Path $scriptPath -Severity Error,Warning)
if ($issues.Count) { $issues | Format-Table RuleName,Severity,Line,Message -Wrap | Out-Host }
$analyzerFailed = @($issues | Where-Object Severity -eq 'Error').Count -gt 0

$config = New-PesterConfiguration
$config.Run.Path = $PSScriptRoot
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'
$config.TestResult.Enabled = $true
$config.TestResult.OutputPath = $report
$config.TestResult.OutputFormat = 'NUnitXml'
$result = Invoke-Pester -Configuration $config
if ($analyzerFailed -or $result.Result -ne 'Passed' -or $result.FailedCount -gt 0 -or $result.TotalCount -eq 0) { throw 'CI validation failed.' }
