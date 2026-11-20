<#
.SYNOPSIS
  Evidence: does CyberArk PVWA PKIPN use Microsoft "strong certificate mapping" (KB5014754,
  altSecurityIdentities)? Read-only.

.DESCRIPTION
  Three parts. Run each where it makes sense; each one works on its own.

  -Part Pvwa  (on a PVWA server, as Administrator)
      Is Windows/IIS mapping certificates to AD accounts for PVWA at all (DS mapper, IIS AD
      certificate mapping)? Do any PVWA assemblies even contain the strings needed to read
      altSecurityIdentities or ask Windows to map a certificate (S4U / LogonUser / Kerberos)?

  -Part Cert  (any domain-joined Windows machine; needs read access to AD, no RSAT needed)
      For one user certificate: does it carry the SID extension? What are its STRONG mapping
      strings (Issuer+Serial, SKI)? Which AD account has them in altSecurityIdentities, and is that
      the same account PKIPN picks from the certificate's UPN?

  -Part Module (on a PVWA server)
      Sizes the "custom authentication module" option: lists the public types, base classes,
      interfaces and methods of CyberArk.Authentication.CustomPKIPN.dll (reflection only, nothing is
      executed). That is the extension point a custom module would implement.

  -Part Dc    (any machine; needs rights to read the Security/System logs of the domain controllers)
      After a PKIPN login: did any DC see a certificate (PKINIT) logon for that user, or log a
      KB5014754 strong-mapping event? If PVWA used Windows mapping, it would show here.

  Writes the same text to the screen and to .\strongmap-evidence-<host>-<time>.txt

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\strongmap-evidence.ps1 -Part Pvwa
  powershell -ExecutionPolicy Bypass -File .\strongmap-evidence.ps1 -Part Cert -UserCert C:\temp\user.cer
  powershell -ExecutionPolicy Bypass -File .\strongmap-evidence.ps1 -Part Dc -SamAccountName ctest -SinceMinutes 30
