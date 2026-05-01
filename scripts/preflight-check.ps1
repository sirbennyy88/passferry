<#
.SYNOPSIS
    Pre-flight validation for Source → Target sync deployment.

.DESCRIPTION
    Run this on a workstation with RSAT-AD-PowerShell and connectivity to
    every legacy and Target DC you intend to touch. It validates everything
    in docs/ISSUES-AND-RISKS.md programmatically and tells you what to fix
    before writing/deploying any code.

    Read-only. Doesn't modify anything.

.EXAMPLE
    .\scripts/preflight-check.ps1 -SourceDCs 'dc01.source-a.example','dc01.source-b.example' `
                              -TargetDC 'target-dc01.target.example' `
                              -BackrefAttribute 'extensionAttribute15'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string[]] $SourceDCs,
    [Parameter(Mandatory)] [string]   $TargetDC,
    [string] $BackrefAttribute = 'extensionAttribute15'
)

$ErrorActionPreference = 'Continue'
$results = @()
function Add-Result {
    param($Check, $Target, $Status, $Detail)
    $script:results += [pscustomobject]@{
        Check = $Check; Target = $Target; Status = $Status; Detail = $Detail
    }
}

Write-Host "`n=== Source → Target sync pre-flight check ===`n" -ForegroundColor Cyan

#region Per-DC checks (legacy)
foreach ($dc in $SourceDCs) {
    Write-Host "[Source DC: $dc]" -ForegroundColor Yellow

    # Reachability
    if (-not (Test-Connection -ComputerName $dc -Count 1 -Quiet)) {
        Add-Result 'Reachability' $dc 'FAIL' "Not reachable via ICMP"
        Write-Host "  unreachable, skipping rest" -ForegroundColor Red
        continue
    }
    Add-Result 'Reachability' $dc 'OK' 'pingable'

    # OS version
    try {
        $os = Invoke-Command -ComputerName $dc -ScriptBlock {
            (Get-CimInstance Win32_OperatingSystem).Caption
        } -ErrorAction Stop
        $supported = $os -match '2016|2019|2022|2025'
        Add-Result 'OS version' $dc $(if($supported){'OK'}else{'WARN'}) $os
    } catch {
        Add-Result 'OS version' $dc 'FAIL' "WinRM failed: $_"
    }

    # RunAsPPL — the big one
    try {
        $ppl = Invoke-Command -ComputerName $dc -ScriptBlock {
            (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' `
                -Name 'RunAsPPL' -ErrorAction SilentlyContinue).RunAsPPL
        }
        if ($ppl -in 1,2) {
            Add-Result 'LSA Protection (RunAsPPL)' $dc 'BLOCKER' `
                "RunAsPPL=$ppl — Microsoft signing required, self-signed will NOT load. See section 3 of docs/ISSUES-AND-RISKS.md"
        } else {
            Add-Result 'LSA Protection (RunAsPPL)' $dc 'OK' 'Not enabled — self-signed cert will work'
        }
    } catch {
        Add-Result 'LSA Protection (RunAsPPL)' $dc 'FAIL' "Could not read: $_"
    }

    # Notification Packages — what's already there?
    try {
        $pkgs = Invoke-Command -ComputerName $dc -ScriptBlock {
            (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' `
                -Name 'Notification Packages').'Notification Packages'
        }
        $known = @{
            'scecli' = 'Microsoft default (KEEP)'
            'rassfm' = 'RAS server filter'
            'SPP3FLT' = 'Specops Password Policy'
            'nppwd' = 'nFront Password Filter'
            'ClusAuthMgr' = 'Failover Cluster auth (RISKY on a DC)'
        }
        $detail = ($pkgs | ForEach-Object {
            if ($known.ContainsKey($_)) { "$_ ($($known[$_]))" }
            elseif ($_ -match 'AzureAD') { "$_ (Entra Password Protection)" }
            else { "$_ (UNKNOWN — investigate)" }
        }) -join ', '

        $hasUnknown = $pkgs | Where-Object {
            -not $known.ContainsKey($_) -and $_ -notmatch 'AzureAD'
        }
        $hasCluster = 'ClusAuthMgr' -in $pkgs

        $status = 'OK'
        if ($hasCluster) { $status = 'BLOCKER' }
        elseif ($hasUnknown) { $status = 'WARN' }

        Add-Result 'Notification Packages' $dc $status $detail
    } catch {
        Add-Result 'Notification Packages' $dc 'FAIL' "Could not read: $_"
    }

    # Failover Cluster feature
    try {
        $cluster = Invoke-Command -ComputerName $dc -ScriptBlock {
            (Get-WindowsFeature -Name Failover-Clustering -ErrorAction SilentlyContinue).InstallState
        }
        if ($cluster -eq 'Installed') {
            Add-Result 'Failover Cluster on DC' $dc 'BLOCKER' 'Cluster role installed on a DC — uninstall before proceeding'
        } else {
            Add-Result 'Failover Cluster on DC' $dc 'OK' 'Not installed'
        }
    } catch {
        Add-Result 'Failover Cluster on DC' $dc 'WARN' "Could not check: $_"
    }

    # Kerberos enc types
    try {
        $enc = Invoke-Command -ComputerName $dc -ScriptBlock {
            (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters' `
                -Name SupportedEncryptionTypes -ErrorAction SilentlyContinue).SupportedEncryptionTypes
        }
        $aesOnly = ($enc -band 0x18) -eq 0x18 -and ($enc -band 0x4) -eq 0
        if ($null -eq $enc) {
            Add-Result 'Kerberos enc types' $dc 'WARN' 'Default (RC4 likely allowed) — set SupportedEncryptionTypes=0x18 for AES only'
        } elseif ($aesOnly) {
            Add-Result 'Kerberos enc types' $dc 'OK' "0x{0:X} (AES only)" -f $enc
        } else {
            Add-Result 'Kerberos enc types' $dc 'WARN' ("0x{0:X} (RC4 still allowed)" -f $enc)
        }
    } catch {
        Add-Result 'Kerberos enc types' $dc 'WARN' "Could not check: $_"
    }
}
#endregion

