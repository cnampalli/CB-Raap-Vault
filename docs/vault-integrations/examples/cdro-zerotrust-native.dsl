// ---------------------------------------------------------------------------
// CloudBees CD/RO -> Vault Enterprise: ZeroTrust plugin, Tier 2 (native, no CLI)
//
// The ZeroTrust plugin performs the Vault login + read itself, so the CD/RO
// agent needs NO shell binaries (no curl, no vault, no jq). Use this tier when
// your users don't script at all.
//
// This is illustrative CD/RO DSL (ectool/DSL-style). Adapt field names to your
// CD/RO version; the plugin procedure names and semantics are the contract.
//
// Assumes (already configured):
//   - A ZeroTrust plugin Configuration named "vault-aut" with:
//       Endpoint=https://vault-vip.corp.example.com:8200, Provider=jwt-cdro,
//       Role=cdro-zerotrust, Issuer=ZeroTrust, secret_mount_path=secret,
//       Namespace=AUT, Algorithm=RS256, Token lifetime=900, debugLevel=info,
//       customClaims={"sub":"$[/myJob/launchedByUser]","aud":"vault-AUT",
//                     "job_name":"$[/myRelease/name]"}
//   - Vault mount jwt-cdro (static pubkey) + role cdro-zerotrust + policy
//     cdro-zerotrust-ro on secret/data/cdr/<release>/*.
//
// Concurrency clobber: give each release/pipeline its OWN credential. Do NOT let
// two different releases share one credential (e.g. the default zt_credential) —
// last write wins and a run can read the wrong secret.
// ---------------------------------------------------------------------------

// --- Pattern A, option 1: read a KV secret into an existing CD/RO credential ---
// 1 pair  -> key=username, value=password
// 2 pairs {username,password} -> mapped directly
// >2 pairs -> whole secret stored as JSON in the password field
procedure 'read-db-secret', {
  step 'update-credential', {
    subproject       : '/plugins/ZeroTrust/project'
    subprocedure     : 'UpdateCdroCredentialThroughJwtRequest'
    actualParameter  : [
      configuration  : 'vault-aut',
      secretPath     : 'cdr/$[/myRelease/name]/db',   // release-scoped KV path
      credentialName : '$[/myRelease/name]-db-cred'    // per-release credential (avoid clobber)
    ]
  }
  // Later steps reference the credential; the secret is never echoed.
}

// --- Pattern A, option 2: store secret in zt_credential, then run a command ---
procedure 'read-and-run', {
  step 'get-and-run', {
    subproject      : '/plugins/ZeroTrust/project'
    subprocedure    : 'getCdroCredentialAndRunStep'
    actualParameter : [
      configuration : 'vault-aut',
      secretPath    : 'cdr/$[/myRelease/name]/db',
      // plugin stores the secret (JSON) in the password of a credential named zt_credential,
      // then runs the command below, which reads it via getFullCredential.
      command       : '''
        import com.electriccloud.commander.dsl.util.*
        def cred = getFullCredential(credentialName: "zt_credential")
        // use cred.password (JSON) here; do NOT print it
      '''
    ]
  }
}

// --- Pattern A, option 3: store the Vault-AUTHORIZED TOKEN, then run a command --
procedure 'token-and-run', {
  step 'get-token-and-run', {
    subproject      : '/plugins/ZeroTrust/project'
    subprocedure    : 'getAuthorizedTokenAndRunStep'
    actualParameter : [
      configuration : 'vault-aut',
      // plugin stores the Vault token in zt_credential; your command uses it to
      // call Vault itself (e.g. additional reads within this run's policy scope).
      command       : 'echo "token available in zt_credential — not printed"'
    ]
  }
}
