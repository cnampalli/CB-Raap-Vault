# 06 — Test end to end

**Who:** CyberArk admin + a test user on a workstation · **Needs:** chunks 01–05
**Gives:** a working certificate login, with evidence

**In short:** log in with the certificate from a fresh InPrivate window, check the IIS log says
`200`, repeat on every PVWA server, then check that wrong certificates are refused.

## Step 1 — Browser trusts the PVWA (internal CA)

🖱 On the test workstation, open `https://<pvwa>/PasswordVault` in Chrome or Edge.

**Expected:** no certificate warning. If there is one, the workstation is missing the **internal**
root (deploy it by GPO). This is unrelated to the user's external certificate.

## Step 2 — Log in with the certificate

1. 🖱 On the sign-in page, choose the PKIPN option (chunk 04 display name).
2. 🖱 The browser asks you to **select a certificate**. Pick the external-CA login certificate. For a
   smart card, enter the PIN.
3. 🖱 Use a fresh **InPrivate / Incognito** window for each attempt. Browsers remember the chosen
   certificate (or a cancelled prompt) until they are closed.

**Expected:** the PVWA opens as the test user, with no password asked.

## Step 3 — Evidence

1. ⌨ On the PVWA server, the IIS log for that request shows `200`:
   `C:\inetpub\logs\LogFiles\W3SVC1\u_ex<yymmdd>.log`. Search for `pkipn`.
2. 🖱 PVWA → **Activities** / audit for the user: a logon through the PVWA.
3. 🖱 Repeat on **each** PVWA server (point the browser at each server directly, or drain the load
   balancer one at a time).

**Expected:** login works through every PVWA server.

## Step 4 — Negative tests

| Test | Expected |
|---|---|
| A certificate from another CA (e.g. internal-CA user cert) | Refused, if issuer restriction (chunk 04 Step 5) is on |
| A user whose UPN has no Vault user | Refused with "user not found" |
| Cancel the certificate prompt | `403.7`, no login |

## Done when

- [ ] Certificate login works on every PVWA server
- [ ] Negative tests refused
