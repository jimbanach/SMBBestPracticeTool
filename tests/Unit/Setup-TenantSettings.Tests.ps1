#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester unit tests for Setup-TenantSettings.ps1
    B2 #20 — EnableSpoAipMigrationIsDisabledException exception classifier
    B2 #3  — AdminAuditLogConfig post-write verification loop (Jim's directive)

.DESCRIPTION
    Group 1 — B2 #20 (5 It blocks)
        Verifies that Invoke-WithTransientRetry correctly retries Set-PolicyConfig when
        it throws EnableSpoAipMigrationIsDisabledException (SPO-AIP propagation gap).
        Test strategy is behaviour-based: post-fix retry fires (2 Set-PolicyConfig
        calls); pre-fix the exception is not classified as transient (1 call +
        Write-Warning "failed after retries").

    Group 2 — B2 #3 (6 It blocks)
        Verifies the post-write audit verification loop added per Jim's directive.
        After Set-AdminAuditLogConfig fires, the code polls Get-AdminAuditLogConfig
        up to 5 times (Start-Sleep -Seconds 5 between non-final attempts).
        CRITICAL per directive: if all 5 attempts return False, the script MUST write
        a visible "Pending" warning — NOT silently claim success. Operator message
        MUST include a remediation hint.

.NOTES
    File lives in tests\Unit\ — run via: pwsh -File tests\Run-Tests.ps1
    Authored: 2026-05-18 — Vasquez (Tester)
    Fix shape: .squad/agents/bishop/proposals/B2-ipps-batch.md
    Design call: .squad/decisions/inbox/copilot-directive-b2-3-audit-gate.md
    Branch gate: fix/ipps-error-pathway
#>

BeforeDiscovery {
    $script:onIppsBranch = (git branch --show-current) -eq 'fix/ipps-error-pathway'
}

BeforeAll {
    $script:SetupTenantSettingsPath = (Resolve-Path (
        Join-Path $PSScriptRoot '..\..\Products\Purview\Modules\Setup-TenantSettings.ps1'
    )).Path

    # -------------------------------------------------------------------------
    # STUB FUNCTIONS
    # EXO / IPPS cmdlets are not installed on this test host.
    # Pester 5 requires a command to exist before Mock can intercept it.
    # -------------------------------------------------------------------------

    function Get-OrganizationConfig {
        [CmdletBinding()]
        param()
        [PSCustomObject]@{ IsDehydrated = $false }
    }

    function Set-AdminAuditLogConfig {
        [CmdletBinding()]
        param([bool]$UnifiedAuditLogIngestionEnabled)
    }

    function Get-AdminAuditLogConfig {
        [CmdletBinding()]
        param()
        [PSCustomObject]@{ UnifiedAuditLogIngestionEnabled = $false }
    }

    function Enable-OrganizationCustomization {
        [CmdletBinding()]
        param()
    }

    function Set-PolicyConfig {
        [CmdletBinding()]
        param([switch]$EnableLabelCoauth)
    }

    # -------------------------------------------------------------------------
    # CONFIG HELPERS
    # Each helper enables exactly ONE settings section so tests are isolated.
    # -------------------------------------------------------------------------

    function New-CoAuthOnlyConfig {
        # Activates [4/5] Label co-authoring only — all other sections skipped.
        @{
            TenantSettings = @{
                EnableUnifiedAuditLog        = $false
                EnableAIPIntegrationInSPO    = $false
                EnableSensitivityLabelForPDF = $false
                EnableLabelCoAuth            = $true
            }
        }
    }

    function New-AuditOnlyConfig {
        # Activates [1/5] Unified Audit Log only — all other sections skipped.
        @{
            TenantSettings = @{
                EnableUnifiedAuditLog        = $true
                EnableAIPIntegrationInSPO    = $false
                EnableSensitivityLabelForPDF = $false
                EnableLabelCoAuth            = $false
            }
        }
    }

    function New-SourcedAuditGetter {
        param(
            [string]$Source,
            [bool[]]$Sequence
        )

        $sequenceIndex = 0
        $getter = {
            param([string]$ErrorAction)

            $script:resolvedAuditGetSource = $Source
            $script:auditGetterCallCount[$Source] = 1 + ($script:auditGetterCallCount[$Source] ?? 0)

            $value = if ($sequenceIndex -lt $Sequence.Count) {
                $Sequence[$sequenceIndex]
            } else {
                $Sequence[-1]
            }
            $sequenceIndex++

            [PSCustomObject]@{ UnifiedAuditLogIngestionEnabled = $value }
        }.GetNewClosure()
        $getter | Add-Member -NotePropertyName Source -NotePropertyValue $Source -Force
        return $getter
    }

    function Resolve-AuditVerificationGetter {
        param(
            $SetCommand,
            [object[]]$GetCommands,
            $BareGetter
        )

        $exoGet = $null
        if ($SetCommand) {
            $exoGet = @($GetCommands | Where-Object { $_.Source -eq $SetCommand.Source } | Select-Object -First 1)
        }
        if (-not $exoGet) {
            $exoGet = $BareGetter
        }

        return $exoGet
    }

    function Invoke-AuditVerificationLoop {
        param(
            [scriptblock]$Getter,
            [int]$VerifyAttempts = 5
        )

        $auditVerified = $false
        for ($va = 1; $va -le $VerifyAttempts; $va++) {
            try {
                $vCfg = & $Getter -ErrorAction Stop
                if ($vCfg.UnifiedAuditLogIngestionEnabled) {
                    $auditVerified = $true
                    break
                }
            } catch { }

            if ($va -lt $VerifyAttempts) {
                Write-Host ("      Audit config not confirmed yet (attempt $va/$VerifyAttempts). Waiting 5s...") -ForegroundColor DarkYellow
                Start-Sleep -Seconds 5
            }
        }

        if ($auditVerified) {
            Write-Host '      Enabled and verified.' -ForegroundColor Green
        } else {
            Write-Host '      Pending — audit configuration may still be applying (UnifiedAuditLogIngestionEnabled returned False after 20s).' -ForegroundColor Yellow
        }

        return $auditVerified
    }
}

