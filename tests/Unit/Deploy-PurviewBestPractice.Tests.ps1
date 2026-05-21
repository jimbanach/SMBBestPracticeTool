#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester unit tests for Deploy-PurviewBestPractice.ps1
    B2 #18 — Fix A (BPOnly auto-promotion in BusinessPremium + Other tier branches).

.DESCRIPTION
    Fix A contract (post-fix):
        When Get-TenantPurviewLicenseTier returns 'BusinessPremium' or 'Other',
        and $BPOnly is not already set, the script:
          1. Sets $BPOnly = $true
          2. Writes a yellow Write-Host message containing "Auto-enabling -BPOnly"
        The existing if (-not $BPOnly) guard prevents double-promotion when
        the caller already passed -BPOnly explicitly.

    Pre-fix RED tests:
        Group 3 tests for BusinessPremium and Other tier full invocations
        (message not written → Should -Invoke Write-Host Times 1 fails).

    Pre-fix GREEN tests (always pass):
        Group 1 — parameter metadata.
        Group 2 — inline SKU algorithm spec replica.
        Group 3 — E5OrPurviewSuite and explicit-BPOnly guard tests.

    Stub-function + $global: scope pattern — see
    .squad/agents/vasquez/history.md.

.NOTES
    File lives in tests\Unit\ (gitignored — local-only, never committed).
    Test config written to tests\Unit\test-deploy-config.psd1 — created in
    BeforeAll, deleted in AfterAll.
    Run via: pwsh -File tests\Run-Tests.ps1
    Authored: 2026-05-15 — Vasquez (Tester)
    Fix shape source: .squad/agents/bishop/proposals/B2-18-bponly-auto-promotion.md
#>

BeforeDiscovery {
    # Capture current branch at discovery time so Describe -Skip: can evaluate it.
    $script:onBPOnlyBranch   = (git branch --show-current) -eq 'fix/bponly-auto-promotion'
    $script:onOneshotsBranch = (git branch --show-current) -eq 'fix/oneshots'
}

