# DLP Policy Creation Example (SMBTool Purview Toolkit)

This is the **Microsoft Purview DLP** portion of the SMBTool Purview Best
Practice Toolkit. It creates DLP policies that block external sharing of
content labelled with any **Confidential** or **Highly Confidential**
sub-label, per Microsoft's Business Premium Data Security Best Practice guide.

Two policies are created (per Microsoft's recommendation — separate per
workload):

* **Exchange** — blocks send to external recipients
* **SharePoint + OneDrive** — blocks external sharing/access

Both policies match content via **sensitivity label GUIDs** (resolved at
runtime from `LabelPaths`), never by display name, so they cannot collide
with similarly-named labels.

The script is **idempotent**: existing toolkit-managed policies/rules are
updated in place; foreign objects abort the run unless `-AdoptExisting` is
supplied.

---

## 1. Configuration (excerpt from `PurviewConfig.psd1`)

```powershell
@{
    # Marker stamped in object descriptions for safe re-runs and rollback.
    ManagedByTag = '[Managed by SMBTool Purview Toolkit]'

    # ----- DLP policies -----
    # Two policies (Microsoft's recommendation): one for Exchange, one for SPO + OneDrive.
    #
    # Workloads supported under Microsoft 365 Business Premium:
    #   * 'Exchange'              - mailboxes
    #   * 'SharePointOneDrive'    - SPO sites + OneDrive for Business
    #
    # E5 / Purview Suite ONLY (rejected when Deploy-PurviewBestPractice.ps1 is
    # run with -BPOnly):
    #   * 'Endpoint' / 'Devices'  - Endpoint DLP
    #   * 'OnPremisesScanner'     - on-prem file shares & SP servers
    #   * 'DefenderForCloudApps'  - 3rd party apps via MCAS
    #   * 'PowerBI'               - Power BI tenants
    DlpPolicies = @(
        @{
            Name        = 'SMBTool - DLP - Confidential and HC external (EXO)'
            Comment     = 'Blocks Exchange messages labelled with any Confidential or Highly Confidential sub-label from being sent outside the organisation.'
            Workload    = 'Exchange'
            RuleName    = 'SMBTool - DLP Rule - Confidential and HC - Exchange'
            # All Confidential + Highly Confidential sub-labels are OR-matched.
            # Resolved to GUIDs at runtime.
            LabelPaths  = @(
                'Confidential/AllEmployees'
                'Confidential/ConfidentialSpecificPeople'
                'Confidential/ConfidentialInternalException'
                'HighlyConfidential/HCAllEmps'
                'HighlyConfidential/HCSpecificPeople'
                'HighlyConfidential/HCInternalException'
            )
            BlockAccess = $true
            # BlockAccessScope is meaningful for SPO/ODFB only; Setup-DLP.ps1
            # omits it for Exchange rules. The value here is kept for config
            # schema consistency (ignored at runtime for Exchange workloads).
            BlockAccessScope = 'PerUser'
            NotifyUser  = @('SiteAdmin','LastModifier','Owner')
            GenerateIncidentReport = @('SiteAdmin')
        }
        @{
            Name        = 'SMBTool - DLP - Confidential and HC external (SPO+ODB)'
            Comment     = 'Blocks SharePoint and OneDrive files labelled with any Confidential or Highly Confidential sub-label from being shared externally.'
            Workload    = 'SharePointOneDrive'
            RuleName    = 'SMBTool - DLP Rule - Confidential and HC - SPO ODFB'
            LabelPaths  = @(
                'Confidential/AllEmployees'
                'Confidential/ConfidentialSpecificPeople'
                'Confidential/ConfidentialInternalException'
                'HighlyConfidential/HCAllEmps'
                'HighlyConfidential/HCSpecificPeople'
                'HighlyConfidential/HCInternalException'
            )
            BlockAccess = $true
            # SPO/ODFB: 'PerUser' = "Block only people outside your organization".
            # 'All' would mean "Block everyone" (incl. internal users).
            # 'PerAnonymousUser' would only block anonymous link recipients.
            BlockAccessScope = 'PerUser'
            NotifyUser  = @('SiteAdmin','LastModifier','Owner')
            GenerateIncidentReport = @('SiteAdmin')
        }
    )
}
```

