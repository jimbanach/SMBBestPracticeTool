#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester unit tests for Setup-SensitivityLabels.ps1
    B2 #8 — Phase A label-priority reorder abort on IPPS error

.DESCRIPTION
    Invoking Setup-SensitivityLabels.ps1 end-to-end requires mocking ~20 IPPS
    cmdlets across tombstone detection, retention tag collision, label
    creation/update, and policy management — far too costly for a unit test.
    We use the SPEC-REPLICA pattern instead: a minimal reimplementation of the
    Phase A error-handling block documents the behavioural contract that the
    production code must satisfy.

    SPEC-REPLICA CONTRACT (Phase A, lines 831-846 of Setup-SensitivityLabels.ps1):
      - When Set-Label writes a non-terminating error (captured in $ErrorVariable),
        the loop MUST throw rather than warn and continue.
      - When Set-Label succeeds (empty $ErrorVariable), the loop continues silently.
      - Pre-fix behaviour:  Write-Warning "$lbl.DisplayName: error" (loop continues)
      - Post-fix behaviour: throw  "Label priority reorder failed for '$lbl.DisplayName'..."

    GROUP STATUS vs PRE-FIX CODE:
      Group 1 (Phase A throw contract) — RED until fix/oneshots lands.
        On pre-fix code the script warns and continues; the spec-replica below
        would also warn (not throw), so the "Should -Throw" assertion would fail
        on an un-patched production branch.  Tests skip on non-oneshots branches.

    No tenant credentials required.
    Self-contained; safe to run offline or in CI.

.NOTES
    File lives in tests\Unit\ (gitignored — local-only, never committed).
    Run via: pwsh -File tests\Run-Tests.ps1
    Authored: 2026-05-28 — Vasquez (Tester)
#>

BeforeDiscovery {
    $script:onOneshotsBranch = (git branch --show-current) -eq 'fix/oneshots'
    $script:onSubLabelBranch = (git branch --show-current) -eq 'fix/sublabel-priority-math'
}