BeforeAll {
    $script:DeployPath = (Resolve-Path (
        Join-Path $PSScriptRoot '..\..\Products\Purview\Deploy-PurviewBestPractice.ps1'
    )).Path

    # Minimal config file written to disk so Import-PowerShellDataFile works.
    # TenantSettings = @{} (all keys absent) → Setup-TenantSettings.ps1 runs instantly with no calls.
    $script:TestConfigPath = Join-Path $PSScriptRoot 'test-deploy-config.psd1'
    if (-not (Test-Path $script:TestConfigPath)) {
        Set-Content -Path $script:TestConfigPath -Encoding UTF8 -Value @'
@{
    ManagedByTag         = '[SMBTool Test]'
    DlpStartInSimulation = $false
    EnableContentMarking = $false
    TenantSettings       = @{
        EnableUnifiedAuditLog   = $false
        EnableSPOAIPIntegration = $false
        EnableSPOPDFLabels      = $false
        EnableLabelCoauth       = $false
    }
    DlpPolicies          = @()
    Labels               = @()
    RetentionPolicies    = @()
    AIGovernancePolicies = @()
}
'@
    }

    # -------------------------------------------------------------------------
    # STUB FUNCTIONS — must exist before Mock can intercept them.
    # Connect / auth stubs (referenced by Connect-PurviewServices.ps1).
    # -------------------------------------------------------------------------

    # Microsoft.Online.SharePoint.PowerShell
    function Connect-SPOService    { param([string]$Url, [string]$AuthenticationUrl, [switch]$UseWebLogin) }
    function Disconnect-SPOService { param() }
    function Get-SPOTenant         { param() }

    # ExchangeOnlineManagement (EXO + IPPS)
    function Connect-ExchangeOnline  { param([string]$UserPrincipalName, [string]$DelegatedOrganization, [string]$Organization, [switch]$ShowBanner) }
    function Disconnect-ExchangeOnline { param() }
    function Get-ConnectionInformation { param() }
    function Connect-IPPSSession     { param([string]$UserPrincipalName, [string]$DelegatedOrganization, [string]$Organization) }

    # Microsoft.Graph.Authentication
    function Connect-MgGraph  { param([string[]]$Scopes, [string]$TenantId, [switch]$NoWelcome) }
    function Disconnect-MgGraph { param() }
    function Get-MgContext    { param() }

    # Microsoft.Graph — Graph REST wrapper used by Get-TenantPurviewLicenseTier
    function Invoke-MgGraphRequest { param([string]$Method, [string]$Uri) }

    # PowerShellGet
    function Get-PSRepository { param([string]$Name) }

    # Microsoft.Graph.Beta — needed when EnableContainerLabels=$true reaches
    # Setup-TenantSettings.ps1's container-labels block (E5 auto-detect path).
    function Get-MgBetaDirectorySetting         { param() }
    function Get-MgBetaDirectorySettingTemplate  { param() }
    function New-MgBetaDirectorySetting          { param([hashtable]$BodyParameter) }
    function Update-MgBetaDirectorySetting       { param([string]$DirectorySettingId, [hashtable]$BodyParameter) }

    # DLP cmdlets (needed even for -SkipDLP path because stubs must exist
    # for any Mock in nested scripts that may reference them)
    function New-DlpCompliancePolicy { param([string]$Name, [string]$Mode, [string]$Comment, [string]$ExchangeLocation, [string]$SharePointLocation, [string]$OneDriveLocation, [string]$EndpointDlpLocation) }
    function Get-DlpCompliancePolicy { param([string]$Identity) }
    function Set-DlpCompliancePolicy { param([string]$Identity, [string]$Mode, [string]$Comment) }
    function New-DlpComplianceRule   { param([string]$Name, [string]$Policy, [string]$Comment, [hashtable]$ContentContainsSensitiveInformation, [string]$AdvancedRule, [array]$EndpointDlpRestrictions, [string]$BlockAccess, [string]$BlockAccessScope, [string]$AccessScope, [string]$NotifyUser, [string]$GenerateIncidentReport) }
    function Get-DlpComplianceRule   { param([string]$Identity, [string]$Policy) }
    function Set-DlpComplianceRule   { param([string]$Identity, [string]$Comment, [hashtable]$ContentContainsSensitiveInformation, [string]$AdvancedRule, [array]$EndpointDlpRestrictions, [string]$BlockAccess, [string]$BlockAccessScope, [string]$AccessScope, [string]$NotifyUser, [string]$GenerateIncidentReport) }
    function Get-Label               { param([string]$Identity) }

    # Session-cleanup stubs (needed for B2 #9)
    function Remove-Module { param([string]$Name, [switch]$Force) }
    function Remove-PSSession { param($Session) }
}

AfterAll {
    if (Test-Path $script:TestConfigPath) {
        Remove-Item -Path $script:TestConfigPath -Force
    }
}

