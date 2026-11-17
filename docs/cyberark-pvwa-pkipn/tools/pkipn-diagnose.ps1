<#
.SYNOPSIS
  Read-only PKIPN diagnostics for a CyberArk PVWA server (Self-Hosted 14.x).

.DESCRIPTION
  Run on EACH PVWA server, as Administrator, in Windows PowerShell 5.1.
  Changes nothing. Writes a report to .\pkipn-report-<host>-<time>.txt and the screen.

  Stage 2  IIS client-certificate settings, HTTPS binding (netsh), TLS 1.3
  Stage 3  user certificate chain + revocation from THIS server, Root store hygiene, proxy
  Stage 4  UPN / EKU in the user certificate, PKIPN DLL locations, PKI lines in web.config
  Logs     latest IIS 403s on PKI paths, CAPI2 log state, PVWA log lines mentioning PKI

.PARAMETER UserCert
  Path to the user's PUBLIC certificate (.cer, DER or Base64). Never a .pfx.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\pkipn-diagnose.ps1 -UserCert C:\temp\user.cer
#>
param(
  [Parameter(Mandatory = $true)][string]$UserCert,
  [string]$PvwaRoot = 'C:\inetpub\wwwroot\PasswordVault',
  [string]$SiteName = 'Default Web Site',
  [string]$PvwaLogDir = 'C:\Windows\Temp\PVWA'
)

$ErrorActionPreference = 'Continue'
$report = Join-Path (Get-Location) ("pkipn-report-{0}-{1}.txt" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
$X = 'System.Security.Cryptography.X509Certificates'
function Out-R([string]$t) { Write-Host $t; Add-Content -Path $report -Value $t }
function Head([string]$t) { Out-R ''; Out-R ('=' * 78); Out-R "== $t"; Out-R ('=' * 78) }
function Res([string]$state, [string]$t) { Out-R ("[{0}] {1}" -f $state, $t) }

Head "PKIPN diagnostics on $env:COMPUTERNAME at $(Get-Date -Format s)"
Out-R ("OS: {0}  build {1}" -f (Get-CimInstance Win32_OperatingSystem).Caption, [Environment]::OSVersion.Version)

# ---------------------------------------------------------------- user certificate
Head 'STAGE 4a - User certificate content (what PKIPN reads)'
if (-not (Test-Path $UserCert)) { Res 'FAIL' "UserCert not found: $UserCert"; return }
$cert = New-Object "$X.X509Certificate2" (Resolve-Path $UserCert).Path
if ($cert.HasPrivateKey) { Res 'WARN' 'This file contains a PRIVATE KEY. Use the public .cer only.' }
Out-R "Subject : $($cert.Subject)"
Out-R "Issuer  : $($cert.Issuer)"
Out-R "Valid   : $($cert.NotBefore) -> $($cert.NotAfter)"
Out-R "Thumb   : $($cert.Thumbprint)"
$now = Get-Date
if ($now -lt $cert.NotBefore -or $now -gt $cert.NotAfter) { Res 'FAIL' 'Certificate not valid now (IIS 403.17)' } else { Res 'OK' 'Within validity dates' }

$san = $cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' }
if ($san) {
  $sanText = $san.Format($true)
  Out-R "SAN:`n$sanText"
  $m = [regex]::Match($sanText, 'Principal Name=(\S+)')
  if ($m.Success) { Res 'OK' ("UPN (Principal Name) = {0}  <- must equal the Vault user name" -f $m.Groups[1].Value) }
  else { Res 'FAIL' 'No Principal Name (UPN) in the SAN. PKIPN cannot identify the user. Reissue with a UPN SAN.' }
} else { Res 'FAIL' 'No Subject Alternative Name extension. PKIPN cannot identify the user.' }

$eku = $cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' }
if ($eku) {
  $ekus = @($eku.EnhancedKeyUsages | ForEach-Object { "$($_.FriendlyName) ($($_.Value))" })
  Out-R ("EKU: {0}" -f ($ekus -join '; '))
  if ($eku.EnhancedKeyUsages | Where-Object { $_.Value -eq '1.3.6.1.5.5.7.3.2' }) { Res 'OK' 'Client Authentication EKU present' }
  else { Res 'FAIL' 'Client Authentication EKU (1.3.6.1.5.5.7.3.2) missing' }
} else { Res 'WARN' 'No EKU extension (any purpose). ValidatePKICertificate=Yes may refuse it' }

$bc = $cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.19' }
if ($bc -and $bc.CertificateAuthority) { Res 'FAIL' 'This is a CA certificate, not a user certificate' }
if ($cert.Subject -eq $cert.Issuer) { Res 'FAIL' 'Self-signed certificate' }

# ---------------------------------------------------------------- chain + revocation
Head 'STAGE 3 - Chain and revocation as THIS server sees it (IIS 403.16 / 403.13)'
$chain = New-Object "$X.X509Chain"
$chain.ChainPolicy.RevocationMode = 'Online'
$chain.ChainPolicy.RevocationFlag = 'EntireChain'
$chain.ChainPolicy.UrlRetrievalTimeout = New-TimeSpan -Seconds 20
$ok = $chain.Build($cert)
$i = 0
foreach ($e in $chain.ChainElements) {
  $c = $e.Certificate
  $st = ($e.ChainElementStatus | ForEach-Object { $_.Status }) -join ','
  if (-not $st) { $st = 'OK' }
  Out-R ("  [{0}] {1}`n       issuer: {2}`n       status: {3}" -f $i, $c.Subject, $c.Issuer, $st)
  $i++
}
if ($ok) { Res 'OK' 'Chain builds to a trusted root and revocation checks passed' }
else {
  $chain.ChainStatus | ForEach-Object { Res 'FAIL' ("{0}: {1}" -f $_.Status, $_.StatusInformation.Trim()) }
  Out-R '  UntrustedRoot -> root not in LocalMachine\Root | PartialChain -> intermediate missing'
  Out-R '  RevocationStatusUnknown/OfflineRevocation -> CRL/OCSP unreachable from this server (proxy/firewall)'
}
$last = if ($chain.ChainElements.Count -gt 0) { $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate } else { $null }
if ($last -and $last.Subject -eq $last.Issuer) {
  $inRoot = Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Thumbprint -eq $last.Thumbprint }
  if ($inRoot) { Res 'OK' 'Root is in LocalMachine\Root' } else { Res 'FAIL' 'Root is NOT in LocalMachine\Root (maybe only in CurrentUser)' }
}

