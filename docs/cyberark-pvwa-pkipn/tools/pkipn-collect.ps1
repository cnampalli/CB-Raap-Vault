<#
.SYNOPSIS
  Collect the evidence for ONE certificate-login attempt on a PVWA server, into a zip.

.DESCRIPTION
  Run on the PVWA server that will serve the attempt, as Administrator, in Windows PowerShell 5.1.
    1. Run the script. It turns the CAPI2 certificate log on (if it was off) and notes the time.
    2. Try the certificate login ONCE from a workstation (new InPrivate window).
    3. Press Enter. The script collects only what happened in between, and zips it.

  Collected: IIS log lines, IIS Failed Request Tracing files (if tracing is on, see 09), CAPI2 and
  Schannel events (.evtx + a readable summary), the tail of the PVWA application logs.
  Changes: turns the CAPI2 log on for the attempt and back to its previous state afterwards; flushes
  the IIS log buffer so the latest lines are on disk. Nothing else. No private keys or passwords are
  collected. Review the zip before sending it outside your organisation.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\pkipn-collect.ps1
#>
param(
  [string]$OutRoot = 'C:\temp',
  [string]$PvwaLogDir = 'C:\Windows\Temp\PVWA',
  [string]$IisLogDir = 'C:\inetpub\logs\LogFiles',
  [string]$FrebDir = 'C:\inetpub\logs\FailedReqLogFiles'
)
$ErrorActionPreference = 'Continue'
$capiLog = 'Microsoft-Windows-CAPI2/Operational'

# ---- before the attempt
$capi = Get-WinEvent -ListLog $capiLog -ErrorAction SilentlyContinue
$capiWasOn = [bool]($capi -and $capi.IsEnabled)
if (-not $capiWasOn) { wevtutil sl $capiLog /e:true | Out-Null; Write-Host 'CAPI2 log turned on for this attempt.' }

$start = Get-Date
Write-Host ''
Write-Host '=================================================================='
Write-Host " Ready ($($start.ToString('HH:mm:ss'))). Now, on the workstation:"
Write-Host '   1. Open a NEW InPrivate / Incognito window'
Write-Host '   2. Go to the PVWA, choose the certificate (PKIPN) login, pick the certificate'
Write-Host '   3. Wait for the error (or success)'
Write-Host ' Then come back here and press Enter.'
Write-Host '=================================================================='
[void](Read-Host)
Start-Sleep -Seconds 3
$end = Get-Date

