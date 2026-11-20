# 09 — Debug logging

**Who:** Windows admin on the PVWA server (CyberArk admin for the Vault part)
**Use when:** a login fails and the IIS sub-status alone doesn't say why.

**In short:** turn on the extra logging below, try **one** login, collect with
[`tools/pkipn-collect.ps1`](tools/pkipn-collect.ps1), then **turn the logging off again** (table at
the end).

## Which log answers which question

| Question | Log | Default |
|---|---|---|
| Which stage failed? | IIS log: `403 <sub-status>` | On |
| Which certificate did IIS check, and why was it refused? | **CAPI2** event log | **Off** |
| Did the TLS handshake fail, or was no certificate sent? | **Schannel** events (System log) | Errors only |
| Which IIS step returned the 403, with full detail? | **Failed Request Tracing** | **Off** (feature may not be installed) |
| IIS accepted the certificate (`200`), but PVWA said no. Why? | **PVWA logs** `C:\Windows\Temp\PVWA\` | On |
| PVWA passed it on, the Vault refused the user. Why? | Vault **`ITALog.log`** | On |

## 1. CAPI2: certificate chain checks

⌨ On:
```cmd
wevtutil sl Microsoft-Windows-CAPI2/Operational /e:true /ms:104857600
```
(`/ms` makes the log 100 MB; the default size fills up within minutes on a busy server.)

**Read it:** the collector script summarises it. By hand: 🖱 Event Viewer → *Applications and
Services Logs* → *Microsoft* → *Windows* → *CAPI2* → *Operational*. Look for **Error** events with ID
**11** (build chain) or **30** (verify chain) at the time of the attempt. On the *Details* tab:
*ProcessName* `lsass.exe` = the check IIS did. The *Result* value is the reason: `800B0109`
untrusted root, `80092013` revocation offline, `800B0101` expired.

⌨ Off: `wevtutil sl Microsoft-Windows-CAPI2/Operational /e:false`

## 2. Schannel: TLS handshake detail

⌨ On (needs a **reboot** to take effect):
```cmd
reg add HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL /v EventLogging /t REG_DWORD /d 7 /f
```
**Read it:** Event Viewer → *Windows Logs* → *System*, source **Schannel**. Useful IDs: `36888` (a fatal TLS
alert, with its code) and `36874` (no common cipher or protocol). Many information events are normal
once logging is up; look at the **Error** ones at the time of the attempt.

⌨ Off: `reg add HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL /v EventLogging /t REG_DWORD /d 1 /f`, then reboot.

## 3. IIS Failed Request Tracing: what IIS did with the request

1. ⌨ Install the feature (once; no restart):
   ```powershell
   Install-WindowsFeature Web-Http-Tracing
   ```
2. 🖱 **IIS Manager** → *Sites* → **Default Web Site** → *Actions* pane (right) → **Failed Request
   Tracing…** → tick **Enable** → *Maximum number of trace files*: `50` → **OK**.
3. 🖱 Select **PasswordVault** → double-click **Failed Request Tracing Rules** → *Actions* → **Add…**
   - *What would you like to trace?* **All content (\*)** → **Next**
   - *Status code(s):* `401-403` → **Next**
   - Providers: leave all ticked, *Verbosity*: **Verbose** → **Finish**
4. 🖱 Try the login once.
5. **Read it:** files `fr000001.xml`, … in `C:\inetpub\logs\FailedReqLogFiles\W3SVC1\`. Open one
   in **Edge** (keep `freb.xsl` in the same folder). *Request Summary* shows the URL, status and
   sub-status, and the **module** that refused it. *Compact View* → search for `CERTIFICATE`, `SSL`
   and `403` to see the client-certificate details IIS had.

Off: 🖱 *Default Web Site* → **Failed Request Tracing…** → untick **Enable** → **OK**.

## 4. PVWA application logs

**Where:** `C:\Windows\Temp\PVWA\`. The useful files are usually `PVWA.App.log`,
`CyberArk.WebApplication.log` and `CyberArk.WebConsole.log`. Each request has an ID (a GUID) on every
line. Find the line `EndRequest /PasswordVault/api/auth/pkipn/logon | code: …`, copy its GUID, and
search all files for it: that gives every line for that one login.

⌨ All lines for the latest PKIPN request:
```powershell
$l = Select-String -Path C:\Windows\Temp\PVWA\*.log -Pattern 'auth/pkipn/logon' | Select-Object -Last 1
$id = [regex]::Match($l.Line, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}').Value
Select-String -Path C:\Windows\Temp\PVWA\*.log -Pattern $id | ForEach-Object Line
```

**More detail.** Your server's `PVWA.App.log` already contains `TRACE` lines, its most detailed
level. If you need the other PVWA logs at debug level:
1. ⌨ Find where your version sets the levels (lists the config files and lines that mention them):
   ```powershell
   Select-String -Path C:\inetpub\wwwroot\PasswordVault\*.config -Pattern 'level|debug' | Select-Object Path, LineNumber, Line
   ```
2. 📋 Change it only as the CyberArk 14.6 documentation or CyberArk support says for your version.
   Back the file up first; `iisreset` afterwards.
3. Put it back when done. Debug logs grow fast and can include user names.

## 5. Vault: ITALog.log

Only needed when PVWA says the user is unknown, suspended or not authorised.

🖱 On the **Vault** server: `…\PrivateArk\Server\Logs\ITALog.log`. Search for the user name (the
certificate UPN) and for `PVWAGWUser` at the time of the attempt. Each line starts with an `ITA…`
message code and says why the logon was refused.

Don't raise the Vault's own debug level yourself: it needs a Vault restart (an outage). Ask CyberArk
support if `ITALog.log` doesn't explain it.

## 6. The browser (optional)

- 🖱 **F12** → *Network* → try the login → click the red `logon` request → *Response* shows PVWA's
  error text.
- No certificate prompt at all? 🖱 `edge://net-export` (or `chrome://net-export`) → *Start logging* →
  try the login → *Stop*. The file shows whether the server asked for a certificate and whether the
  browser sent one. Send it with the other evidence.

## Turn it all off afterwards

| Turned on | Turn off |
|---|---|
| CAPI2 | `wevtutil sl Microsoft-Windows-CAPI2/Operational /e:false` |
| Schannel `EventLogging` = 7 | Set back to `1`, reboot |
| Failed Request Tracing | Untick *Enable* on the site |
| PVWA debug level | Restore the backed-up config file, `iisreset` |
