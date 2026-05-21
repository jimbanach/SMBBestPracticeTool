#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester unit tests for Setup-TenantSettings.ps1
    B2 #28 — Set-SPOTenant confirmation handling on fix/oneshots.
#>

BeforeDiscovery {
    $script:onOneshotsBranch = (git branch --show-current) -eq 'fix/oneshots'
}

BeforeAll {
    $script:SetupTenantSettingsPath = (Resolve-Path (
        Join-Path $PSScriptRoot '..\..\Products\Purview\Modules\Setup-TenantSettings.ps1'
    )).Path
    $script:SetupTenantSettingsSource = Get-Content -Path $script:SetupTenantSettingsPath -Raw

    function Get-SPOTenant {
        [CmdletBinding()]
        param()
    }

    function Set-SPOTenant {
        [CmdletBinding()]
        param(
            [bool]$EnableAIPIntegration,
            [bool]$EnableSensitivityLabelforPDF,
            [string]$WarningAction,
            [string]$ErrorAction,
            [switch]$Confirm
        )
    }

    function New-AipOnlyConfig {
        @{
            TenantSettings = @{
                EnableUnifiedAuditLog        = $false
                EnableAIPIntegrationInSPO    = $true
                EnableSensitivityLabelForPDF = $false
                EnableLabelCoAuth            = $false
            }
        }
    }

    function New-PdfOnlyConfig {
        @{
            TenantSettings = @{
                EnableUnifiedAuditLog        = $false
                EnableAIPIntegrationInSPO    = $false
                EnableSensitivityLabelForPDF = $true
                EnableLabelCoAuth            = $false
            }
        }
    }
}

Describe 'Group 4 — B2 #28 Set-SPOTenant calls do NOT pass invalid -Confirm parameter' `
    -Skip:(-not $script:onOneshotsBranch) {

    BeforeEach {
        $script:observedConfirmPreference = $null
        Mock Write-Host { }
        Mock Write-Warning { }
        Mock Start-Sleep { }
    }

    It 'AIP integration calls Set-SPOTenant without -Confirm and with EnableAIPIntegration true' {
        Mock Get-Command {
            switch ($Name) {
                'Get-SPOTenant' { [PSCustomObject]@{ Name = 'Get-SPOTenant' } }
                'Set-SPOTenant' { [PSCustomObject]@{ Name = 'Set-SPOTenant'; Parameters = @{} } }
                default { $null }
            }
        }
        Mock Get-SPOTenant { [PSCustomObject]@{ EnableAIPIntegration = $false } }
        Mock Set-SPOTenant {
            $script:observedConfirmPreference = $ConfirmPreference
        }

        { & $script:SetupTenantSettingsPath -Config (New-AipOnlyConfig) } | Should -Not -Throw

        Should -Invoke Set-SPOTenant -Times 1 -Exactly -ParameterFilter {
            $EnableAIPIntegration -eq $true -and -not $PSBoundParameters.ContainsKey('Confirm')
        }
    }

    It 'PDF labels call Set-SPOTenant without -Confirm and with EnableSensitivityLabelforPDF true' {
        Mock Get-Command {
            switch ($Name) {
                'Get-SPOTenant' { [PSCustomObject]@{ Name = 'Get-SPOTenant' } }
                'Set-SPOTenant' { [PSCustomObject]@{ Name = 'Set-SPOTenant'; Parameters = @{ EnableSensitivityLabelforPDF = $true } } }
                default { $null }
            }
        }
        Mock Get-SPOTenant { [PSCustomObject]@{ EnableSensitivityLabelforPDF = $false } }
        Mock Set-SPOTenant {
            $script:observedConfirmPreference = $ConfirmPreference
        }

        { & $script:SetupTenantSettingsPath -Config (New-PdfOnlyConfig) } | Should -Not -Throw

        Should -Invoke Set-SPOTenant -Times 1 -Exactly -ParameterFilter {
            $EnableSensitivityLabelforPDF -eq $true -and -not $PSBoundParameters.ContainsKey('Confirm')
        }
    }

    It 'source uses scoped ConfirmPreference overrides for both SharePoint Set-SPOTenant calls' {
        $script:SetupTenantSettingsSource | Should -Match '(?s)Enable AIP integration.*?\$ConfirmPreference\s*=\s*''None''.*?Set-SPOTenant\s+-EnableAIPIntegration\s+\$true'
        $script:SetupTenantSettingsSource | Should -Match '(?s)PDF sensitivity labels.*?\$ConfirmPreference\s*=\s*''None''.*?Set-SPOTenant\s+-EnableSensitivityLabelforPDF\s+\$true'
    }

    It 'regression: Setup-TenantSettings.ps1 never passes -Confirm to Set-SPOTenant' {
        $setSpoLines = $script:SetupTenantSettingsSource -split "`r?`n" | Where-Object {
            $_ -match '^\s*Set-SPOTenant\s+-Enable(AIPIntegration|SensitivityLabelforPDF)\b'
        }

        $setSpoLines.Count | Should -Be 2
        ($setSpoLines -join "`n") | Should -Not -Match '-Confirm'
    }
}