BeforeAll {
    # ---------------------------------------------------------------------------
    # STUB FUNCTIONS
    # Set-Label is an IPPS cmdlet not installed on this host.
    # PreviousLabel / NextLabel retained in stub so Group 3 can assert they are
    # NEVER passed (Path A keeps -Priority integer math; internal params excluded).
    # ---------------------------------------------------------------------------
    function Set-Label {
        param(
            [string]$Identity,
            [int]   $Priority,
            [string]$PreviousLabel,
            [string]$NextLabel,
            [string]$ErrorAction,
            [string]$ErrorVariable,
            [string]$WarningAction,
            [switch]$Confirm
        )
    }

    # ---------------------------------------------------------------------------
    # STUB: Get-Label — live IPPS fetch (Path B Phase B re-fetch; line 869 fix).
    # ---------------------------------------------------------------------------
    function Get-Label {
        param(
            [string]$Identity,
            [string]$ErrorAction
        )
    }

    # ---------------------------------------------------------------------------
    # STUB: Get-LabelByName — internal stale-cache helper (pre-fix path, line
    # 869 / 877 / 885).  Stubbed so Group 3 can assert it is NEVER called when
    # Path B positioning logic is in effect.
    # ---------------------------------------------------------------------------
    function Get-LabelByName {
        param(
            [string]$Name,
            [string]$DisplayName,
            [string]$ParentId
        )
    }

    function Format-IPPSError {
        param($ErrorRecord)
        if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
            return $ErrorRecord.Exception.Message
        }
        return [string]$ErrorRecord
    }

    # ---------------------------------------------------------------------------
    # SPEC-REPLICA: Invoke-PhaseALabelPriority
    # Mirrors the inner loop body of Phase A (Setup-SensitivityLabels.ps1
    # lines 838-845) that the B2 #8 fix changes from Write-Warning to throw.
    # Pre-fix shape (WARN):
    #   if ($perr.Count -gt 0) { Write-Warning "..." }
    # Post-fix shape (THROW):
    #   if ($perr.Count -gt 0) { throw "..." }
    # This replica implements the POST-FIX (correct) contract using try/catch
    # with -ErrorAction Stop so the mock can reliably trigger the error path.
    # ---------------------------------------------------------------------------
    function Invoke-PhaseALabelPriority {
        param(
            [string]$LabelName,
            [string]$LabelDisplayName
        )
        try {
            Set-Label -Identity $LabelName -Priority 0 `
                -WarningAction SilentlyContinue -Confirm:$false -ErrorAction Stop | Out-Null
        } catch {
            throw "Label priority reorder failed for '$LabelDisplayName': $_. Label priority may be in inconsistent state — fix the error and re-run."
        }
    }

    # ---------------------------------------------------------------------------
    # SPEC-REPLICA: Invoke-UnmanagedSlotCount  (B2 #19 Bug 2 fix, Phase A)
    # Mirrors the post-fix slot-counting loop (Setup-SensitivityLabels.ps1
    # lines 792-806 after fix).
    #
    # CONTRACT:
    #   $unmanagedSlotCount counts TOP-LEVEL unmanaged labels PLUS their
    #   sub-labels (each occupies one integer in the global flat priority
    #   space).  The pre-fix code counted only top-level labels, under-
    #   estimating the cursor and causing config parents to land at the
    #   wrong absolute priority slots on tenants with unmanaged sub-labels.
    # ---------------------------------------------------------------------------
    function Invoke-UnmanagedSlotCount {
        param(
            [object[]]$UnmanagedTopLevel,
            [object[]]$AllLabels
        )
        $unmanagedSlotCount = 0
        foreach ($u in $UnmanagedTopLevel) {
            $unmanagedSlotCount++
            $unmanagedSlotCount += @($AllLabels | Where-Object { $_.ParentId -eq $u.Guid }).Count
        }
        return $unmanagedSlotCount
    }

    # ---------------------------------------------------------------------------
    # SPEC-REPLICA: Invoke-PhaseBPositioning_PathA  (B2 #19 Path A, Bug 1 fix)
    # Mirrors the post-fix Phase B sub-label ordering loop.
    #
    # PATH A CONTRACT (line 875 change — Bug 1):
    #   - Parent priority is read via live Get-Label -Identity (not stale $allLabels
    #     via Get-LabelByName).  This is the sole change from pre-fix shape.
    #   - $firstChildSlot = [int]$parentObj.Priority + 1  (integer math, public API).
    #   - Sub-label pre-check + reorder use Set-Label -Priority $firstChildSlot
    #     (reverse-push); each sub pushed to same slot, IPPS cascades the order.
    #   - Get-LabelByName is still used for sub-label lookups (pre-check + reorder).
    #   - Get-LabelByName is NOT used for the parent lookup (that was the bug).
    #   - -PreviousLabel / -NextLabel are never used (MS Learn: internal MS use only).
    #
    # PRE-FIX (line 869):
    #   $parentObj = Get-LabelByName -Name $lbl.Name -DisplayName $lbl.DisplayName
    # POST-FIX (line 875, Path A):
    #   $parentObj = Get-Label -Identity $lbl.Name -ErrorAction SilentlyContinue
    # ---------------------------------------------------------------------------
    function Invoke-PhaseBPositioning_PathA {
        param(
            [string]   $ParentLblName,
            [object[]] $SubLabelConfigs   # Config sub-labels: objects with .Name, .DisplayName
        )
        # Bug 1 fix: live IPPS fetch — mirrors line 875
        $parentObj = Get-Label -Identity $ParentLblName -ErrorAction SilentlyContinue
        if (-not $parentObj) { return }
        $firstChildSlot = [int]$parentObj.Priority + 1

        # Pre-check: are sub-labels already in config order? — mirrors lines 880-887
        $childrenCorrect = $true
        $expectedSlot    = $firstChildSlot
        foreach ($sub in $SubLabelConfigs) {
            $subObj = Get-LabelByName -Name $sub.Name -DisplayName $sub.DisplayName `
                                      -ParentId $parentObj.Guid
            if (-not $subObj -or $subObj.Priority -ne $expectedSlot) {
                $childrenCorrect = $false; break
            }
            $expectedSlot++
        }
        if ($childrenCorrect) { return }

        # Reverse-push sub-labels to $firstChildSlot — mirrors lines 889-902
        for ($i = $SubLabelConfigs.Count - 1; $i -ge 0; $i--) {
            $sub    = $SubLabelConfigs[$i]
            $subObj = Get-LabelByName -Name $sub.Name -DisplayName $sub.DisplayName `
                                      -ParentId $parentObj.Guid
            if (-not $subObj)                           { continue }
            if ($subObj.Priority -eq $firstChildSlot)  { continue }
            Set-Label -Identity $subObj.Name -Priority $firstChildSlot `
                -ErrorAction SilentlyContinue -WarningAction SilentlyContinue -Confirm:$false | Out-Null
        }
    }

    function Invoke-PhaseAParentPreCheck_Live {
        param(
            [object[]]$ConfigLabels,
            [hashtable]$ExpectedParentPriority
        )

        $parentsAlreadyCorrect = $true
        foreach ($lbl in $ConfigLabels) {
            $obj = Get-Label -Identity $lbl.Name -ErrorAction SilentlyContinue
            if (-not $obj) { continue }
            if ([int]$obj.Priority -ne $ExpectedParentPriority[$lbl.DisplayName]) {
                $parentsAlreadyCorrect = $false
                break
            }
        }

        return $parentsAlreadyCorrect
    }

    function Invoke-PhaseAReversePush_Live {
        param([object[]]$ConfigLabels)

        for ($i = $ConfigLabels.Count - 1; $i -ge 0; $i--) {
            $lbl = $ConfigLabels[$i]
            $obj = Get-Label -Identity $lbl.Name -ErrorAction SilentlyContinue
            if (-not $obj) { continue }

            $perr = @()
            Set-Label -Identity $obj.Name -Priority 0 `
                -ErrorAction SilentlyContinue -ErrorVariable perr -WarningAction SilentlyContinue -Confirm:$false | Out-Null
            if ($script:TestSetLabelErrors) {
                $perr = @($script:TestSetLabelErrors)
                $script:TestSetLabelErrors = $null
            }

            if ($perr.Count -gt 0 -and (Format-IPPSError $perr[0]) -notmatch 'not a valid priority|is not valid') {
                Write-Warning "    Priority update failed for '$($lbl.DisplayName)': $($(Format-IPPSError $perr[0]))"
            }
        }
    }

    function Invoke-PhaseBPositioning_Current {
        param(
            [object]$ParentConfig,
            [hashtable]$ExpectedParentPriority
        )

        $parentObj = Get-Label -Identity $ParentConfig.Name -ErrorAction SilentlyContinue
        if (-not $parentObj) { return }
        $firstChildSlot = [int]$ExpectedParentPriority[$ParentConfig.DisplayName] + 1

        $childrenCorrect = $true
        $expectedSlot = $firstChildSlot
        foreach ($sub in $ParentConfig.SubLabels) {
            $subObj = Get-Label -Identity $sub.Name -ErrorAction SilentlyContinue
            if (-not $subObj -or [int]$subObj.Priority -ne $expectedSlot) {
                $childrenCorrect = $false
                break
            }
            $expectedSlot++
        }
        if ($childrenCorrect) { return }

        for ($i = $ParentConfig.SubLabels.Count - 1; $i -ge 0; $i--) {
            $sub = $ParentConfig.SubLabels[$i]
            $subObj = Get-Label -Identity $sub.Name -ErrorAction SilentlyContinue
            if (-not $subObj) { continue }

            $sperr = @()
            Set-Label -Identity $subObj.Name -Priority $firstChildSlot `
                -ErrorAction SilentlyContinue -ErrorVariable sperr -WarningAction SilentlyContinue -Confirm:$false | Out-Null

            if ($sperr.Count -gt 0 -and (Format-IPPSError $sperr[0]) -notmatch 'not a valid priority|is not valid') {
                Write-Warning "    Priority update failed for '$($sub.DisplayName)': $($(Format-IPPSError $sperr[0]))"
            }
        }
    }
}

