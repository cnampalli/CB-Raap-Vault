<#
.SYNOPSIS
  Read-only PKIPN diagnostics for a CyberArk PVWA server (Self-Hosted 14.x).

.DESCRIPTION
  Run on EACH PVWA server, as Administrator, in Windows PowerShell 5.1.
  Changes nothing. Writes a report to .\pkipn-report-<host>-<time>.txt and the screen.

  Stage 2  IIS client-certificate settings, HTTPS binding (netsh), TLS 1.3
  Stage 3  user certificate chain + revocation from THIS server, Root store hygiene, proxy,
           and a connection test to every CRL/OCSP/AIA URL: direct, through the netsh winhttp
           proxy (the path IIS uses) and, with -Proxy, through an explicit proxy
  Stage 4  UPN / EKU in the user certificate, PKIPN DLL locations, PKI lines in web.config
  Logs     latest IIS 403s on PKI paths, CAPI2 log state, PVWA log lines mentioning PKI

.PARAMETER UserCert
  Path to the user's PUBLIC certificate (.cer, DER or Base64). Never a .pfx.

.PARAMETER Proxy
  Optional host:port of a proxy to test as well (e.g. before running netsh winhttp set proxy).

.PARAMETER SkipUrlTests
  Skip the outbound connection tests to the CRL/OCSP/AIA URLs.

.PARAMETER UrlTimeoutSec
  Timeout per connection test (default 10 seconds).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\pkipn-diagnose.ps1 -UserCert C:\temp\user.cer

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\pkipn-diagnose.ps1 -UserCert C:\temp\user.cer -Proxy 10.0.0.5:3128
#>
param(
  [Parameter(Mandatory = $true)][string]$UserCert,
  [string]$PvwaRoot = 'C:\inetpub\wwwroot\PasswordVault',
  [string]$SiteName = 'Default Web Site',
  [string]$PvwaLogDir = 'C:\Windows\Temp\PVWA',
  [string]$Proxy,
  [switch]$SkipUrlTests,
  [int]$UrlTimeoutSec = 10
)

$ErrorActionPreference = 'Continue'
$scriptStart = Get-Date   # CAPI2 events after this are from this script, not from a login
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
  $revOnly = $true
  foreach ($cs in $chain.ChainStatus) {
    if ("$($cs.Status)" -in 'RevocationStatusUnknown', 'OfflineRevocation') { Res 'WARN' ("{0}: {1}" -f $cs.Status, $cs.StatusInformation.Trim()) }
    else { $revOnly = $false; Res 'FAIL' ("{0}: {1}" -f $cs.Status, $cs.StatusInformation.Trim()) }
  }
  Out-R '  UntrustedRoot -> root not in LocalMachine\Root | PartialChain -> intermediate missing'
  Out-R '  RevocationStatusUnknown/OfflineRevocation -> CRL/OCSP unreachable (proxy/firewall). NOTE: this check runs as'
  Out-R ("  {0}, with your user's proxy and URL cache. IIS checks as SYSTEM via the netsh winhttp proxy." -f [Security.Principal.WindowsIdentity]::GetCurrent().Name)
  Out-R '  If chunk 02 Step 4 (certutil -verify -urlfetch as SYSTEM) passes, these WARN lines do not affect the login.'
  if ($revOnly) { Res 'OK' 'Chain itself builds to a trusted root (only revocation differs, see above)' }
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
if ($bad) {
  $phys = [ordered]@{
    'LocalMachine (certlm.msc, removable here)'  = 'HKLM:\SOFTWARE\Microsoft\SystemCertificates\ROOT\Certificates'
    'GroupPolicy (a GPO pushes it back)'          = 'HKLM:\SOFTWARE\Policies\Microsoft\SystemCertificates\Root\Certificates'
    'Enterprise (published in AD, comes back)'     = 'HKLM:\SOFTWARE\Microsoft\EnterpriseCertificates\Root\Certificates'
  }
  foreach ($b in $bad) {
    Res 'FAIL' ("Not self-signed, move to Intermediate CAs: {0} [{1}]" -f $b.Subject, $b.Thumbprint)
    Out-R ("       issuer: {0}" -f $b.Issuer)
    $where = @($phys.Keys | Where-Object { Test-Path (Join-Path $phys[$_] $b.Thumbprint) })
    Out-R ("       stored in: {0}" -f $(if ($where) { $where -join '; ' } else { 'unknown physical store' }))
    if ($where -match 'GroupPolicy') { Out-R '       -> find the GPO: gpresult /scope computer /h C:\temp\gp.html (Public Key Policies > Trusted Root)' }
    $inCA = Get-ChildItem Cert:\LocalMachine\CA | Where-Object { $_.Thumbprint -eq $b.Thumbprint }
    Out-R ("       also in Intermediate CAs: {0}" -f $(if ($inCA) { 'yes' } else { 'no (import it there before removing from Root)' }))
    $parent = Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -eq $b.Issuer -and $_.Subject -eq $_.Issuer }
    Out-R ("       its own root in Root: {0}" -f $(if ($parent) { "yes [$($parent[0].Thumbprint)]" } else { 'NO - add that root first, or chains through this CA (e.g. the PVWA web cert) break' }))
  }
  Out-R '  Fix: chunk 02 Step 2 (Step 3 if stored in GroupPolicy/Enterprise). Reboot afterwards.'
}
else { Res 'OK' 'Only self-signed certificates in LocalMachine\Root' }
$rootsInCA = @(Get-ChildItem Cert:\LocalMachine\CA | Where-Object { $_.Subject -eq $_.Issuer -and $_.Subject -ne 'CN=Root Agency' })
foreach ($r in $rootsInCA) {
  $alsoRoot = Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Thumbprint -eq $r.Thumbprint }
  if ($alsoRoot) { Out-R ("  [INFO] Self-signed cert in Intermediate CAs, also in Root (harmless): {0}" -f $r.Subject) }
  else { Res 'WARN' ("Self-signed (root) cert only in Intermediate CAs, NOT in Root - chains to it are untrusted: {0} [{1}]. Import it to Root." -f $r.Subject, $r.Thumbprint) }
}