#>
param(
  [ValidateSet('Pvwa', 'Cert', 'Dc', 'Module')][string[]]$Part = @('Pvwa'),
  [string]$UserCert,
  [string]$PvwaRoot = 'C:\inetpub\wwwroot\PasswordVault',
  [string]$SiteName = 'Default Web Site',
  [string]$SearchRoot,            # e.g. 'GC://acme.corp.au' or 'LDAP://dc1.acme.corp.au/DC=acme,DC=corp,DC=au'. Default: Global Catalog of this forest
  [string]$SamAccountName,        # for -Part Dc
  [string[]]$DomainController,    # for -Part Dc. Default: every DC of this computer's domain
  [int]$SinceMinutes = 60
)
$ErrorActionPreference = 'Continue'
$X = 'System.Security.Cryptography.X509Certificates'
$report = Join-Path (Get-Location) ("strongmap-evidence-{0}-{1}.txt" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
function Out-R([string]$t) { Write-Host $t; Add-Content -Path $report -Value $t }
function Head([string]$t) { Out-R ''; Out-R ('=' * 78); Out-R "== $t"; Out-R ('=' * 78) }
function Res([string]$s, [string]$t) { Out-R ("[{0}] {1}" -f $s, $t) }
function Esc-Ldap([string]$v) { ($v -replace '\\', '\5c' -replace '\*', '\2a' -replace '\(', '\28' -replace '\)', '\29' -replace "`0", '\00') }

Head "Strong certificate mapping evidence on $env:COMPUTERNAME at $(Get-Date -Format s)"

# =============================================================================== PART PVWA
if ($Part -contains 'Pvwa') {
  Head 'PART PVWA 1 - Does IIS map client certificates to AD accounts? (where KB5014754 would apply)'
  $cur = $null
  foreach ($l in @(netsh http show sslcert)) {
    if ($l -match '^\s*(IP:port|Hostname:port)\s*:\s*(\S+)') { $cur = $Matches[2] }
    elseif ($l -match 'DS Mapper Usage\s*:\s*(\S+)') { Out-R ("  {0,-22} DS Mapper Usage = {1}" -f $cur, $Matches[1]) }
  }
  Out-R '  DS Mapper = Windows/Schannel maps the client certificate to an AD account. Disabled = not used.'
  try {
    Import-Module WebAdministration -ErrorAction Stop
    foreach ($loc in "$SiteName", "$SiteName/PasswordVault", "$SiteName/PasswordVault/auth/pki", "$SiteName/PasswordVault/auth/pkipn", "$SiteName/PasswordVault/api/auth/pkipn") {
      $ad = (Get-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Location $loc -Filter 'system.webServer/security/authentication/clientCertificateMappingAuthentication' -Name enabled -ErrorAction SilentlyContinue).Value
      $ii = (Get-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Location $loc -Filter 'system.webServer/security/authentication/iisClientCertificateMappingAuthentication' -Name enabled -ErrorAction SilentlyContinue).Value
      Out-R ("  {0,-48} AD cert mapping = {1,-5}  IIS cert mapping = {2}" -f $loc, $ad, $ii)
    }
  } catch { Res 'WARN' "WebAdministration not available: $($_.Exception.Message)" }
  Out-R '  Expect for PKIPN: all False. IIS only validates the certificate (chain/revocation) and hands it to PVWA.'

  Head 'PART PVWA 2 - What the PKI/PKIPN modules reference (reflection, read-only)'
  $pkiDlls = @(Get-ChildItem (Join-Path $PvwaRoot 'Bin'), (Join-Path $PvwaRoot 'CustomAuthenticationDlls') -Filter '*PKI*.dll' -ErrorAction SilentlyContinue)
  foreach ($d in $pkiDlls) {
    Out-R "--- $($d.FullName)  ($($d.Length) bytes)"
    try {
      $a = [Reflection.Assembly]::ReflectionOnlyLoadFrom($d.FullName)
      Out-R ("  References: {0}" -f (($a.GetReferencedAssemblies() | ForEach-Object Name) -join ', '))
    } catch { Out-R "  (not loaded: $($_.Exception.Message.Split([Environment]::NewLine)[0]))" }
  }
  Out-R '  An AD-mapping implementation would reference System.DirectoryServices*, or call Windows logon APIs.'

  Head 'PART PVWA 3 - Strings in ALL PVWA assemblies that an altSecurityIdentities / Windows-mapping implementation needs'
  $keys = [ordered]@{
    'altSecurityIdentities'     = 'AD attribute holding strong mappings'
    'X509:<'                    = 'prefix of every altSecurityIdentities mapping string'
    'KerbS4ULogon'              = 'Windows S4U logon (map a cert/UPN to a Windows token)'
    'LsaLogonUser'              = 'Windows logon API'
    'LogonUser'                 = 'Windows logon API'
    '1.3.6.1.4.1.311.25.2'      = 'OID of the KB5014754 SID extension'
    '1.3.6.1.4.1.311.20.2.3'    = 'OID of the UPN (Principal Name) in the SAN'
    'userPrincipalName'         = 'AD UPN attribute'
  }
  $files = @(Get-ChildItem (Join-Path $PvwaRoot 'Bin'), (Join-Path $PvwaRoot 'CustomAuthenticationDlls') -Filter '*.dll' -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -like 'CyberArk*' -or $_.Name -like 'PVWA*' })
  Out-R ("  Scanned {0} CyberArk/PVWA assemblies (ASCII and UTF-16)." -f $files.Count)
  $hits = @{}; foreach ($k in $keys.Keys) { $hits[$k] = New-Object System.Collections.Generic.List[string] }
  foreach ($f in $files) {
    $b = [IO.File]::ReadAllBytes($f.FullName)
    $txt = [Text.Encoding]::ASCII.GetString($b) + "`n" + [Text.Encoding]::Unicode.GetString($b) + "`n" + $(if ($b.Length -gt 1) { [Text.Encoding]::Unicode.GetString($b, 1, $b.Length - 1) })
    foreach ($k in $keys.Keys) { if ($txt.IndexOf($k, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hits[$k].Add($f.Name) } }
  }
  foreach ($k in $keys.Keys) {
    $n = $hits[$k] | Select-Object -Unique
    Out-R ("  {0,-24} {1,-3} {2}" -f $k, $(if ($n) { 'YES' } else { 'no' }), $(if ($n) { ($n -join ', ') } else { "($($keys[$k]))" }))
  }
  Out-R '  Read: the deciding lines are altSecurityIdentities and X509:<. "no" for both in every PVWA assembly ='
  Out-R '  PVWA has no code that reads or evaluates strong mappings. LogonUser/userPrincipalName hits are expected'
  Out-R '  elsewhere (Windows and LDAP login modules) and prove nothing either way. Check WHICH file hits.'
}

# =============================================================================== PART CERT
if ($Part -contains 'Cert') {
  Head 'PART CERT - Strong mapping strings for this certificate, and who they map to in AD'
  if (-not $UserCert -or -not (Test-Path $UserCert)) { Res 'FAIL' 'Give -UserCert <path to the PUBLIC .cer>' }
  else {
    $c = New-Object "$X.X509Certificate2" (Resolve-Path $UserCert).Path
    Out-R "Subject : $($c.Subject)"; Out-R "Issuer  : $($c.Issuer)"; Out-R "Serial  : $($c.SerialNumber)"; Out-R "Thumb   : $($c.Thumbprint)"
    $upn = $null
    $san = $c.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' }
    if ($san) { $m = [regex]::Match($san.Format($false), 'Principal Name=([^,\s]+)'); if ($m.Success) { $upn = $m.Groups[1].Value } }
    Out-R "UPN     : $upn   <- what PKIPN uses to pick the account"

    $sid = $c.Extensions | Where-Object { $_.Oid.Value -eq '1.3.6.1.4.1.311.25.2' }
    if ($sid) { Res 'INFO' 'Certificate HAS the SID extension (1.3.6.1.4.1.311.25.2): strong mapping by SID (AD CS-issued)' }
    else { Res 'INFO' 'No SID extension (normal for an external CA). Strong mapping is only possible via altSecurityIdentities.' }

    # Strong mapping strings (KB5014754). Issuer in reversed RDN order, serial in reversed byte order.
    $issuerRev = (($c.IssuerName.Decode([Security.Cryptography.X509Certificates.X500DistinguishedNameFlags]'Reversed, UseNewLines') -split "`r?`n") | Where-Object { $_ }) -join ','
    $srRev = -join ($c.GetSerialNumber() | ForEach-Object { $_.ToString('X2') })   # GetSerialNumber() = little-endian = reversed
    $skiExt = $c.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.14' }
    $ski = if ($skiExt) { ([System.Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension]$skiExt).SubjectKeyIdentifier } else { $null }
    $strIS = "X509:<I>$issuerRev<SR>$srRev"
    $strSKI = if ($ski) { "X509:<SKI>$ski" } else { $null }
    Out-R ''
    Out-R 'Strong mapping strings for this certificate (add ONE to the user''s altSecurityIdentities):'
    Out-R "  X509IssuerSerialNumber : $strIS"
    Out-R ("  X509SKI                : {0}" -f $(if ($strSKI) { $strSKI } else { '(certificate has no SKI extension)' }))
    Out-R 'Weak forms, for comparison (not accepted by DCs under Full Enforcement):'
    Out-R ("  X509IssuerSubject      : X509:<I>{0}<S>{1}" -f $issuerRev, ((($c.SubjectName.Decode([Security.Cryptography.X509Certificates.X500DistinguishedNameFlags]'Reversed, UseNewLines') -split "`r?`n") | Where-Object { $_ }) -join ','))
    Out-R '  UPN / e-mail (implicit) : the account whose userPrincipalName = the SAN UPN  <- this is what PKIPN does'

    # ---- AD lookups
    try {
      $root = if ($SearchRoot) { New-Object DirectoryServices.DirectoryEntry($SearchRoot) }
              else { New-Object DirectoryServices.DirectoryEntry(('GC://' + [DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest().Name)) }
      Out-R ''; Out-R "AD search root: $($root.Path)"
      function Find-AD([string]$filter) {
        $s = New-Object DirectoryServices.DirectorySearcher($root, $filter, [string[]]@('samaccountname', 'userprincipalname', 'altsecurityidentities', 'distinguishedname'))
        $s.PageSize = 200; @($s.FindAll())
      }
      function Show([object[]]$rs) { foreach ($r in $rs) { Out-R ("    {0}  UPN={1}  {2}" -f $r.Properties['samaccountname'][0], $r.Properties['userprincipalname'][0], $r.Properties['distinguishedname'][0]); foreach ($v in $r.Properties['altsecurityidentities']) { Out-R "      altSecurityIdentities: $v" } } }

      $byUpn = if ($upn) { Find-AD "(userPrincipalName=$(Esc-Ldap $upn))" } else { @() }
      Out-R ''; Out-R "1) Account by UPN (implicit, WEAK - what PKIPN relies on): $($byUpn.Count) found"; Show $byUpn

      $strong = @()
      $strong += Find-AD "(altSecurityIdentities=*<SR>$(Esc-Ldap $srRev))"      # issuer-order independent
      if ($strSKI) { $strong += Find-AD "(altSecurityIdentities=$(Esc-Ldap $strSKI))" }
      $strong = @($strong | Sort-Object { $_.Properties['distinguishedname'][0] } -Unique)
      Out-R ''; Out-R "2) Account(s) with a STRONG mapping to this certificate (altSecurityIdentities): $($strong.Count) found"; Show $strong
      if ($strong.Count -eq 0 -and $root.Path -like 'GC://*') { Out-R '    (searched the Global Catalog; to rule out a GC gap, re-run with -SearchRoot ''LDAP://<dc of the user''s domain>/<domain DN>'')' }

      foreach ($r in $strong) {
        foreach ($v in $r.Properties['altsecurityidentities']) {
          if ($v -like "*<SR>$srRev" -and $v -ne $strIS) { Res 'WARN' "Stored Issuer+Serial string differs from the computed one (issuer order/format?): $v" }
        }
      }
      Out-R ''
      Head 'PART CERT - Verdict'
      $upnDn = if ($byUpn.Count -eq 1) { $byUpn[0].Properties['distinguishedname'][0] } else { $null }
      if ($strong.Count -eq 0) {
        Res 'INFO' 'No strong mapping exists for this certificate. A Windows/Kerberos certificate logon with it would be REFUSED by DCs in Full Enforcement.'
        Out-R '       If PKIPN still logs this user in, PKIPN does not use strong mapping (it maps by UPN only).'
      } elseif ($upnDn -and ($strong | Where-Object { $_.Properties['distinguishedname'][0] -eq $upnDn })) {
        Res 'OK' 'A strong mapping exists and points to the SAME account as the UPN. Windows and PKIPN agree for this certificate.'
        Out-R '       (PKIPN still never checks it; see PART PVWA. To prove that, run the negative test in chunk 10.)'
      } else {
        Res 'WARN' 'The strong mapping points to a DIFFERENT account than the UPN. Windows would log in that account; PKIPN logs in the UPN account.'
      }
      if ($byUpn.Count -eq 1 -and $strong.Count -eq 0) {
        Out-R ''
        Out-R 'To ADD a strong mapping (AD admin; changes AD; not run by this script):'
        Out-R ("  Set-ADUser -Identity '{0}' -Add @{{altSecurityIdentities='{1}'}}" -f $byUpn[0].Properties['samaccountname'][0], $strIS)
      }
    } catch { Res 'FAIL' "AD query failed: $($_.Exception.Message). Give -SearchRoot 'GC://<forest>' or 'LDAP://<dc>/<base DN>'." }
  }
}

# =============================================================================== PART MODULE
if ($Part -contains 'Module') {
  Head 'PART MODULE - The custom authentication extension point (reflection only)'
  $bin = Join-Path $PvwaRoot 'Bin'
  $resolver = [ResolveEventHandler]{
    param($sender, $e)
    $n = (New-Object Reflection.AssemblyName($e.Name)).Name
    $p = Join-Path $bin "$n.dll"
    if (Test-Path $p) { [Reflection.Assembly]::ReflectionOnlyLoadFrom($p) } else { [Reflection.Assembly]::ReflectionOnlyLoad($e.Name) }
  }
  [AppDomain]::CurrentDomain.add_ReflectionOnlyAssemblyResolve($resolver)
  foreach ($name in 'CyberArk.Authentication.CustomPKIPN.dll', 'CyberArk.Authentication.PKIPN.dll') {
    $f = Join-Path $bin $name
    if (-not (Test-Path $f)) { Out-R "--- $name not found in Bin"; continue }
    Out-R "--- $name  ($((Get-Item $f).Length) bytes, version $((Get-Item $f).VersionInfo.FileVersion))"
    try {
      $a = [AppDomain]::CurrentDomain.ReflectionOnlyGetAssemblies() | Where-Object { $_.Location -eq $f } | Select-Object -First 1
      if (-not $a) { $a = [Reflection.Assembly]::ReflectionOnlyLoadFrom($f) }
      $types = try { $a.GetTypes() } catch [Reflection.ReflectionTypeLoadException] { $_.Exception.Types | Where-Object { $_ } }
      foreach ($t in $types) {
        Out-R ("  TYPE {0}" -f $t.FullName)
        Out-R ("       base: {0}" -f $t.BaseType)
        $ifs = try { ($t.GetInterfaces() | ForEach-Object FullName) -join ', ' } catch { '(unresolved)' }
        Out-R ("       implements: {0}" -f $ifs)
        try { $t.GetMethods([Reflection.BindingFlags]'Public, NonPublic, Instance, Static, DeclaredOnly') | ForEach-Object { Out-R ("       method: {0}" -f $_.ToString()) } } catch { Out-R "       methods: (unresolved: $($_.Exception.Message))" }
      }
    } catch { Res 'WARN' "Could not inspect ${name}: $($_.Exception.Message)" }
  }
  Out-R '  Read: the interface/base class above is what a custom module must implement. Small type, few'
  Out-R '  methods = a small extension point (good for option C). Ask CyberArk whether it is a supported API.'
}

# =============================================================================== PART DC
if ($Part -contains 'Dc') {
  Head "PART DC - Did any domain controller see a certificate logon for '$SamAccountName' in the last $SinceMinutes min?"
  if (-not $SamAccountName) { Res 'FAIL' 'Give -SamAccountName (the AD logon name, e.g. from PART CERT)' }
  else {
    if (-not $DomainController) {
      try { $DomainController = @([DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().DomainControllers | ForEach-Object Name) }
      catch { Res 'FAIL' "Cannot list DCs: $($_.Exception.Message). Give -DomainController dc1,dc2"; $DomainController = @() }
    }
    $since = (Get-Date).AddMinutes(-$SinceMinutes).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.000Z')
    $kerbAny = 0; $kerbCert = 0; $kdc = 0
    foreach ($dc in $DomainController) {
      Out-R "--- $dc"
      $xp = "*[System[(EventID=4768) and TimeCreated[@SystemTime>='$since']] and EventData[Data[@Name='TargetUserName']='$SamAccountName']]"
      try {
        $ev = @(Get-WinEvent -ComputerName $dc -LogName Security -FilterXPath $xp -ErrorAction Stop)
        foreach ($e in $ev) {
          $d = @{}; ([xml]$e.ToXml()).Event.EventData.Data | ForEach-Object { $d[$_.Name] = $_.'#text' }
          $kerbAny++
          if ($d['PreAuthType'] -in '15', '16', '17' -or $d['CertIssuerName']) { $kerbCert++ }
          Out-R ("  {0} 4768 TGT  PreAuthType={1}  CertIssuer={2}  CertSerial={3}  Client={4}" -f $e.TimeCreated, $d['PreAuthType'], $d['CertIssuerName'], $d['CertSerialNumber'], $d['IpAddress'])
        }
        if (-not $ev) { Out-R '  no 4768 for this account' }
      } catch { if ($_.Exception.Message -match 'No events') { Out-R '  no 4768 for this account' } else { Res 'WARN' "Security log not readable on ${dc}: $($_.Exception.Message)" } }
      try {
        $k = @(Get-WinEvent -ComputerName $dc -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kerberos-Key-Distribution-Center'; Id = 39, 40, 41, 45, 48, 49; StartTime = (Get-Date).AddMinutes(-$SinceMinutes) } -ErrorAction Stop)
        foreach ($e in $k) { $kdc++; Out-R ("  {0} KDC event {1}: {2}" -f $e.TimeCreated, $e.Id, ($e.Message -split "`n")[0]) }
      } catch { if ($_.Exception.Message -notmatch 'No events') { Res 'WARN' "System log not readable on ${dc}: $($_.Exception.Message)" } else { Out-R '  no KB5014754 KDC events' } }
    }
    Head 'PART DC - Verdict'
    Out-R "  Kerberos TGT requests for the account: $kerbAny   with a certificate (PKINIT): $kerbCert   KB5014754 KDC events: $kdc"
    if ($kerbCert -eq 0) {
      Res 'OK' 'No domain controller performed a certificate logon for this account in the window.'
      Out-R '       If a PKIPN login for this user succeeded in that window, the login never went through Windows certificate'
      Out-R '       mapping, so KB5014754 strong mapping was not (and cannot be) applied to it.'
    } else { Res 'INFO' 'A DC did see a certificate logon. Check its time: was it the PKIPN attempt, or a Windows smart-card logon by the user?' }
  }
}

Head 'DONE'
Out-R "Report: $report"