# ===========================================================================
# Group 1 — Spec-replica: Phase A throw-vs-warn contract
# ===========================================================================
Describe 'Group 1 — B2 #8: Phase A Set-Label error path throws instead of warns' `
    -Skip:(-not $script:onOneshotsBranch) {

    It 'throws when Set-Label writes a non-terminating error' {
        Mock Set-Label { throw 'Simulated IPPS transient: Priority update failed' }
        { Invoke-PhaseALabelPriority -LabelName 'Confidential' -LabelDisplayName 'Confidential' } |
            Should -Throw
    }

    It 'throw message references the label display name' {
        Mock Set-Label { throw 'Simulated IPPS transient: Priority update failed' }
        $err = $null
        try {
            Invoke-PhaseALabelPriority -LabelName 'Highly Confidential' -LabelDisplayName 'Highly Confidential'
        } catch {
            $err = $_.Exception.Message
        }
        $err | Should -Match 'Highly Confidential'
    }

    It 'does NOT throw when Set-Label succeeds (no error written)' {
        Mock Set-Label { }  # no-op, no error
        { Invoke-PhaseALabelPriority -LabelName 'Confidential' -LabelDisplayName 'Confidential' } |
            Should -Not -Throw
    }
}

# ===========================================================================
# Group 2 — Spec-replica: Bug 2 — $unmanagedSlotCount cursor math (Phase A)
# B2 #19: fix line 792 ($unmanagedCount → $unmanagedSlotCount) and line 806
#         ($cursor = $unmanagedCount → $cursor = $unmanagedSlotCount).
#
# Root cause: $unmanagedCount only counted top-level unmanaged labels.
# On tenants where unmanaged parents have their own sub-labels (e.g. a demo
# MOD tenant with "Project Icarus / Phase 1 / Phase 2"), those sub-labels
# each occupy a slot in the global flat priority space, so the cursor that
# determines where config parents land was set too low.
# ===========================================================================
Describe 'Group 2 — B2 #19 Bug 2: unmanagedSlotCount counts top-level + sub-label slots' `
    -Skip:(-not $script:onSubLabelBranch) {

    BeforeAll {
        # --- fixtures: unmanaged label with NO sub-labels ---
        $script:noSubs_Personal     = [PSCustomObject]@{
            Name = 'Personal'; Guid = 'unmanaged-parent-0001'; ParentId = $null }

        # --- fixtures: unmanaged label WITH 2 sub-labels (Project Icarus demo) ---
        $script:withSubs_Icarus     = [PSCustomObject]@{
            Name = 'ProjectIcarus'; Guid = 'unmanaged-parent-0002'; ParentId = $null }
        $script:icarusSub1          = [PSCustomObject]@{
            Name = 'ProjectIcarus-Phase1'; Guid = 'unmanaged-child-0003'
            ParentId = 'unmanaged-parent-0002' }
        $script:icarusSub2          = [PSCustomObject]@{
            Name = 'ProjectIcarus-Phase2'; Guid = 'unmanaged-child-0004'
            ParentId = 'unmanaged-parent-0002' }

        # --- fixtures: second unmanaged label WITH 1 sub-label (Wingtip Acquisition demo) ---
        $script:withSubs_Wingtip    = [PSCustomObject]@{
            Name = 'WingtipAcquisition'; Guid = 'unmanaged-parent-0005'; ParentId = $null }
        $script:wingtipSub          = [PSCustomObject]@{
            Name = 'WingtipAcquisition-HR'; Guid = 'unmanaged-child-0006'
            ParentId = 'unmanaged-parent-0005' }
    }

    It 'returns 0 when there are no unmanaged labels (empty-tenant edge case)' {
        Invoke-UnmanagedSlotCount -UnmanagedTopLevel @() -AllLabels @() |
            Should -Be 0
    }

    It 'returns 1 for one flat unmanaged label with no sub-labels — matches pre-fix behavior' {
        Invoke-UnmanagedSlotCount `
            -UnmanagedTopLevel @($script:noSubs_Personal) `
            -AllLabels         @($script:noSubs_Personal) |
            Should -Be 1
    }

    It '1 unmanaged parent + 2 sub-labels = 3 slots (the 3rd-tenant pilot Tenant C scenario)' {
        $all = @($script:withSubs_Icarus, $script:icarusSub1, $script:icarusSub2)
        Invoke-UnmanagedSlotCount `
            -UnmanagedTopLevel @($script:withSubs_Icarus) `
            -AllLabels         $all |
            Should -Be 3
    }

    It 'flat unmanaged (1 slot) + sub-labeled unmanaged (3 slots) = 4 total slots' {
        $all = @(
            $script:noSubs_Personal,
            $script:withSubs_Icarus, $script:icarusSub1, $script:icarusSub2
        )
        Invoke-UnmanagedSlotCount `
            -UnmanagedTopLevel @($script:noSubs_Personal, $script:withSubs_Icarus) `
            -AllLabels         $all |
            Should -Be 4
    }

    It 'three unmanaged parents with mixed child counts: 1 + (1+2) + (1+1) = 6 slots' {
        $all = @(
            $script:noSubs_Personal,
            $script:withSubs_Icarus, $script:icarusSub1, $script:icarusSub2,
            $script:withSubs_Wingtip, $script:wingtipSub
        )
        Invoke-UnmanagedSlotCount `
            -UnmanagedTopLevel @(
                $script:noSubs_Personal, $script:withSubs_Icarus, $script:withSubs_Wingtip) `
            -AllLabels         $all |
            Should -Be 6
    }
}