Out-R ''
Out-R 'CRL / AIA URLs in the user certificate (must be reachable from this server):'
foreach ($oid in '2.5.29.31', '1.3.6.1.5.5.7.1.1') {
  $x = $cert.Extensions | Where-Object { $_.Oid.Value -eq $oid }
  if ($x) { Out-R $x.Format($true) }
}

Head 'STAGE 3 - LocalMachine\Root hygiene (non-self-signed certs here break client auth -> 403.16)'
$bad = Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -ne $_.Issuer }
if ($bad) { $bad | ForEach-Object { Res 'FAIL' ("Not self-signed, move to Intermediate CAs: {0} [{1}]" -f $_.Subject, $_.Thumbprint) } }
else { Res 'OK' 'Only self-signed certificates in LocalMachine\Root' }

Head 'STAGE 3 - Machine proxy used for CRL/OCSP downloads'
(netsh winhttp show proxy) | ForEach-Object { Out-R $_ }

# ---------------------------------------------------------------- IIS
Head 'STAGE 2 - HTTPS bindings (netsh http show sslcert)'
(netsh http show sslcert) | ForEach-Object { Out-R $_ }
Out-R 'Check: Verify Client Certificate Revocation=Enabled; CTL Store Name empty or includes the external CA;'
Out-R '       Negotiate Client Certificate=Enabled if TLS 1.3 is on.'

Head 'STAGE 2 - TLS 1.3 server state'
$t13 = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.3\Server'
if (Test-Path $t13) { Get-ItemProperty $t13 | Select-Object Enabled, DisabledByDefault | Format-List | Out-String | ForEach-Object { Out-R $_ } }
else { Out-R 'No explicit TLS 1.3 server key: OS default (on by default on Windows Server 2022+)' }

Head 'STAGE 2 - IIS client-certificate setting (sslFlags) per PVWA path'
try {
  Import-Module WebAdministration -ErrorAction Stop
  $authDirs = @()
  foreach ($d in 'auth', 'api\auth') {
    $p = Join-Path $PvwaRoot $d
    if (Test-Path $p) { $authDirs += Get-ChildItem $p -Directory | ForEach-Object { ($d -replace '\\', '/') + '/' + $_.Name } }
  }
  Out-R ("Physical folders under PasswordVault\auth / api\auth: {0}" -f (($authDirs | Sort-Object) -join ', '))
  $locs = @("$SiteName", "$SiteName/PasswordVault") + ($authDirs | ForEach-Object { "$SiteName/PasswordVault/$_" }) +
          @("$SiteName/PasswordVault/auth/pki", "$SiteName/PasswordVault/auth/pkipn", "$SiteName/PasswordVault/api/auth/pkipn")
  foreach ($loc in ($locs | Select-Object -Unique)) {
    $f = Get-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Location $loc -Filter 'system.webServer/security/access' -Name sslFlags -ErrorAction SilentlyContinue
    Out-R ("  {0,-55} sslFlags = {1}" -f $loc, $f)
  }
  Out-R 'Expect: SslRequireCert ONLY on the PKI login folder; no SslRequireCert on the site or PasswordVault root.'
  $map = Get-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Location "$SiteName/PasswordVault" -Filter 'system.webServer/security/authentication/iisClientCertificateMappingAuthentication' -Name enabled -ErrorAction SilentlyContinue
  if ($map -and $map.Value) { Res 'WARN' 'IIS client certificate mapping is enabled on PasswordVault (can cause 403.12)' }
} catch { Res 'WARN' "WebAdministration module not available: $($_.Exception.Message)" }