---

## 2. DLP creation script (`Setup-DLP.ps1`)

```powershell
<#
.SYNOPSIS
    Creates Microsoft Purview DLP policies that block external sharing of
    content labelled with Confidential or Highly Confidential sub-labels.

.DESCRIPTION
    Implements Priority 1 DLP from the Microsoft 365 Business Premium Data
    Security Best Practice Deployment guide. Per Microsoft guidance, separate
    DLP policies are created per workload:

      * Exchange policy           — blocks send to external recipients
      * SharePoint + OneDrive     — blocks external sharing/access

    Both policies match content via SENSITIVITY LABEL GUIDs (resolved at
    runtime from LabelPaths) — never by display name — so they cannot
    accidentally collide with other labels of the same name.

    Supports LabelPaths (array, preferred) or LabelPath (single, back-compat).
    Multiple labels are OR-matched at the rule level.

    Idempotent: existing toolkit-managed policies and rules are updated in
    place; foreign objects abort the run unless -AdoptExisting is supplied.

.PARAMETER Config
    Hashtable from PurviewConfig.psd1.

.PARAMETER AdoptExisting
    Update DLP policies / rules that already exist but are not managed by
    this toolkit.

.PARAMETER BPOnly
    Reject DLP workloads that require Microsoft 365 E5 / Purview Suite
    licensing (Endpoint DLP / Devices, Defender for Cloud Apps,
    OnPremisesScanner, Power BI). Used by partners deploying against
    Microsoft 365 Business Premium tenants. When license auto-detect
    classifies the tenant as BusinessPremium or Other, this switch is set
    automatically.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'None')]
param(
    [Parameter(Mandatory)]
    [hashtable] $Config,

    [Parameter()]
    [switch] $AdoptExisting,

    [Parameter()]
    [switch] $BPOnly
)

$ErrorActionPreference = 'Stop'
$ConfirmPreference     = 'None'

# ... (Format-IPPSError, Test-Owned, Resolve-LabelByPath helpers omitted for brevity) ...

foreach ($cfg in $Config.DlpPolicies) {
    Write-Host "DLP policy: $($cfg.Name)" -ForegroundColor Cyan

    if ($BPOnly -and ($script:E5OnlyWorkloads -contains $cfg.Workload)) {
        Write-Warning "  Skipping '$($cfg.Name)' — workload '$($cfg.Workload)' requires E5/Purview Suite."
        continue
    }

    # Resolve all label paths to GUIDs. Supports LabelPaths (array) or
    # LabelPath (single, backward-compat). Multiple labels are OR-matched.
    $labelPathList = @()
    if ($cfg.LabelPaths) {
        $labelPathList = @($cfg.LabelPaths)
    } elseif ($cfg.LabelPath) {
        $labelPathList = @($cfg.LabelPath)
    } else {
        throw "DLP policy '$($cfg.Name)' has no LabelPath or LabelPaths configured."
    }

    $resolvedLabelGuids = @()
    foreach ($lp in $labelPathList) {
        $resolved = Resolve-LabelByPath -Path $lp
        $resolvedLabelGuids += $resolved.Guid.ToString()
    }

    # Build the sensitivity-label match group. All resolved GUIDs are
    # OR-matched in a single groups array.
    $labelMatches = @($resolvedLabelGuids | ForEach-Object { @{ name = $_; type = 'Sensitivity' } })
    $contentMatch = @{
        operator = 'And'
        groups   = @(
            @{
                operator = 'Or'
                name     = 'Default'
                labels   = $labelMatches
            }
        )
    }

    # ... (policy create/update, rule existence check omitted for brevity) ...

    $ruleArgs = @{
        Name                          = $cfg.RuleName
        Policy                        = $cfg.Name
        Comment                       = "$tag DLP rule for $($cfg.Workload)."
        ContentContainsSensitiveInformation = $contentMatch
        BlockAccess                   = $cfg.BlockAccess
        NotifyUser                    = $cfg.NotifyUser
        GenerateIncidentReport        = $cfg.GenerateIncidentReport
    }

    # Exchange: external condition via AccessScope; BlockAccessScope is
    # not applicable and is omitted to avoid portal noise.
    # SPO/ODFB: both conditions apply.
    if ($cfg.Workload -eq 'Exchange') {
        $ruleArgs['AccessScope'] = 'NotInOrganization'
    } elseif ($cfg.Workload -eq 'SharePointOneDrive') {
        $ruleArgs['AccessScope']      = 'NotInOrganization'
        $ruleArgs['BlockAccessScope'] = $cfg.BlockAccessScope
    }

    if (-not $existingRule) {
        if ($PSCmdlet.ShouldProcess($cfg.RuleName, 'New-DlpComplianceRule')) {
            New-DlpComplianceRule @ruleArgs -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        }
    } else {
        if ($PSCmdlet.ShouldProcess($cfg.RuleName, 'Set-DlpComplianceRule')) {
            $setArgs = @{
                Identity = $cfg.RuleName
                Comment  = $ruleArgs.Comment
                ContentContainsSensitiveInformation = $contentMatch
                BlockAccess            = $cfg.BlockAccess
                NotifyUser             = $cfg.NotifyUser
                GenerateIncidentReport = $cfg.GenerateIncidentReport
                AccessScope            = $ruleArgs.AccessScope
            }
            if ($cfg.Workload -ne 'Exchange') {
                $setArgs['BlockAccessScope'] = $ruleArgs.BlockAccessScope
            }
            Set-DlpComplianceRule @setArgs -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

Write-Host "DLP policies complete." -ForegroundColor Green
Write-Host "NOTE: DLP policy changes can take up to an hour to begin enforcement." -ForegroundColor DarkYellow
```