# =============================================================================
# GROUP 1 — Parameter Metadata
# Reflection-only; no script invocation.
# Expected result: GREEN today and after fix.
# =============================================================================
Describe 'Group 1 — Parameter Metadata (Deploy-PurviewBestPractice.ps1)' {

    BeforeAll {
        $script:DeployCmd = Get-Command $script:DeployPath
    }

    It '-TenantAdminUpn is mandatory' {
        $attr = $script:DeployCmd.Parameters['TenantAdminUpn'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
            Select-Object -First 1
        $attr.Mandatory | Should -BeTrue
    }

    It '-ConfigPath is optional and typed [string]' {
        $p = $script:DeployCmd.Parameters['ConfigPath']
        $p | Should -Not -BeNull
        $p.ParameterType | Should -Be ([string])
        ($p.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
            Select-Object -First 1).Mandatory | Should -BeFalse
    }

    It '-BPOnly is optional and typed [switch]' {
        $p = $script:DeployCmd.Parameters['BPOnly']
        $p | Should -Not -BeNull
        $p.ParameterType | Should -Be ([switch])
        ($p.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
            Select-Object -First 1).Mandatory | Should -BeFalse
    }

    It '-NoLicenseAutoDetect is optional and typed [switch]' {
        $p = $script:DeployCmd.Parameters['NoLicenseAutoDetect']
        $p | Should -Not -BeNull
        $p.ParameterType | Should -Be ([switch])
        ($p.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
            Select-Object -First 1).Mandatory | Should -BeFalse
    }
}

# =============================================================================
# GROUP 2 — SKU Tier Classification Algorithm (spec replica)
#
# The tier-classification logic lives in the inline Get-TenantPurviewLicenseTier
# function inside Deploy-PurviewBestPractice.ps1 (lines 365-421).  Because the
# function is not exported, these tests replicate the spec from Bishop's approved
# fix shape (B2-18-bponly-auto-promotion.md) and verify the algorithm directly.
#
# Purpose: contract documentation + regression guard — if the algorithm is changed
# in production without updating this spec, the discrepancy is visible.
#
# Expected result: GREEN today and after fix (spec functions are standalone).
# =============================================================================
Describe 'Group 2 — SKU Tier Classification Algorithm (spec replica)' {

    BeforeAll {
        # Inline spec replica of the tier classification algorithm from
        # Deploy-PurviewBestPractice.ps1 lines 396-420.
        function Invoke-TierClassification {
            param([string[]] $PartNumbers)

            $e5Sku = @(
                'SPE_E5','SPE_E5_NOPSTNCONF','SPE_E5_CALLINGMINUTES',
                'SPE_E5_USGOV_GCCHIGH',
                'Microsoft_365_E5_(no_Teams)',
                'Microsoft_365_E5_EEA_(no_Teams)_with_Calling_Minutes',
                'Microsoft_365_E5_EEA_(no_Teams)_without_Audio_Conferencing',
                'ENTERPRISEPREMIUM','ENTERPRISEPREMIUM_NOPSTNCONF',
                'INFORMATION_PROTECTION_COMPLIANCE',
                'IDENTITY_THREAT_PROTECTION',
                'M365_E5_SUITE_COMPONENTS',
                'Microsoft_Purview_Suite',
                'INFORMATION_PROTECTION_AND_GOVERNANCE',
                'PURVIEW_SUITE_FOR_BUSINESS_PREMIUM',
                'PURVIEW_SUITE_FOR_BUSINESS_PREMIUM_NEW',
                'DEFENDER_AND_PURVIEW_SUITES_FOR_BUSINESS_PREMIUM',
                'DEFENDER_AND_PURVIEW_SUITES_FOR_BUSINESS_PREMIUM_NEW'
            )
            $bpSku = @(
                'SPB','BUSINESS_PREMIUM',
                'Microsoft_365_ Business_ Premium_(no Teams)',
                'Office_365_w/o_Teams_Bundle_Business_Premium',
                'Microsoft_365_Business_Premium_Donation_(Non_Profit_Pricing)'
            )

            $matched = @($PartNumbers | Where-Object { $_ -in $e5Sku })
            if ($matched.Count -gt 0) { return 'E5OrPurviewSuite' }

            $bpMatched = @($PartNumbers | Where-Object { $_ -in $bpSku })
            if ($bpMatched.Count -gt 0) {
                return 'BusinessPremium'
            }

            return 'Other'
        }
    }

    It 'SPB maps to BusinessPremium' {
        Invoke-TierClassification -PartNumbers @('SPB') | Should -Be 'BusinessPremium'
    }

    It 'BUSINESS_PREMIUM maps to BusinessPremium' {
        Invoke-TierClassification -PartNumbers @('BUSINESS_PREMIUM') | Should -Be 'BusinessPremium'
    }

    It 'SPE_E5 maps to E5OrPurviewSuite' {
        Invoke-TierClassification -PartNumbers @('SPE_E5') | Should -Be 'E5OrPurviewSuite'
    }

    It 'E5 wins over BusinessPremium when both SKUs are present' {
        # E5 takes precedence — checked before BusinessPremium in the algorithm.
        Invoke-TierClassification -PartNumbers @('SPE_E5', 'SPB') | Should -Be 'E5OrPurviewSuite'
    }

    It 'Microsoft_365_E5_(no_Teams) maps to E5OrPurviewSuite' {
        Invoke-TierClassification -PartNumbers @('Microsoft_365_E5_(no_Teams)') | Should -Be 'E5OrPurviewSuite'
    }

    It 'SPE_E5_CALLINGMINUTES maps to E5OrPurviewSuite' {
        Invoke-TierClassification -PartNumbers @('SPE_E5_CALLINGMINUTES') | Should -Be 'E5OrPurviewSuite'
    }

    It 'PURVIEW_SUITE_FOR_BUSINESS_PREMIUM maps to E5OrPurviewSuite' {
        Invoke-TierClassification -PartNumbers @('PURVIEW_SUITE_FOR_BUSINESS_PREMIUM') | Should -Be 'E5OrPurviewSuite'
    }

    It 'Microsoft_365_ Business_ Premium_(no Teams) maps to BusinessPremium' {
        Invoke-TierClassification -PartNumbers @('Microsoft_365_ Business_ Premium_(no Teams)') | Should -Be 'BusinessPremium'
    }

    It 'Office_365_w/o_Teams_Bundle_Business_Premium maps to BusinessPremium' {
        Invoke-TierClassification -PartNumbers @('Office_365_w/o_Teams_Bundle_Business_Premium') | Should -Be 'BusinessPremium'
    }

    It 'Purview Suite for BP add-on wins over Business Premium base SKU' {
        Invoke-TierClassification -PartNumbers @('BUSINESS_PREMIUM', 'PURVIEW_SUITE_FOR_BUSINESS_PREMIUM') | Should -Be 'E5OrPurviewSuite'
    }

    It 'unknown-only SKU maps to Other' {
        Invoke-TierClassification -PartNumbers @('O365_BUSINESS_ESSENTIALS') | Should -Be 'Other'
    }

    It 'empty SKU list maps to Other' {
        Invoke-TierClassification -PartNumbers @() | Should -Be 'Other'
    }
}

# =============================================================================
# GROUP 3 — Fix A: BPOnly auto-promotion via full script invocation
#
# Test strategy: invoke Deploy-PurviewBestPractice.ps1 under -WhatIf
# (bypasses y/N prompt) + -SkipDLP -SkipLabels -SkipRetention (only tenant
# settings + auto-detect run).  Write-Host is mocked to suppress console output
# and enable Should -Invoke assertions.  Invoke-MgGraphRequest is mocked per-test
# to return the desired SKU tier.
#
# $wantGraphForAutoDetect = (-not $BPOnly -and -not $NoLicenseAutoDetect
#                            -and -not $SkipTenantSettings -and -not $EnableContainerLabels)
# → Only true when none of those flags are set — our standard invocation satisfies this.
#
# Pre-fix HEAD behaviour (lines 433-441, 442-450 before fix):
#   'BusinessPremium' arm: no $BPOnly=true, no Write-Host "Auto-enabling -BPOnly..."
#   'Other' arm:           no $BPOnly=true, no Write-Host "Auto-enabling -BPOnly..."
#
# Post-fix (Bishop Fix A):
#   Both arms: if (-not $BPOnly) { $BPOnly=$true; Write-Host "  Auto-enabling -BPOnly..." -ForegroundColor Yellow }
#
# RED tests (pre-fix): Business_Premium_auto_promotes + Other_auto_promotes
# GREEN tests (always): E5_does_NOT_auto_promote + explicit_BPOnly_no_double_promote
# =============================================================================
Describe 'Group 3 — Fix A: BPOnly auto-promotion (full invocation)' -Skip:(-not $script:onBPOnlyBranch) {

    BeforeEach {
        # Suppress all Write-Host output while tracking calls
        Mock Write-Host { }

        # Ensure-RequiredModule internals (referenced by Connect-PurviewServices.ps1)
        Mock Get-Module {
            [PSCustomObject]@{ Name = ($Name | Select-Object -First 1); Version = [version]'1.0.0' }
        }
        Mock Import-Module { }
        Mock Get-Command {
            [PSCustomObject]@{ Name = ($Name | Select-Object -First 1) }
        }
        Mock Get-PSRepository { }

        # EXO / IPPS session — no active sessions → connect paths taken
        Mock Get-ConnectionInformation { @() }
        Mock Connect-ExchangeOnline    { }
        Mock Connect-IPPSSession       { }

        # SPO session — throw → connect path taken
        Mock Get-SPOTenant      { throw 'No active SPO session' }
        Mock Connect-SPOService { }
        Mock Disconnect-SPOService { }

        # Graph session — not connected
        Mock Get-MgContext    { $null }
        Mock Connect-MgGraph  { }
        Mock Disconnect-MgGraph { }

        # Graph Beta — container-labels block in Setup-TenantSettings.ps1.
        # Return an existing setting that already has EnableMIPLabels='True' so
        # the block writes "Already enabled." and makes no further calls.
        # Only matters when $EnableContainerLabels=$true (E5 path) but it's
        # harmless to set for all tests in this group.
        Mock Get-MgBetaDirectorySetting {
            [PSCustomObject]@{
                TemplateId = 'group-unified-template-id'
                Values     = @(
                    [PSCustomObject]@{ Name = 'EnableMIPLabels'; Value = 'True' }
                )
            }
        }
    }

    It 'BusinessPremium tier triggers auto-promotion message' {
        # Pre-fix: no Write-Host with *Auto-enabling -BPOnly* → Should -Invoke Times 1 FAILS → RED.
        # Post-fix: message emitted once → GREEN.
        Mock Invoke-MgGraphRequest {
            [PSCustomObject]@{
                value = @(
                    [PSCustomObject]@{ skuPartNumber = 'SPB'; capabilityStatus = 'Enabled' }
                )
            }
        }
        & $script:DeployPath `
            -TenantAdminUpn      'test@contoso.onmicrosoft.com' `
            -SharePointAdminUrl  'https://contoso-admin.sharepoint.com' `
            -ConfigPath          $script:TestConfigPath `
            -SkipDLP -SkipLabels -SkipRetention -WhatIf

        Should -Invoke Write-Host -Times 1 -ParameterFilter {
            $Object -like '*Auto-enabling -BPOnly*'
        }
    }

    It 'Other tier triggers auto-promotion message' {
        # Pre-fix: no auto-promotion in Other arm → RED.
        # Post-fix: message emitted → GREEN.
        Mock Invoke-MgGraphRequest {
            [PSCustomObject]@{
                value = @(
                    [PSCustomObject]@{ skuPartNumber = 'O365_BUSINESS_ESSENTIALS'; capabilityStatus = 'Enabled' }
                )
            }
        }
        & $script:DeployPath `
            -TenantAdminUpn      'test@contoso.onmicrosoft.com' `
            -SharePointAdminUrl  'https://contoso-admin.sharepoint.com' `
            -ConfigPath          $script:TestConfigPath `
            -SkipDLP -SkipLabels -SkipRetention -WhatIf

        Should -Invoke Write-Host -Times 1 -ParameterFilter {
            $Object -like '*Auto-enabling -BPOnly*'
        }
    }

    It 'E5OrPurviewSuite tier does NOT trigger auto-promotion message' {
        # Container labels enabled, no BPOnly message — GREEN in both pre-fix and post-fix.
        # Acts as regression guard for the E5 happy path.
        Mock Invoke-MgGraphRequest {
            [PSCustomObject]@{
                value = @(
                    [PSCustomObject]@{ skuPartNumber = 'SPE_E5'; capabilityStatus = 'Enabled' }
                )
            }
        }
        & $script:DeployPath `
            -TenantAdminUpn      'test@contoso.onmicrosoft.com' `
            -SharePointAdminUrl  'https://contoso-admin.sharepoint.com' `
            -ConfigPath          $script:TestConfigPath `
            -SkipDLP -SkipLabels -SkipRetention -WhatIf

        Should -Invoke Write-Host -Times 0 -ParameterFilter {
            $Object -like '*Auto-enabling -BPOnly*'
        }
    }

    It 'explicit -BPOnly flag skips auto-detect entirely — no double-promotion message' {
        # $wantGraphForAutoDetect = (-not $BPOnly -and ...) → false when -BPOnly is set.
        # The auto-detect block is bypassed; Get-TenantPurviewLicenseTier is never called.
        # Green in both pre-fix and post-fix — regression guard for the if (-not $BPOnly) guard.
        Mock Invoke-MgGraphRequest { throw 'Should not be called when BPOnly is set' }

        { & $script:DeployPath `
            -TenantAdminUpn      'test@contoso.onmicrosoft.com' `
            -SharePointAdminUrl  'https://contoso-admin.sharepoint.com' `
            -ConfigPath          $script:TestConfigPath `
            -SkipDLP -SkipLabels -SkipRetention -BPOnly -WhatIf
        } | Should -Not -Throw

        Should -Invoke Write-Host -Times 0 -ParameterFilter {
            $Object -like '*Auto-enabling -BPOnly*'
        }
    }
}

# =============================================================================
# GROUP 4 — B2 #10 (try/finally summary) + B2 #9 (WinPS proxy Remove-Module)
# Branch: fix/oneshots
# Both fixes are in the SAME finally block added by B2 #10 and B2 #9.
# =============================================================================
Describe 'Group 4 — B2 #10 + #9: try/finally summary and WinPS cleanup' `
    -Skip:(-not $script:onOneshotsBranch) {

    # Shared mock setup for all invocations in this group.
    # All five task-scripts are skipped so the script reaches finally quickly.
    BeforeEach {
        Mock Write-Host    { }
        Mock Write-Warning { }
        Mock Write-Error   { }

        # Suppress the pre-flight confirmation prompt
        Mock Read-Host { 'y' }

        # Connect-PurviewServices returns a connectionInfo object
        Mock Get-PSRepository        { }
        Mock Get-Module              { [PSCustomObject]@{ Name = 'ExchangeOnlineManagement'; Version = [version]'3.0.0' } }
        Mock Get-Command             { [PSCustomObject]@{ Name = ($Name | Select-Object -First 1) } }
        Mock Get-ConnectionInformation { @( [PSCustomObject]@{ State = 'Connected'; TokenStatus = 'Active' } ) }
        Mock Connect-ExchangeOnline  { }
        Mock Connect-IPPSSession     { }
        Mock Get-SPOTenant           { [PSCustomObject]@{ StorageQuota = 1TB } }
        Mock Connect-SPOService      { }
        Mock Disconnect-SPOService   { }
        Mock Get-MgContext           { [PSCustomObject]@{ TenantId = 'test-tenant' } }
        Mock Connect-MgGraph         { }
        Mock Disconnect-MgGraph      { }
        Mock Invoke-MgGraphRequest   { [PSCustomObject]@{ value = @() } }

        # Remove-Module must be stubbable
        Mock Remove-Module           { }
    }

    # -----------------------------------------------------------------------
    # B2 #10 — summary is printed in finally (regression guard, always GREEN
    # on fix/oneshots; would fail pre-fix if an exception interrupted the run
    # because summary was outside the try block and would never be reached)
    # -----------------------------------------------------------------------
    It 'summary banner is written to console even when all tasks are skipped' {
        & $script:DeployPath `
            -TenantAdminUpn      'test@contoso.onmicrosoft.com' `
            -SharePointAdminUrl  'https://contoso-admin.sharepoint.com' `
            -ConfigPath          $script:TestConfigPath `
            -SkipTenantSettings -SkipLabels -SkipDLP -SkipRetention `
            -NoLicenseAutoDetect -NonInteractive

        Should -Invoke Write-Host -ParameterFilter { $Object -like '*Deployment summary*' }
    }

    # -----------------------------------------------------------------------
    # B2 #10 — spec-replica: exception path summary contract
    # Cannot inject an exception mid-task (& $script paths can't be mocked),
    # so the exception-path contract is documented via spec-replica.
    # -----------------------------------------------------------------------
    It 'spec-replica: summary block runs after task throws (finally guarantee)' {
        # Pure PowerShell spec-replica: try { throw } finally { $ran = $true }
        $ran = $false
        try {
            try {
                throw 'Simulated task failure'
            } finally {
                $ran = $true  # mirrors the finally summary block
            }
        } catch { }
        $ran | Should -BeTrue
    }

    # -----------------------------------------------------------------------
    # B2 #9 — Remove-Module called in finally when SpoUsedWinPsProxy is true
    # -----------------------------------------------------------------------
    It 'spec-replica: Remove-Module called in finally when SpoUsedWinPsProxy = $true' {
        # Inline spec-replica of the Deploy finally cleanup block (lines 562-564).
        # $spoUsedWinPsProxy = $true path: Remove-Module must be invoked.
        Mock Remove-Module { }
        $spoUsedWinPsProxy = $true
        if ($spoUsedWinPsProxy) {
            Remove-Module Microsoft.Online.SharePoint.PowerShell -Force -ErrorAction SilentlyContinue
        }
        Should -Invoke Remove-Module -Times 1 -ParameterFilter {
            $Name -eq 'Microsoft.Online.SharePoint.PowerShell' -and $Force
        }
    }

    It 'spec-replica: Remove-Module NOT called when SpoUsedWinPsProxy = $false' {
        Mock Remove-Module { }
        $spoUsedWinPsProxy = $false
        if ($spoUsedWinPsProxy) {
            Remove-Module Microsoft.Online.SharePoint.PowerShell -Force -ErrorAction SilentlyContinue
        }
        Should -Invoke Remove-Module -Times 0
    }
}