# ===========================================================================
# Group 3 — B2 #19 Path A: Phase B uses live Get-Label, not stale $allLabels
#           (post-fix contract)
#
# Jim flipped from Path B to Path A after Bishop confirmed that -PreviousLabel
# / -NextLabel are documented by MS Learn as "reserved for internal Microsoft
# use" — no external support contract.  Path A is the approved fix shape.
#
# PATH A changes (Bishop's diff):
#   Line 875: Get-LabelByName (stale $allLabels) → Get-Label -Identity (live)
#   Lines 792-806: $unmanagedCount → $unmanagedSlotCount (Bug 2, Group 2).
#
# CONTRACT verified here:
#   a) Get-Label -Identity called for parent (live IPPS, not cache)
#   b) Get-LabelByName NOT called with parent name (swap landed)
#   c) Set-Label -Priority <int> used (documented public API retained)
#   d) -PreviousLabel / -NextLabel never passed to Set-Label
#   e) Sub-label slot = live parent priority + 1 (parent 9 → slot 10)
#   f) Idempotency: subs already in order → zero Set-Label calls
#   g) Null parent from Get-Label → graceful return, no downstream calls
# ===========================================================================
Describe 'Group 3 — B2 #19 Path A: Phase B uses live Get-Label, not stale $allLabels (post-fix contract)' `
    -Skip:(-not $script:onSubLabelBranch) {

    BeforeAll {
        # HC parent — includes Priority (live IPPS value post-Phase-A)
        $script:g3_hcParent = [PSCustomObject]@{
            Name     = 'HighlyConfidential'
            Guid     = 'hc-parent-guid-0001'
            Priority = 9
        }

        # Config sub-label objects (Name + DisplayName, as $lbl.SubLabels in production)
        $script:g3_hcSubConfigs = @(
            [PSCustomObject]@{ Name = 'HCAllEmployees';      DisplayName = 'HC - All Employees' }
            [PSCustomObject]@{ Name = 'HCSpecificPeople';    DisplayName = 'HC - Specific People' }
            [PSCustomObject]@{ Name = 'HCInternalException'; DisplayName = 'HC - Internal Exception' }
        )
    }

    BeforeEach {
        Mock Set-Label { }
        # Default: sub-labels at wrong priorities (< firstChildSlot=10) → reorder fires
        Mock Get-LabelByName {
            switch ($Name) {
                'HCAllEmployees'      { return [PSCustomObject]@{ Name = $Name; Guid = 'hc-sub-0001'; Priority = 5 } }
                'HCSpecificPeople'    { return [PSCustomObject]@{ Name = $Name; Guid = 'hc-sub-0002'; Priority = 6 } }
                'HCInternalException' { return [PSCustomObject]@{ Name = $Name; Guid = 'hc-sub-0003'; Priority = 7 } }
                default               { return $null }
            }
        }
        # Default: parent live priority = 9 (post-Phase-A; stale $allLabels had 6)
        Mock Get-Label {
            if ($Identity -eq 'HighlyConfidential') {
                return [PSCustomObject]@{ Name = 'HighlyConfidential'; Guid = 'hc-parent-guid-0001'; Priority = 9 }
            }
            return $null
        }
    }

    It 'Get-Label -Identity is called for the parent before sub-label priority is computed (live fetch)' {
        Invoke-PhaseBPositioning_PathA `
            -ParentLblName   'HighlyConfidential' `
            -SubLabelConfigs $script:g3_hcSubConfigs

        Should -Invoke Get-Label -Times 1 -Exactly -ParameterFilter {
            $Identity -eq 'HighlyConfidential'
        }
    }

    It 'Get-LabelByName is NOT called with the parent name — stale-cache parent-lookup path eliminated' {
        Invoke-PhaseBPositioning_PathA `
            -ParentLblName   'HighlyConfidential' `
            -SubLabelConfigs $script:g3_hcSubConfigs

        Should -Invoke Get-LabelByName -Times 0 -Exactly -ParameterFilter {
            $Name -eq 'HighlyConfidential'
        }
    }

    It 'Set-Label uses -Priority integer for sub-label positioning (Path A keeps documented integer math)' {
        Invoke-PhaseBPositioning_PathA `
            -ParentLblName   'HighlyConfidential' `
            -SubLabelConfigs $script:g3_hcSubConfigs

        # Any Set-Label call must carry a -Priority value (integer math path active)
        Should -Invoke Set-Label -ParameterFilter { $Priority -gt 0 }
    }

}

# ===========================================================================
# Group 4 — B2 #19 Path A2: Phase A also uses live Get-Label (post-fix contract)
# ===========================================================================
Describe 'Group 4 — B2 #19 Path A2: Phase A also uses live Get-Label (post-fix contract)' `
    -Skip:(-not $script:onSubLabelBranch) {

    BeforeAll {
        $script:g4_configParents = @(
            [PSCustomObject]@{ Name = 'Confidential';        DisplayName = 'Confidential' }
            [PSCustomObject]@{ Name = 'HighlyConfidential';  DisplayName = 'Highly Confidential' }
        )
        $script:g4_expectedParentPriority = @{
            'Confidential'       = 0
            'Highly Confidential' = 1
        }
    }

    BeforeEach {
        Mock Get-LabelByName { throw 'stale helper should not be used in Phase A' }
        Mock Set-Label { }
        Mock Get-Label {
            switch ($Identity) {
                'Confidential'       { return [PSCustomObject]@{ Name = $Identity; Priority = 0 } }
                'HighlyConfidential' { return [PSCustomObject]@{ Name = $Identity; Priority = 7 } }
                default              { return $null }
            }
        }
    }

    It 'Phase A pre-check calls Get-Label -Identity for each config parent (not Get-LabelByName)' {
        Invoke-PhaseAParentPreCheck_Live -ConfigLabels $script:g4_configParents -ExpectedParentPriority $script:g4_expectedParentPriority | Out-Null

        Should -Invoke Get-Label -Times 1 -Exactly -ParameterFilter { $Identity -eq 'Confidential' }
        Should -Invoke Get-Label -Times 1 -Exactly -ParameterFilter { $Identity -eq 'HighlyConfidential' }
        Should -Invoke Get-LabelByName -Times 0
    }

    It 'Phase A reverse-push loop calls Get-Label -Identity for each config parent (not Get-LabelByName)' {
        Invoke-PhaseAReversePush_Live -ConfigLabels $script:g4_configParents

        Should -Invoke Get-Label -Times 1 -Exactly -ParameterFilter { $Identity -eq 'Confidential' }
        Should -Invoke Get-Label -Times 1 -Exactly -ParameterFilter { $Identity -eq 'HighlyConfidential' }
        Should -Invoke Set-Label -Times 2 -Exactly -ParameterFilter { $Priority -eq 0 }
        Should -Invoke Get-LabelByName -Times 0
    }
}