# ---- collect
$out = Join-Path $OutRoot ("pkipn-evidence-{0}-{1}" -f $env:COMPUTERNAME, $start.ToString('yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $out -Force | Out-Null
$sum = Join-Path $out 'summary.txt'
function S([string]$t) { Write-Host $t; Add-Content -Path $sum -Value $t }
S ("Attempt window: {0} -> {1} (server local time)  on {2}" -f $start, $end, $env:COMPUTERNAME)

# IIS log lines (IIS writes UTC times, and buffers: flush first)
netsh http flush logbuffer | Out-Null
S ''; S '== IIS requests in the window (near the end of each line: status substatus win32-status) =='
$fromUtc = $start.ToUniversalTime().AddMinutes(-1)
$iisOut = Join-Path $out 'iis-lines.txt'
$iisLines = New-Object System.Collections.Generic.List[string]
Get-ChildItem $IisLogDir -Recurse -Filter 'u_ex*.log' -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -ge $start.AddMinutes(-2) } | ForEach-Object {
    $iisLines.Add("# file: $($_.FullName)")
    $sr = New-Object IO.StreamReader([IO.File]::Open($_.FullName, 'Open', 'Read', 'ReadWrite'))   # IIS keeps the file open
    while ($null -ne ($line = $sr.ReadLine())) {
      if ($line -like '#Fields*') { $iisLines.Add($line); continue }
      if ($line -like '#*') { continue }
      $f = $line -split ' '
      $t = [datetime]::MinValue
      if ([datetime]::TryParseExact("$($f[0]) $($f[1])", 'yyyy-MM-dd HH:mm:ss', $null, 'None', [ref]$t) -and $t -ge $fromUtc) { $iisLines.Add($line) }
    }
    $sr.Close()
  }
if ($iisLines | Where-Object { $_ -notlike '#*' }) { $iisLines | Set-Content $iisOut }
if (Test-Path $iisOut) {
  Get-Content $iisOut | Where-Object { $_ -match '/auth/' } | ForEach-Object { S "  $_" }
} else { S '  (no IIS lines - did the attempt reach THIS server? Behind a load balancer, run on each server or target one directly)' }
S '  403 7 = no certificate sent | 403 16 = not trusted | 403 13 = revoked/CRL unreachable | 403 17 = expired | 200 = IIS accepted it (look at PVWA logs)'

# Event logs as .evtx for support, limited to the window
$ms = [int](($end - $start).TotalMilliseconds + 60000)
wevtutil epl $capiLog (Join-Path $out 'capi2.evtx') "/q:*[System[TimeCreated[timediff(@SystemTime) <= $ms]]]" 2>$null
wevtutil epl System (Join-Path $out 'schannel.evtx') "/q:*[System[Provider[@Name='Schannel'] and TimeCreated[timediff(@SystemTime) <= $ms]]]" 2>$null

# CAPI2 readable summary: chain checks done by lsass (= IIS/Schannel) in the window
S ''; S '== Certificate checks by IIS (CAPI2, process lsass) =='
$found = $false
Get-WinEvent -FilterHashtable @{ LogName = $capiLog; StartTime = $start.AddMinutes(-1); EndTime = $end } -ErrorAction SilentlyContinue |
  Where-Object { $_.Id -in 11, 30 } | ForEach-Object {
    try { $x = [xml]$_.ToXml() } catch { return }
    $aux = $x.SelectSingleNode("//*[local-name()='EventAuxInfo']")
    if (-not $aux -or $aux.GetAttribute('ProcessName') -notmatch 'lsass') { return }
    $found = $true
    $res = $x.SelectSingleNode("//*[local-name()='Result']")
    $c1 = $x.SelectSingleNode("//*[local-name()='Certificate'][@subjectName]")
    S ("  {0} id={1} result={2} cert={3} [{4}]" -f $_.TimeCreated, $_.Id,
       $(if ($res) { $res.GetAttribute('value') } else { '' }),
       $(if ($c1) { $c1.GetAttribute('subjectName') } else { '' }),
       $(if ($c1) { $c1.GetAttribute('fileRef') -replace '\.cer$', '' } else { '' }))
  }
if (-not $found) { S '  (none: no certificate reached IIS, or the attempt went to another server)' }
S '  result 0 = OK | 800B0109 = untrusted root (see 02 Step 2/3) | 80092013 = revocation offline (02 Step 4) | 800B0101 = expired'

# Failed Request Tracing files written during the window
$freb = @(Get-ChildItem $FrebDir -Recurse -Include 'fr*.xml', 'freb.xsl' -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'freb.xsl' -or $_.LastWriteTime -ge $start })
if ($freb) { $d = New-Item -ItemType Directory (Join-Path $out 'freb') -Force; $freb | Copy-Item -Destination $d.FullName; S ''; S "== $(@($freb | ? Name -ne 'freb.xsl').Count) Failed Request Tracing file(s) copied to freb\ (open in Edge) ==" }
else { S ''; S '== No Failed Request Tracing files (optional: turn it on, see 09) ==' }

# PVWA application logs touched during the window (last 3000 lines each)
S ''; S '== PVWA logs (files changed during the attempt; lines mentioning auth/PKI shown here, full tail in pvwa\) =='
if (Test-Path $PvwaLogDir) {
  $d = New-Item -ItemType Directory (Join-Path $out 'pvwa') -Force
  Get-ChildItem $PvwaLogDir -File | Where-Object { $_.LastWriteTime -ge $start.AddMinutes(-1) } | ForEach-Object {
    $tail = Get-Content $_.FullName -Tail 3000
    $tail | Set-Content (Join-Path $d.FullName $_.Name)
    S "--- $($_.Name)"
    $tail | Select-String -Pattern 'pki|certificate|auth/|logon|error|exception|ITA' | Select-Object -Last 20 | ForEach-Object { S ("  " + $_.Line.Trim()) }
  }
} else { S "  PVWA log folder not found: $PvwaLogDir" }

# ---- restore and zip
if (-not $capiWasOn) { wevtutil sl $capiLog /e:false | Out-Null; S ''; S 'CAPI2 log set back to off.' }
$zip = "$out.zip"
Compress-Archive -Path "$out\*" -DestinationPath $zip -Force
S ''
S "Done. Send: $zip"
S 'Also useful (not collected here): the Vault server ITALog.log lines at the same time, and the error text PVWA showed.'