#region target checks
Write-Host "`n[Target DC: $TargetDC]" -ForegroundColor Yellow

if (-not (Test-Connection -ComputerName $TargetDC -Count 1 -Quiet)) {
    Add-Result 'Reachability' $TargetDC 'FAIL' "Not reachable"
} else {
    Add-Result 'Reachability' $TargetDC 'OK' 'pingable'

    # Check chosen back-reference attribute
    try {
        $populated = Get-ADUser -Server $TargetDC -Filter "$BackrefAttribute -like '*'" `
            -Properties $BackrefAttribute -ErrorAction Stop |
            Measure-Object | Select-Object -ExpandProperty Count
        if ($populated -eq 0) {
            Add-Result "Back-ref attribute ($BackrefAttribute)" $TargetDC 'OK' 'Unused — safe to claim'
        } else {
            Add-Result "Back-ref attribute ($BackrefAttribute)" $TargetDC 'BLOCKER' `
                "$populated user(s) already populated. Pick a different attribute or audit existing values first."
        }
    } catch {
        Add-Result "Back-ref attribute ($BackrefAttribute)" $TargetDC 'FAIL' "Could not query: $_"
    }

    # Audit ALL extension attributes 1-15 so user has a clear picture
    try {
        Write-Host "  scanning extensionAttribute1..15 for usage..."
        for ($i=1; $i -le 15; $i++) {
            $a = "extensionAttribute$i"
            $c = (Get-ADUser -Server $TargetDC -Filter "$a -like '*'" -Properties $a |
                  Measure-Object).Count
            if ($c -gt 0) {
                Add-Result "extensionAttribute audit" $TargetDC 'INFO' "$a populated on $c users"
            }
        }
    } catch {
        Add-Result "extensionAttribute audit" $TargetDC 'WARN' "Audit failed: $_"
    }

    # PSOs in target
    try {
        $psos = Get-ADFineGrainedPasswordPolicy -Server $TargetDC -Filter * -ErrorAction Stop
        if ($psos) {
            $psoNames = ($psos | ForEach-Object { "$($_.Name) (min=$($_.MinPasswordLength))" }) -join '; '
            Add-Result 'Fine-Grained Password Policies (PSOs)' $TargetDC 'INFO' $psoNames
        } else {
            Add-Result 'Fine-Grained Password Policies (PSOs)' $TargetDC 'OK' 'None defined'
        }
    } catch {
        Add-Result 'Fine-Grained Password Policies (PSOs)' $TargetDC 'WARN' "Could not enumerate: $_"
    }

    # Default domain password policy
    try {
        $pol = Get-ADDefaultDomainPasswordPolicy -Server $TargetDC
        Add-Result 'Default password policy (target)' $TargetDC 'INFO' `
            "MinLength=$($pol.MinPasswordLength), Complexity=$($pol.ComplexityEnabled), MaxAge=$($pol.MaxPasswordAge)"
    } catch {
        Add-Result 'Default password policy (target)' $TargetDC 'WARN' "Could not read: $_"
    }

    # LDAPS reachable
    try {
        $tcp = Test-NetConnection -ComputerName $TargetDC -Port 636 -WarningAction SilentlyContinue
        if ($tcp.TcpTestSucceeded) {
            Add-Result 'LDAPS port 636' $TargetDC 'OK' 'reachable'
        } else {
            Add-Result 'LDAPS port 636' $TargetDC 'BLOCKER' 'Not reachable — broker requires LDAPS to set passwords securely'
        }
    } catch {
        Add-Result 'LDAPS port 636' $TargetDC 'WARN' "Test failed: $_"
    }
}
#endregion

#region Summary
Write-Host "`n=== Results ===`n" -ForegroundColor Cyan
$results | Format-Table -AutoSize

$blockers = $results | Where-Object { $_.Status -eq 'BLOCKER' }
$warns    = $results | Where-Object { $_.Status -eq 'WARN' }
$fails    = $results | Where-Object { $_.Status -eq 'FAIL' }

Write-Host ""
if ($blockers) {
    Write-Host "BLOCKERS ($($blockers.Count)) — fix these before proceeding:" -ForegroundColor Red
    $blockers | ForEach-Object { Write-Host "  - [$($_.Target)] $($_.Check): $($_.Detail)" -ForegroundColor Red }
}
if ($warns) {
    Write-Host "WARNINGS ($($warns.Count)) — review:" -ForegroundColor Yellow
    $warns | ForEach-Object { Write-Host "  - [$($_.Target)] $($_.Check): $($_.Detail)" -ForegroundColor Yellow }
}
if ($fails) {
    Write-Host "CHECK FAILURES ($($fails.Count)) — couldn't validate, investigate:" -ForegroundColor Magenta
    $fails | ForEach-Object { Write-Host "  - [$($_.Target)] $($_.Check): $($_.Detail)" -ForegroundColor Magenta }
}
if (-not ($blockers -or $warns -or $fails)) {
    Write-Host "All checks passed. You're clear to proceed." -ForegroundColor Green
}

# Export
$reportPath = Join-Path $PSScriptRoot "preflight-report-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
$results | Export-Csv -Path $reportPath -NoTypeInformation
Write-Host "`nFull report: $reportPath" -ForegroundColor Cyan
#endregion