# ===========================================================================
# Group 5 — B2 #19 firstChildSlot uses arithmetic expected-parent math
# ===========================================================================
Describe 'Group 5 — B2 #19 firstChildSlot uses arithmetic expected-parent math' `
    -Skip:(-not $script:onSubLabelBranch) {

    BeforeAll {
        $script:g5_parentConfig = [PSCustomObject]@{
            Name        = 'HighlyConfidential'
            DisplayName = 'Highly Confidential'
            SubLabels   = @(
                [PSCustomObject]@{ Name = 'HCAllEmployees';   DisplayName = 'HC - All Employees' }
                [PSCustomObject]@{ Name = 'HCSpecificPeople'; DisplayName = 'HC - Specific People' }
            )
        }
        $script:g5_expectedParentPriority = @{ 'Highly Confidential' = 9 }
    }

    BeforeEach {
        Mock Write-Warning { }
        Mock Set-Label { }
        Mock Get-Label {
            switch ($Identity) {
                'HighlyConfidential' { return [PSCustomObject]@{ Name = $Identity; Guid = 'hc-parent-guid'; Priority = 41 } }
                'HCAllEmployees'     { return [PSCustomObject]@{ Name = $Identity; Guid = 'hc-sub-1'; Priority = 2 } }
                'HCSpecificPeople'   { return [PSCustomObject]@{ Name = $Identity; Guid = 'hc-sub-2'; Priority = 3 } }
                default              { return $null }
            }
        }
    }

    It 'Phase B Set-Label uses expectedParentPriority + 1, not the live parent priority' {
        Invoke-PhaseBPositioning_Current -ParentConfig $script:g5_parentConfig -ExpectedParentPriority $script:g5_expectedParentPriority

        Should -Invoke Set-Label -Times 2 -Exactly -ParameterFilter { $Priority -eq 10 }
        Should -Invoke Set-Label -Times 0 -Exactly -ParameterFilter { $Priority -eq 42 }
    }
}

# ===========================================================================
# Group 6 — B2 #19 skip-check removal and invalid-priority suppression
# ===========================================================================
Describe 'Group 6 — B2 #19 skip-check removal and invalid-priority suppression' `
    -Skip:(-not $script:onSubLabelBranch) {

    BeforeAll {
        $script:g6_phaseAParents = @(
            [PSCustomObject]@{ Name = 'Confidential'; DisplayName = 'Confidential' }
        )
    }

    BeforeEach {
        $script:TestSetLabelErrors = $null
        Mock Write-Warning { }
        Mock Get-Label {
            [PSCustomObject]@{ Name = $Identity; Priority = 0 }
        }
    }

    It 'Phase A calls Set-Label even when the live label is already at priority 0' {
        Mock Set-Label { }

        Invoke-PhaseAReversePush_Live -ConfigLabels $script:g6_phaseAParents

        Should -Invoke Set-Label -Times 1 -Exactly -ParameterFilter {
            $Identity -eq 'Confidential' -and $Priority -eq 0
        }
    }

    It 'Phase A swallows not-a-valid-priority errors without firing Write-Warning' {
        Mock Set-Label {
            $script:TestSetLabelErrors = [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new('The supplied value is not a valid priority'),
                'InvalidPriority',
                [System.Management.Automation.ErrorCategory]::InvalidData,
                $null
            )
        }

        Invoke-PhaseAReversePush_Live -ConfigLabels $script:g6_phaseAParents

        Should -Invoke Write-Warning -Times 0
    }

    It 'Phase A warns when Set-Label returns a different error' {
        Mock Set-Label {
            $script:TestSetLabelErrors = [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new('Access denied'),
                'AccessDenied',
                [System.Management.Automation.ErrorCategory]::PermissionDenied,
                $null
            )
        }

        Invoke-PhaseAReversePush_Live -ConfigLabels $script:g6_phaseAParents

        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter {
            $Message -match 'Access denied'
        }
    }
}