# ---------------------------------------------------------------- PVWA files
Head 'STAGE 4b - PKIPN module files'
$dlls = Get-ChildItem $PvwaRoot -Recurse -Filter '*PKI*.dll' -ErrorAction SilentlyContinue
if ($dlls) { $dlls | ForEach-Object { Out-R ("  {0}  ({1})  {2}" -f $_.FullName, $_.Length, $_.LastWriteTime) } }
else { Res 'FAIL' "No *PKI*.dll under $PvwaRoot" }
$cad = Join-Path $PvwaRoot 'CustomAuthenticationDlls'
if (Test-Path $cad) { Res 'OK' "CustomAuthenticationDlls exists" } else { Res 'INFO' "No CustomAuthenticationDlls folder (needed if your 14.6 doc page says so)" }

Head 'STAGE 4b - PKI-related lines in web.config (Bin is the one PVWA uses; Env shown for comparison)'
foreach ($w in (Join-Path $PvwaRoot 'Bin\web.config'), (Join-Path $PvwaRoot 'Env\web.config'), (Join-Path $PvwaRoot 'web.config')) {
  if (Test-Path $w) {
    Out-R "--- $w"
    Select-String -Path $w -Pattern 'pkipn|pki|Issuer|ClientCert' -AllMatches | ForEach-Object { Out-R ("  {0,5}: {1}" -f $_.LineNumber, $_.Line.Trim()) }
  }
}

# ---------------------------------------------------------------- logs
Head 'LOGS - latest IIS requests on PKI paths (status substatus win32)'
$logDir = 'C:\inetpub\logs\LogFiles'
$lf = Get-ChildItem $logDir -Recurse -Filter 'u_ex*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($lf) {
  Out-R "File: $($lf.FullName)"
  Get-Content $lf.FullName -Tail 5000 | Where-Object { $_ -match '/auth/pki|pkipn' } | Select-Object -Last 25 | ForEach-Object { Out-R "  $_" }
  Out-R 'Read sc-status sc-substatus: 403 7=no cert sent, 16=untrusted, 13=revoked/CRL unreachable, 17=expired, 12=mapping'
} else { Res 'INFO' "No IIS logs under $logDir" }

Head 'LOGS - CAPI2 (certificate chain/revocation events)'
$capi = Get-WinEvent -ListLog 'Microsoft-Windows-CAPI2/Operational' -ErrorAction SilentlyContinue
if ($capi -and $capi.IsEnabled) {
  Get-WinEvent -LogName 'Microsoft-Windows-CAPI2/Operational' -MaxEvents 300 -ErrorAction SilentlyContinue |
    Where-Object { $_.LevelDisplayName -eq 'Error' } | Select-Object -First 10 |
    ForEach-Object { Out-R ("  {0} id={1} {2}" -f $_.TimeCreated, $_.Id, ($_.Message -split "`n")[0]) }
} else { Res 'INFO' 'CAPI2 log disabled. Enable: wevtutil sl Microsoft-Windows-CAPI2/Operational /e:true  then retry the login and re-run' }

Head 'LOGS - Schannel errors (last 24 h)'
Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Schannel'; StartTime = (Get-Date).AddDays(-1) } -MaxEvents 10 -ErrorAction SilentlyContinue |
  ForEach-Object { Out-R ("  {0} id={1} {2}" -f $_.TimeCreated, $_.Id, ($_.Message -split "`n")[0]) }

Head "LOGS - PVWA log lines mentioning PKI ($PvwaLogDir)"
if (Test-Path $PvwaLogDir) {
  Get-ChildItem $PvwaLogDir -File | Sort-Object LastWriteTime -Descending | Select-Object -First 3 | ForEach-Object {
    Out-R "--- $($_.FullName)"
    Select-String -Path $_.FullName -Pattern 'pki|certificate|PKIPN' | Select-Object -Last 15 | ForEach-Object { Out-R ("  {0}" -f $_.Line.Trim()) }
  }
} else { Res 'INFO' "PVWA log folder not found: $PvwaLogDir" }

Head 'DONE'
Out-R "Report: $report"
Out-R 'Share this report. It holds no private keys or passwords; review it before sending outside your organisation.'