Head 'STAGE 3 - Schannel client-auth trust mode and Client Authentication Issuers store (403.16 0x800B0109)'
$sch = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL' -ErrorAction SilentlyContinue
$mode = if ($sch -and $null -ne $sch.ClientAuthTrustMode) { $sch.ClientAuthTrustMode } else { 0 }
Out-R ("ClientAuthTrustMode = {0}  (0 = machine trust/default, 1 = exclusive root trust, 2 = exclusive CA trust)" -f $mode)
$cai = @(Get-ChildItem Cert:\LocalMachine\ClientAuthIssuer -ErrorAction SilentlyContinue)
Out-R ("Client Authentication Issuers store: {0} certificate(s)" -f $cai.Count)
$cai | ForEach-Object { Out-R ("  {0} [{1}]" -f $_.Subject, $_.Thumbprint) }
if ($mode -ne 0 -and $chain.ChainElements.Count -gt 1) {
  $need = if ($mode -eq 1) { $last } else { $chain.ChainElements[1].Certificate }
  if ($need -and ($cai | Where-Object { $_.Thumbprint -eq $need.Thumbprint })) { Res 'OK' "Required issuer is in ClientAuthIssuer: $($need.Subject)" }
  elseif ($need) { Res 'FAIL' "Trust mode $mode needs this in ClientAuthIssuer: $($need.Subject). certutil -addstore ClientAuthIssuer <file>.cer, then reboot" }
}

Head 'STAGE 3 - Machine proxy used for CRL/OCSP downloads'
(netsh winhttp show proxy) | ForEach-Object { Out-R $_ }