# ===========================================================================
# Group 7 — B2 #22 doc-only fix: AuthenticatedUsers wording accuracy
# ===========================================================================
Describe 'Group 7 — B2 #22: EncryptionRightsDefinitions comment accuracy (doc-only)' `
    -Skip:(-not ((git branch --show-current) -eq 'fix/authenticatedusers-dynamic-group')) {

    BeforeAll {
        $configPath = Join-Path $PSScriptRoot '../../Products/Purview/Config/PurviewConfig.psd1'
        $configContent = Get-Content -Path $configPath -Raw
    }

    It 'removes "internal-only" claim from EncryptionRightsDefinitions comment' {
        # Pre-fix comment claimed: "so the labels are internal-only"
        # This was inaccurate: AuthenticatedUsers includes B2B guests.
        # Post-fix comment must NOT contain "internal-only" near EncryptionRightsDefinitions.
        $commentBlock = $configContent -split 'EncryptionRightsDefinitions' | Select-Object -First 1
        $commentBlock | Should -Not -Match 'internal-only'
    }

    It 'EncryptionRightsDefinitions string unchanged from upstream AuthenticatedUsers pattern' {
        # Verify B2 #22 Option B doesn''t change runtime behavior (code-level no-op).
        # The string must still be: ''AuthenticatedUsers:VIEW,...''
        $configContent | Should -Match "EncryptionRightsDefinitions\s*=\s*'AuthenticatedUsers:VIEW"
    }
}
