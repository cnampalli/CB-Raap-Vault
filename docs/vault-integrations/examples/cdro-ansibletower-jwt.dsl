// ---------------------------------------------------------------------------
// CloudBees CD/RO -> AAP hand-off: mint a ZeroTrust JWT, then launch an AAP job
// template with it via the EC-AnsibleTower plugin.  (Pattern B, see 03 §6.)
//
// FLOW
//   Task 1 (ZeroTrust plugin):  IssueJwtAndStoreInProperty
//        mint a JWT whose customClaims target the AAP Vault role, store it in a
//        SECURE pipeline property (/myPipelineRuntime/jwtToken).
//   Task 2 (EC-AnsibleTower plugin):  Launch a Job Template
//        pass that property as an extra_var to the AAP job template, which runs
//        aap-vault-jwt.yml and does its own Vault login + secret fetch.
//
//   CDRO never sees the secret. AAP borrows CDRO's short-lived identity.
//
// This is illustrative CD/RO DSL — adapt field names to your CD/RO version.
// The plugin procedure names + parameter semantics are the contract.
//
// PREREQUISITES (configured once):
//   - ZeroTrust plugin Configuration "vault-aut-aap" with customClaims that
//     target the AAP consumer role, e.g.:
//       Issuer=ZeroTrust, Algorithm=RS256, Token lifetime=900,
//       customClaims={"sub":"aap_job","aud":"vault-aap",
//                     "job_name":"$[/myRelease/name]"}
//     (aud=vault-aap is what the Vault role `aap-consumer` binds on — DIFFERENT
//      audience from the in-CDRO KV role, so the two paths don't overlap.)
//   - EC-AnsibleTower plugin Configuration "aap-prod" with:
//       Ansible Tower Server=https://aap.corp.example.com/api/controller/v2
//       Auth scheme=Bearer token (or Basic Auth Credential)
//       Ansible Automation Platform (AAP) version=<your version, e.g. 2.4>
//   - AAP job template "vault-jwt-consumer" running aap-vault-jwt.yml, with
//     Variables -> "Prompt on launch" ENABLED (else extra_vars are dropped).
//   - Vault role `aap-consumer` on mount jwt-cdro (bound_audiences=["vault-aap"])
//     + policy granting the dynamic/KV paths AAP needs. See 07 §3–§4.
// ---------------------------------------------------------------------------

pipeline 'deploy-with-aap-secrets', {

  stage 'fetch-and-run', {

    // --- Task 1: mint the JWT and store it in a secure property -------------
    task 'mint-jwt', {
      taskType       : 'PLUGIN'
      subproject     : '/plugins/ZeroTrust/project'
      subprocedure   : 'IssueJwtAndStoreInProperty'
      actualParameter: [
        configuration : 'vault-aut-aap',
        // customClaims can also be set here to override the config default:
        customClaims  : '{"sub":"aap_job","aud":"vault-aap","job_name":"$[/myRelease/name]"}',
        // store the minted token in a SECURE (masked) runtime property:
        resultProperty: '/myPipelineRuntime/jwtToken'
      ]
    }

    // --- Task 2: launch the AAP job template, passing the JWT as extra_var --
    task 'run-aap-job', {
      taskType       : 'PLUGIN'
      subproject     : '/plugins/EC-AnsibleTower/project'
      // Procedure display name: "Launch a Job Template"
      subprocedure   : 'RunJobTemplate'
      actualParameter: [
        config           : 'aap-prod',                 // EC-AnsibleTower configuration
        jobTemplate      : 'vault-jwt-consumer',        // name or numeric ID
        // "Job template parameters" — JSON merged into the AAP launch payload.
        // extra_vars require Prompt-on-launch on the template (see prereqs).
        jobTemplateParams: '''{
          "extra_vars": {
            "vault_jwt":  "$[/myPipelineRuntime/jwtToken]",
            "vault_role": "aap-consumer",
            "release":    "$[/myRelease/name]"
          }
        }'''
      ]
      // Runs after mint-jwt so the property is populated.
      dependsOn: 'mint-jwt'
    }
  }
}

// ---------------------------------------------------------------------------
// NOTES
// - Mark /myPipelineRuntime/jwtToken as SECURE so it is masked in logs and UI.
//   Never echo it. Keep Token lifetime tight (900 s) so a leaked JWT is useless.
// - Keep debugLevel=Info on BOTH plugins in production. Debug/Trace on the
//   EC-AnsibleTower plugin prints request bodies (which include the JWT).
// - To pass extra_vars WITHOUT enabling Prompt-on-launch, expose them through
//   an AAP Survey on the job template instead (survey vars are always accepted).
// - Workflow templates: use the "Launch a Workflow Job Template" procedure
//   (subprocedure 'RunWorkflowJobTemplate') with the same jobTemplateParams.
// ---------------------------------------------------------------------------
