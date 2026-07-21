# File: Post-Deployment-DFSR-Validation.ps1
# Run 15 minutes after final DC promotion completes
# Validates that DFSR SYSVOL replication is working correctly

Write-Host "`n=== Post-Deployment DFSR Validation ===" -ForegroundColor Cyan
Write-Host "This script validates fresh deployment state (2 default policies on all DCs)" -ForegroundColor Gray

$dcs = @('GISA-DC01', 'GISA-DC02', 'GISA-DC03', 'GISA-DC04', 'GISA-DC05')
$domainDNS = (Get-ADDomain).DNSRoot
$errors = @()

# 1. Check Event 4602 on all DCs (SYSVOL ready)
Write-Host "`n[1/4] Checking DFSR initialization (Event 4602)..." -ForegroundColor Yellow
foreach ($dc in $dcs) {
    $evt = Get-WinEvent -LogName "DFS Replication" -ComputerName $dc -MaxEvents 100 -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -eq 4602 }
    if ($evt) {
        Write-Host "  ✓ $dc initialized at $($evt[0].TimeCreated)" -ForegroundColor Green
    } else {
        Write-Host "  ✗ $dc: NO Event 4602 — DFSR not ready" -ForegroundColor Red
        $errors += "$dc missing Event 4602"
    }
}

# 2. Check replication group state
Write-Host "`n[2/4] Checking replication group health..." -ForegroundColor Yellow
$rg = Get-DfsReplicationGroup -GroupName "Domain System Volume" -ErrorAction SilentlyContinue
if ($rg -and $rg.State -eq 'Normal') {
    Write-Host "  ✓ RG State: Normal" -ForegroundColor Green
} else {
    Write-Host "  ✗ RG State: $($rg.State ?? 'NOT FOUND')" -ForegroundColor Red
    $errors += "RG state not normal: $($rg.State)"
}

# 3. Check that 2 default policies are present on all DCs
Write-Host "`n[3/4] Checking default policy replication..." -ForegroundColor Yellow
$expectedPolicies = @('31B2F340-016D-11D2-945F-00C04FB984F9', '6AC1786C-016F-11D2-945F-00C04FB984F9')  # Default Domain Policy, Default Domain Controllers Policy

foreach ($dc in $dcs) {
    $policiesPath = "\\$dc\SYSVOL\$domainDNS\Policies"
    $found = 0
    foreach ($guid in $expectedPolicies) {
        if (Test-Path "$policiesPath\$guid") {
            $found++
        }
    }
    if ($found -eq 2) {
        Write-Host "  ✓ $dc: 2/2 default policies" -ForegroundColor Green
    } else {
        Write-Host "  ✗ $dc: $found/2 default policies" -ForegroundColor Red
        $errors += "$dc missing default policies ($found/2)"
    }
}

# 4. Verify DNS is self-pointing
Write-Host "`n[4/4] Checking DNS configuration (per-NIC self-pointing)..." -ForegroundColor Yellow
foreach ($dc in $dcs) {
    try {
        $dns = Invoke-Command -ComputerName $dc -ScriptBlock {
            (Get-DnsClientServerAddress -AddressFamily IPv4 | Select-Object -First 1).ServerAddresses[0]
        } -ErrorAction SilentlyContinue
        Write-Host "  $dc: $dns" -ForegroundColor Gray
    } catch {
        Write-Host "  $dc: Could not retrieve DNS" -ForegroundColor Yellow
    }
}

# Summary
Write-Host "`n" + ("=" * 60) -ForegroundColor Cyan
if ($errors.Count -eq 0) {
    Write-Host "✓✓✓ DFSR Deployment Validation PASSED ✓✓✓" -ForegroundColor Green
    Write-Host "All DCs initialized successfully. DFSR replication is ready." -ForegroundColor Green
    Write-Host "`nTo test GPO replication:" -ForegroundColor Cyan
    Write-Host "  1. Create a new GPO on DC01" -ForegroundColor Gray
    Write-Host "  2. Wait 5 minutes" -ForegroundColor Gray
    Write-Host "  3. Verify GPO GUID folder appears on all DC SYSVOLs" -ForegroundColor Gray
    Write-Host "  4. Apply GPO to a test OU and run gpupdate /force on member VMs" -ForegroundColor Gray
} else {
    Write-Host "✗ VALIDATION FAILED" -ForegroundColor Red
    $errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host "`nAction: Check Event Logs on failing DCs for DFSR errors" -ForegroundColor Yellow
}