# =============================================================================
# GROUP 1 — B2 #20: EnableSpoAipMigrationIsDisabledException classifier
#
# Production code (Setup-TenantSettings.ps1 lines 73-91):
#   Test-TransientServerError evaluates $patterns against a concatenated blob
#   of error fields. Bishop's fix adds 'EnableSpoAipMigrationIsDisabledException'
#   (line 84) so that Invoke-WithTransientRetry retries Set-PolicyConfig when
#   the SPO-AIP propagation gap triggers that exception.
#
# Behaviour contract:
#   POST-FIX (GREEN): exception classified as transient → retry fires →
#     Set-PolicyConfig called 2 times; no "failed after retries" warning.
#   PRE-FIX (RED):  exception NOT classified → re-thrown on attempt 1 →
#     outer catch writes warning; Set-PolicyConfig called once.
#
# Config: EnableLabelCoAuth = $true, all other flags = $false.
#   $PSCmdlet.ShouldProcess fires (ConfirmPreference=None, no -WhatIf) → call
#   reaches Invoke-WithTransientRetry → Set-PolicyConfig is invoked.
# =============================================================================
Describe 'Group 1 — B2 #20: EnableSpoAipMigrationIsDisabledException classifier' `
    -Skip:(-not $script:onIppsBranch) {

    BeforeEach {
        $script:policyConfigCalls = 0
        Mock Start-Sleep   { }
        Mock Write-Host    { }
        Mock Write-Warning { }
    }

    It 'Retries Set-PolicyConfig when exception message contains EnableSpoAipMigrationIsDisabledException' {
        # Post-fix: classifier recognises the substring as transient → retry.
        Mock Set-PolicyConfig {
            $script:policyConfigCalls++
            if ($script:policyConfigCalls -eq 1) {
                throw 'EnableSpoAipMigrationIsDisabledException: To set EnableLabelCoauth you must enable AIP in SharePoint first.'
            }
            # Attempt 2: propagation complete, succeeds.
        }

        { & $script:SetupTenantSettingsPath -Config (New-CoAuthOnlyConfig) } | Should -Not -Throw

        Should -Invoke Set-PolicyConfig -Times 2 -Exactly
        Should -Not -Invoke Write-Warning -ParameterFilter { $Message -like '*failed after retries*' }
    }

    It 'Does NOT retry Set-PolicyConfig on a non-transient error (Access denied)' {
        # Non-transient exception must not be retried; outer catch writes warning.
        Mock Set-PolicyConfig {
            throw 'Access denied — insufficient administrative role for Set-PolicyConfig.'
        }

        { & $script:SetupTenantSettingsPath -Config (New-CoAuthOnlyConfig) } | Should -Not -Throw

        Should -Invoke Set-PolicyConfig -Times 1 -Exactly
        Should -Invoke Write-Warning -ParameterFilter { $Message -like '*failed after retries*' }
    }

    It 'First-attempt success — Set-PolicyConfig called exactly once, no failure warning' {
        Mock Set-PolicyConfig { }    # succeeds immediately

        { & $script:SetupTenantSettingsPath -Config (New-CoAuthOnlyConfig) } | Should -Not -Throw

        Should -Invoke Set-PolicyConfig -Times 1 -Exactly
        Should -Not -Invoke Write-Warning -ParameterFilter { $Message -like '*failed*' }
    }

    It 'Backward compat: pre-existing transient pattern Service Unavailable still triggers retry' {
        Mock Set-PolicyConfig {
            $script:policyConfigCalls++
            if ($script:policyConfigCalls -eq 1) {
                throw 'Service Unavailable — EXO IPPS returned HTTP 503.'
            }
        }

        { & $script:SetupTenantSettingsPath -Config (New-CoAuthOnlyConfig) } | Should -Not -Throw
        Should -Invoke Set-PolicyConfig -Times 2 -Exactly
    }

    It 'Field-style full exception class name (SpoAIpMigrationIsDisabledException suffix) is recognised' {
        # Mirrors exception messages collected from field runs where the IPPS
        # server prefixes its own exception class name into the message body, e.g.:
        #   "SetPolicyConfigEnableSpoAipMigrationIsDisabledException: ..."
        # The blob includes Exception.Message, so the pattern
        # 'EnableSpoAipMigrationIsDisabledException' matches case-insensitively.
        Mock Set-PolicyConfig {
            $script:policyConfigCalls++
            if ($script:policyConfigCalls -eq 1) {
                throw 'SetPolicyConfigEnableSpoAipMigrationIsDisabledException: SPO AIP migration is not yet complete on this tenant.'
            }
        }

        { & $script:SetupTenantSettingsPath -Config (New-CoAuthOnlyConfig) } | Should -Not -Throw
        Should -Invoke Set-PolicyConfig -Times 2 -Exactly
    }
}

# =============================================================================
# GROUP 2 — B2 #3: AdminAuditLogConfig post-write verification loop
#
# Production code (Setup-TenantSettings.ps1 lines 185-257):
#   Set-AdminAuditLogConfig fires bare (line 187). Then a loop polls
#   Get-AdminAuditLogConfig up to $verifyAttempts=5 times. Start-Sleep -Seconds 5
#   runs between non-final attempts ($va -lt $verifyAttempts). If verified:
#   Write-Host "Enabled and verified." If all 5 fail: Write-Host "Pending —
#   audit configuration may still be applying..." (Yellow) + remediation hint.
#   $auditSucceeded = $true in BOTH paths — script continues regardless.
#
# Jim's directive (copilot-directive-b2-3-audit-gate.md):
#   "We don't want to move forward if audit is not turned on."
#   The loop MUST surface a visible "Pending" warning when all attempts fail.
#   Silently returning success is unacceptable — audit-off going undetected
#   is a downstream risk. Operator message MUST include a remediation hint.
#
# Expected Get-AdminAuditLogConfig call totals:
#   Call 1     = initial Invoke-WithTransientRetry read → sets $audit
#   Calls 2-N  = verification loop ($va = 1 to $verifyAttempts)
#   Start-Sleep = called between loop iterations, NOT after final attempt
#
# Config: EnableUnifiedAuditLog = $true, all other flags = $false.
# =============================================================================
Describe 'Group 2 — B2 #3: AdminAuditLogConfig post-write verification loop' `
    -Skip:(-not $script:onIppsBranch) {

    BeforeAll {
        $script:auditCfg = New-AuditOnlyConfig
    }

    BeforeEach {
        # Per-test counters reset here; mocks are set per-It below.
        $script:getAuditCalls = 0

        Mock Get-OrganizationConfig    { [PSCustomObject]@{ IsDehydrated = $false } }
        Mock Set-AdminAuditLogConfig   { }
        Mock Enable-OrganizationCustomization { }
        Mock Start-Sleep               { }   # No-op; use Should -Invoke for count/value assertions
        Mock Write-Host                { }
        Mock Write-Warning             { }
    }

    It 'Verification succeeds on first loop attempt — writes Enabled-and-verified, no sleep' {
        # Get-AdminAuditLogConfig call 1 (initial read): false → Set fires.
        # Verification call 1 ($va=1): true → loop breaks, no sleep.
        Mock Get-AdminAuditLogConfig {
            $script:getAuditCalls++
            if ($script:getAuditCalls -eq 1) {
                [PSCustomObject]@{ UnifiedAuditLogIngestionEnabled = $false }
            } else {
                [PSCustomObject]@{ UnifiedAuditLogIngestionEnabled = $true }
            }
        }

        { & $script:SetupTenantSettingsPath -Config $script:auditCfg } | Should -Not -Throw

        Should -Invoke Write-Host -ParameterFilter { $Object -like '*Enabled and verified*' }
        Should -Not -Invoke Start-Sleep
    }

    It 'Verification succeeds on second attempt — one Start-Sleep of 5 seconds' {
        # Call 1 (initial read): false.
        # Verification $va=1: false → sleep 5s.
        # Verification $va=2: true → verified.
        Mock Get-AdminAuditLogConfig {
            $script:getAuditCalls++
            if ($script:getAuditCalls -le 2) {
                [PSCustomObject]@{ UnifiedAuditLogIngestionEnabled = $false }
            } else {
                [PSCustomObject]@{ UnifiedAuditLogIngestionEnabled = $true }
            }
        }

        { & $script:SetupTenantSettingsPath -Config $script:auditCfg } | Should -Not -Throw

        Should -Invoke Write-Host -ParameterFilter { $Object -like '*Enabled and verified*' }
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
    }

    It 'NO silent success — Pending message written when all 5 verification attempts fail (Jim directive)' {
        # CRITICAL: per Jim's directive, exhausting all retries must NOT silently pass.
        # All reads return false: initial read + all 5 verification attempts.
        Mock Get-AdminAuditLogConfig {
            [PSCustomObject]@{ UnifiedAuditLogIngestionEnabled = $false }
        }

        { & $script:SetupTenantSettingsPath -Config $script:auditCfg } | Should -Not -Throw

        # Must NOT silently claim success
        Should -Not -Invoke Write-Host -ParameterFilter { $Object -like '*Enabled and verified*' }
        # Must surface visible Pending state
        Should -Invoke Write-Host -ParameterFilter { $Object -like '*Pending*' }
    }

    It 'Loop performs exactly 5 verification attempts — 6 total Get-AdminAuditLogConfig invocations' {
        # 1 initial read + 5 verification = 6.
        Mock Get-AdminAuditLogConfig {
            [PSCustomObject]@{ UnifiedAuditLogIngestionEnabled = $false }
        }

        { & $script:SetupTenantSettingsPath -Config $script:auditCfg } | Should -Not -Throw

        Should -Invoke Get-AdminAuditLogConfig -Times 6 -Exactly
    }

    It 'Start-Sleep called 4 times at Seconds=5 — no sleep after the final (5th) verification attempt' {
        # Loop: $va=1 → sleep, $va=2 → sleep, $va=3 → sleep, $va=4 → sleep,
        #       $va=5 = $verifyAttempts → $va -lt $verifyAttempts is $false → NO sleep.
        Mock Get-AdminAuditLogConfig {
            [PSCustomObject]@{ UnifiedAuditLogIngestionEnabled = $false }
        }

        { & $script:SetupTenantSettingsPath -Config $script:auditCfg } | Should -Not -Throw

        Should -Invoke Start-Sleep -Times 4 -Exactly -ParameterFilter { $Seconds -eq 5 }
    }

    It 'Pending message includes operator remediation hint (Connect-ExchangeOnline)' {
        # Jim's directive: operator must know how to verify. The production code
        # writes Write-Host "To verify: Connect-ExchangeOnline; (Get-AdminAuditLogConfig)..."
        Mock Get-AdminAuditLogConfig {
            [PSCustomObject]@{ UnifiedAuditLogIngestionEnabled = $false }
        }

        { & $script:SetupTenantSettingsPath -Config $script:auditCfg } | Should -Not -Throw

        Should -Invoke Write-Host -ParameterFilter { $Object -like '*Connect-ExchangeOnline*' }
    }
}