Head 'STAGE 3 - Reachability of revocation and AIA URLs (direct and via proxy)'
if ($SkipUrlTests) { Out-R 'Skipped (-SkipUrlTests).' }
else {
  $ms = [Math]::Max(1, $UrlTimeoutSec) * 1000
  $winHttpErr = @{ 12002 = 'timeout'; 12007 = 'name not resolved'; 12029 = 'cannot connect'; 12030 = 'connection aborted';
                   12152 = 'invalid server response'; 12157 = 'TLS error'; 12175 = 'TLS certificate error'; 12180 = 'proxy auto-detect failed' }

  function Get-DnsText([string]$h) {
    try { return ((([System.Net.Dns]::GetHostAddresses($h)) | ForEach-Object { $_.IPAddressToString }) -join ', ') } catch { return $null }
  }
  function Test-Tcp([string]$h, [int]$port) {
    $tc = New-Object System.Net.Sockets.TcpClient
    try {
      $ar = $tc.BeginConnect($h, $port, $null, $null)
      if (-not $ar.AsyncWaitHandle.WaitOne($ms)) { return 'no answer (timeout: blocked or filtered)' }
      try { $tc.EndConnect($ar); return 'open' }
      catch { $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }; return ('failed: ' + $e.Message) }
    } catch { $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }; return ('failed: ' + $e.Message) }
    finally { $tc.Close() }
  }
  # mode 0 = pre-configured (netsh winhttp, what IIS/CAPI2 use), 1 = direct (no proxy), 2 = explicit proxy
  function Test-Http([string]$url, [int]$mode, [string]$proxyServer) {
    try {
      $r = New-Object -ComObject WinHttp.WinHttpRequest.5.1
      if ($mode -eq 2) { [void]$r.SetProxy(2, $proxyServer, '<local>') } else { [void]$r.SetProxy($mode) }
      [void]$r.SetTimeouts($ms, $ms, $ms, $ms)
      [void]$r.Open('GET', $url, $false)
      [void]$r.Send()
      return [pscustomobject]@{ Ok = $true; Status = [int]$r.Status; Text = ("HTTP {0} {1}" -f $r.Status, $r.StatusText) }
    } catch {
      $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
      $code = $e.HResult -band 0xFFFF
      $name = if ($winHttpErr.ContainsKey($code)) { $winHttpErr[$code] } else { 'error' }
      return [pscustomobject]@{ Ok = $false; Status = 0; Text = ("WinHTTP {0} ({1}): {2}" -f $code, $name, (($e.Message -split "`n")[0]).Trim()) }
    }
  }
  # Reachable = the server answered the request. For OCSP a plain GET is not a valid OCSP request,
  # so 400/404/405 still prove the responder is reachable. 403/407/5xx usually come from a proxy.
  function Test-Reach($res, [string]$kind) {
    if (-not $res.Ok) { return $false }
    if ($res.Status -ge 200 -and $res.Status -lt 400) { return $true }
    if ($kind -eq 'OCSP' -and $res.Status -in 400, 404, 405) { return $true }
    return $false
  }

  # Proxy settings and proxy reachability
  $nh = @(netsh winhttp show proxy)
  $winhttpProxySet = -not ($nh -match 'Direct access')
  $nhProxy = $null
  if ($winhttpProxySet) {
    $line = $nh | Where-Object { $_ -match 'Proxy Server' } | Select-Object -First 1
    if ($line -match '([A-Za-z0-9\.\-]+):(\d+)') { $nhProxy = @{ Host = $Matches[1]; Port = [int]$Matches[2] } }
  }
  if ($nhProxy) { Out-R ("netsh winhttp proxy {0}:{1} - TCP: {2}" -f $nhProxy.Host, $nhProxy.Port, (Test-Tcp $nhProxy.Host $nhProxy.Port)) }
  else { Out-R 'netsh winhttp: Direct access (no machine proxy). The machine-proxy test below is then the same as direct.' }
  $exProxy = $null
  if ($Proxy) {
    if ($Proxy -match '^(?:https?://)?([A-Za-z0-9\.\-]+):(\d+)$') {
      $exProxy = "{0}:{1}" -f $Matches[1], $Matches[2]
      Out-R ("-Proxy {0} - TCP: {1}" -f $exProxy, (Test-Tcp $Matches[1] ([int]$Matches[2])))
    } else { Res 'WARN' "-Proxy '$Proxy' not understood; use host:port, e.g. 10.0.0.5:3128" }
  }

  # Collect URLs from the user certificate and every non-root CA in the chain
  $urlItems = New-Object System.Collections.Generic.List[object]
  $certsToScan = @($cert) + @($chain.ChainElements | ForEach-Object { $_.Certificate } | Where-Object { $_.Subject -ne $_.Issuer -and $_.Thumbprint -ne $cert.Thumbprint })
  foreach ($c in $certsToScan) {
    foreach ($oid in '2.5.29.31', '1.3.6.1.5.5.7.1.1') {
      $ext = $c.Extensions | Where-Object { $_.Oid.Value -eq $oid }
      if (-not $ext) { continue }
      $kind = if ($oid -eq '2.5.29.31') { 'CRL' } else { 'AIA' }
      foreach ($l in ($ext.Format($true) -split "`r?`n")) {
        if ($l -match '1\.3\.6\.1\.5\.5\.7\.48\.1') { $kind = 'OCSP' }
        elseif ($l -match '1\.3\.6\.1\.5\.5\.7\.48\.2') { $kind = 'AIA' }
        if ($l -match 'URL=(\S+)') {
          $u = $Matches[1].TrimEnd(',')
          if (-not ($urlItems | Where-Object { $_.Url -eq $u })) {
            $urlItems.Add([pscustomobject]@{ Url = $u; Kind = $kind; From = ($c.Subject -split ',')[0] })
          }
        }
      }
    }
  }
  if ($urlItems.Count -eq 0) { Res 'INFO' 'No CRL/AIA URLs found in the certificate chain.' }

  $kindOk = @{ CRL = $false; OCSP = $false; AIA = $false }
  $kindSeen = @{ CRL = $false; OCSP = $false; AIA = $false }
  foreach ($it in $urlItems) {
    Out-R ''
    Out-R ("[{0}] {1}   (from {2})" -f $it.Kind, $it.Url, $it.From)
    try { $uri = [Uri]$it.Url } catch { Res 'WARN' '  not a valid URL'; continue }
    $dns = Get-DnsText $uri.Host
    Out-R ("  DNS {0}: {1}" -f $uri.Host, $(if ($dns) { $dns } else { 'not resolved by this server (fine if the proxy resolves it)' }))

    if ($uri.Scheme -eq 'ldap') {
      $p = if ($uri.Port -gt 0) { $uri.Port } else { 389 }
      Out-R ("  Direct TCP {0}:{1}: {2}" -f $uri.Host, $p, (Test-Tcp $uri.Host $p))
      Res 'INFO' '  LDAP cannot go through an HTTP proxy. Harmless if an http:// URL of the same kind is reachable.'
      continue
    }
    if ($uri.Scheme -notin 'http', 'https') { Res 'INFO' ("  scheme {0} not tested" -f $uri.Scheme); continue }

    $kindSeen[$it.Kind] = $true
    Out-R ("  Direct TCP {0}:{1}: {2}" -f $uri.Host, $uri.Port, (Test-Tcp $uri.Host $uri.Port))
    $rd = Test-Http $it.Url 1 $null
    Out-R ("  Direct HTTP (no proxy):            {0}" -f $rd.Text)
    $rm = Test-Http $it.Url 0 $null
    Out-R ("  Machine proxy (netsh winhttp, IIS): {0}" -f $rm.Text)
    $d = Test-Reach $rd $it.Kind
    $m = Test-Reach $rm $it.Kind
    if ($m) { $kindOk[$it.Kind] = $true }

    if ($d -and $m) { Res 'OK' '  Reachable directly and through the machine proxy' }
    elseif ($m) { Res 'OK' '  Reachable through the machine proxy (direct access blocked: normal for a locked-down server)' }
    elseif ($d) {
      if ($winhttpProxySet) { Res 'WARN' '  Reachable directly but NOT through the netsh winhttp proxy: check the proxy address and bypass list, or, if direct access is approved, netsh winhttp reset proxy' }
      else { Res 'WARN' '  Direct request works but the default WinHTTP request failed: re-run; check netsh winhttp settings' }
    } else {
      if ($winhttpProxySet) { Res 'FAIL' '  Not reachable directly or through the netsh winhttp proxy: raise with the network/proxy team (see the results above)' }
      else { Res 'FAIL' '  Not reachable directly and no WinHTTP proxy is set: set one with netsh winhttp set proxy (chunk 02 Step 4)' }
    }
    if ($rm.Status -eq 407) { Res 'FAIL' '  Proxy requires authentication (407): IIS cannot log in to a proxy. Ask for unauthenticated access to this host' }

    if ($exProxy) {
      $rx = Test-Http $it.Url 2 $exProxy
      Out-R ("  Explicit proxy {0}:  {1}" -f $exProxy, $rx.Text)
      if ((Test-Reach $rx $it.Kind) -and -not $m) {
        Res 'INFO' ('  Works through -Proxy. To use it for IIS: netsh winhttp set proxy proxy-server="{0}" bypass-list="<local>"' -f $exProxy)
      }
    }
  }

  Out-R ''
  $sum = foreach ($k in 'CRL', 'OCSP', 'AIA') { if ($kindSeen[$k]) { "{0}: {1}" -f $k, $(if ($kindOk[$k]) { 'yes' } else { 'NO' }) } else { "{0}: no http URL" -f $k } }
  Out-R ("Reachable on the IIS path (machine proxy setting): {0}" -f ($sum -join '; '))
  if ($kindSeen['CRL'] -and -not $kindOk['CRL']) { Res 'FAIL' 'No CRL URL is reachable on the IIS path: revocation checks will fail (IIS 403.13)' }
  elseif ($kindSeen['OCSP'] -and -not $kindOk['OCSP'] -and $kindOk['CRL']) { Res 'INFO' 'OCSP not reachable, CRL is: Windows falls back to the CRL (not blocking)' }
  Out-R '  Direct and machine-proxy results do not depend on your user Internet Options. The final proof is still'
  Out-R '  certutil -verify -urlfetch run as SYSTEM (chunk 02 Step 4).'
}