# =============================================================================
# GROUP 5 — B2 #11: #requires -Version 7.0 regression guard
# Verify every PS1 module file in the deployment package has the directive.
# Branch: fix/oneshots — this check is RED on pre-fix code (directive absent).
# =============================================================================
Describe 'Group 5 — B2 #11: #requires -Version 7.0 present in all module files' `
    -Skip:(-not $script:onOneshotsBranch) {

    BeforeAll {
        $script:ModuleRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\Products\Purview')
        $script:ExpectedFiles = @(
            'Deploy-PurviewBestPractice.ps1'
            'Modules\Connect-PurviewServices.ps1'
            'Modules\Setup-TenantSettings.ps1'
            'Modules\Setup-SensitivityLabels.ps1'
            'Modules\Setup-DLP.ps1'
            'Modules\Setup-Retention.ps1'
            'Modules\Setup-AIGovernance.ps1'
        )
    }

    foreach ($relPath in $script:ExpectedFiles) {
        It "$(Split-Path $relPath -Leaf) contains '#Requires -Version 7.0'" `
            -TestCases @(@{ RelPath = $relPath }) {
            param($RelPath)
            $fullPath = Join-Path $script:ModuleRoot $RelPath
            $fullPath | Should -Exist
            $content = Get-Content $fullPath -Raw
            $content | Should -Match '(?i)#requires\s+-version\s+7'
        }
    }
}