---

## 3. How it's invoked

The orchestrator calls this module with the loaded config hashtable:

```powershell
# From Deploy-PurviewBestPractice.ps1
$Config = Import-PowerShellDataFile -Path .\Config\PurviewConfig.psd1

# Connect to Security & Compliance Center (IPPS) first
Connect-IPPSSession -UserPrincipalName admin@contoso.onmicrosoft.com

# Run the DLP module — use -WhatIf for dry-run, -BPOnly for Business Premium tenants
.\Modules\Setup-DLP.ps1 -Config $Config -BPOnly -WhatIf
.\Modules\Setup-DLP.ps1 -Config $Config -BPOnly
```

---

## 4. Key design notes

| Aspect | Decision | Rationale |
|---|---|---|
| **Per-workload policies** | One for Exchange, one for SPO+ODFB | Microsoft's own recommendation; mixing workloads complicates rule scoping |
| **Multi-label match** | `LabelPaths` (array of 6 paths) OR-matched | Covers all Confidential and Highly Confidential sub-labels in one rule |
| **Match by label GUID** | `Resolve-LabelByPath` → `$label.Guid` | Display names can collide; GUIDs are unambiguous |
| **Idempotency** | `Test-Owned` checks `[Managed by SMBTool Purview Toolkit]` tag in `Comment` | Safe to re-run; foreign objects need explicit `-AdoptExisting` |
| **64-char name limit** | Validated upfront | IPPS rejects longer names with an empty error; we surface a clear message |
| **`-BPOnly` guard** | Skips E5-only workloads (Endpoint, MCAS, OnPrem, PowerBI); auto-set on BP tenants | Prevents partners from creating policies their tenant can't enforce |
| **`AccessScope = 'NotInOrganization'`** | Both workloads | The "external" condition — only fires for outside-org recipients/sharers |
| **`BlockAccessScope`** | SPO/ODFB only; omitted for Exchange | Exchange uses `AccessScope` for external scoping; `BlockAccessScope` is an SPO/ODFB concept and is a no-op on Exchange rules |

---

## 5. Cmdlets used (Security & Compliance PowerShell / IPPS)

* `Get-DlpCompliancePolicy` / `New-DlpCompliancePolicy` / `Set-DlpCompliancePolicy`
* `Get-DlpComplianceRule`   / `New-DlpComplianceRule`   / `Set-DlpComplianceRule`
* `Get-Label` (to resolve label name → GUID)

Connection: `Connect-IPPSSession` (ExchangeOnlineManagement module).