# ---------------------------------------------------------------- IIS
Head 'STAGE 2 - HTTPS bindings (netsh http show sslcert)'
$ssl = @(netsh http show sslcert)
$ssl | ForEach-Object { Out-R $_ }
$cur = $null
foreach ($l in $ssl) {
  if ($l -match '^\s*(IP:port|Hostname:port)\s*:\s*(\S+)') { $cur = $Matches[2] }
  elseif ($cur -match ':443$' -and $l -match 'Verify Client Certificate Revocation\s*:\s*Disabled') {
    Res 'WARN' "$cur : Verify Client Certificate Revocation is Disabled. Fine for a test, turn it back on afterwards (chunk 03 Step 1)"
  }
  elseif ($cur -match ':443$' -and $l -match 'Ctl Store Name\s*:\s*(?!\(null\))(\S+)') {
    Res 'WARN' "$cur : CTL store '$($Matches[1])' set - IIS accepts only issuers in it (403.16)"
  }
}
Out-R 'Check: Verify Client Certificate Revocation=Enabled; CTL Store Name empty or includes the external CA;'
Out-R '       Negotiate Client Certificate=Enabled if TLS 1.3 is on.'

Head 'STAGE 2 - TLS 1.3 server state'
$t13 = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.3\Server'
if (Test-Path $t13) { Get-ItemProperty $t13 | Select-Object Enabled, DisabledByDefault | Format-List | Out-String | ForEach-Object { Out-R $_ } }
elseif ([Environment]::OSVersion.Version.Build -lt 20348) { Out-R 'Windows Server 2019 or earlier: no TLS 1.3 server support. Chunk 03 Step 3 does not apply.' }
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