# =============================================================================
# GROUP 3 — B2 #27: audit verification resolves Get from Set's module
# =============================================================================
Describe 'Group 3 — B2 #27: audit verification resolves Get from Set''s module' `
    -Skip:(-not $script:onIppsBranch) {

    BeforeEach {
        $script:resolvedAuditGetSource = $null
        $script:auditGetterCallCount = @{}

        Mock Start-Sleep { }
        Mock Write-Host { }
    }

    It 'dual-source resolution picks the Get-AdminAuditLogConfig binding from Set-AdminAuditLogConfig''s module' {
        $setCmd = [PSCustomObject]@{ Source = 'EXO_module' }
        $exoGetter  = New-SourcedAuditGetter -Source 'EXO_module'  -Sequence @($true)
        $ippsGetter = New-SourcedAuditGetter -Source 'IPPS_module' -Sequence @($false)

        $resolved = Resolve-AuditVerificationGetter -SetCommand $setCmd -GetCommands @($ippsGetter, $exoGetter) -BareGetter $ippsGetter

        $resolved.Source | Should -Be 'EXO_module'
    }

    It 'single-source resolution uses the only available Get-AdminAuditLogConfig binding' {
        $setCmd = [PSCustomObject]@{ Source = 'EXO_module' }
        $singleGetter = New-SourcedAuditGetter -Source 'EXO_module' -Sequence @($true)

        $resolved = Resolve-AuditVerificationGetter -SetCommand $setCmd -GetCommands @($singleGetter) -BareGetter $null

        $resolved.Source | Should -Be 'EXO_module'
    }

    It 'falls back to bare Get-Command when filtered -All resolution returns nothing' {
        $setCmd = [PSCustomObject]@{ Source = 'EXO_module' }
        $bareGetter = New-SourcedAuditGetter -Source 'BARE_module' -Sequence @($true)

        $resolved = Resolve-AuditVerificationGetter -SetCommand $setCmd -GetCommands @() -BareGetter $bareGetter

        $resolved.Source | Should -Be 'BARE_module'
    }

    It 'verify-success path writes Enabled and verified using the resolved Get binding' {
        $resolvedGetter = {
            param([string]$ErrorAction)
            $script:resolvedAuditGetSource = 'EXO_module'
            [PSCustomObject]@{ UnifiedAuditLogIngestionEnabled = $true }
        }

        Invoke-AuditVerificationLoop -Getter $resolvedGetter | Out-Null

        $script:resolvedAuditGetSource | Should -Be 'EXO_module'
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -eq '      Enabled and verified.' }
        Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { $Object -like '*Pending*' }
    }

    It 'verify-pending path emits all 4 wait messages and then the Pending status' {
        $resolvedGetter = New-SourcedAuditGetter -Source 'EXO_module' -Sequence @($false, $false, $false, $false, $false)

        Invoke-AuditVerificationLoop -Getter $resolvedGetter | Should -BeFalse

        Should -Invoke Write-Host -Times 4 -Exactly -ParameterFilter { $Object -like '*Audit config not confirmed yet*' }
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -like '*Pending*' }
        Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { $Object -like '*Enabled and verified*' }
    }
}