Head 'STAGE 4b - PKI-related lines in web.config (PasswordVault\web.config is the one IIS loads; Bin/Env shown if present)'
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

Head 'LOGS - CAPI2 chain events from logins (lsass = IIS/Schannel client auth), before this script ran'
$capi = Get-WinEvent -ListLog 'Microsoft-Windows-CAPI2/Operational' -ErrorAction SilentlyContinue
if ($capi -and $capi.IsEnabled) {
  $rows = foreach ($ev in (Get-WinEvent -LogName 'Microsoft-Windows-CAPI2/Operational' -MaxEvents 5000 -ErrorAction SilentlyContinue |
                           Where-Object { $_.Id -in 11, 30 -and $_.TimeCreated -lt $scriptStart })) {
    try { $x = [xml]$ev.ToXml() } catch { continue }
    $aux = $x.SelectSingleNode("//*[local-name()='EventAuxInfo']")
    $proc = if ($aux) { $aux.GetAttribute('ProcessName') } else { '' }
    $resN = $x.SelectSingleNode("//*[local-name()='Result']")
    $res = if ($resN) { $resN.GetAttribute('value') } else { '' }
    $err = @($x.SelectNodes("//*[local-name()='ErrorStatus']") | ForEach-Object { $_.GetAttribute('value') } | Where-Object { $_ -and $_ -ne '0' } | Select-Object -Unique)
    $c1 = $x.SelectSingleNode("//*[local-name()='Certificate'][@subjectName]")
    [pscustomobject]@{ Time = $ev.TimeCreated; Id = $ev.Id; Proc = $proc; Result = $res; Errors = ($err -join ',')
      Subject = $(if ($c1) { $c1.GetAttribute('subjectName') } else { '' })
      Thumb = $(if ($c1) { ($c1.GetAttribute('fileRef') -replace '\.cer$', '').ToUpper() } else { '' }) }
  }
  $login = @($rows | Where-Object { $_.Proc -match 'lsass' } | Select-Object -First 12)
  if (-not $login) { Res 'INFO' 'No lsass chain events yet. CAPI2 must be enabled BEFORE the login attempt: retry the login, then re-run.' }
  foreach ($r in $login) {
    $state = if (($r.Result -and $r.Result -ne '0') -or $r.Errors) { 'FAIL' } else { 'OK' }
    Res $state ("{0} id={1} result={2} errorStatus={3} cert={4} [{5}]" -f $r.Time, $r.Id, $r.Result, $r.Errors, $r.Subject, $r.Thumb)
  }
  $sent = @($login | Where-Object { $_.Thumb } | ForEach-Object { $_.Thumb } | Select-Object -Unique)
  if ($sent -and ($sent -notcontains $cert.Thumbprint.ToUpper())) {
    Res 'WARN' "The certificate(s) IIS checked differ from -UserCert ($($cert.Thumbprint)). Export the one the browser sent and re-run with it."
  } elseif ($sent) { Res 'OK' 'IIS checked the same certificate as -UserCert' }
  Out-R '  result/errorStatus 800B0109 = untrusted root, 80092013 = revocation offline, 800B0101 = expired, 0 = OK'
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
