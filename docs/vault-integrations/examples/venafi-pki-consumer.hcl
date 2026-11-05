# venafi-pki-consumer.hcl — namespace AUT
# Least-privilege policy for a workload that requests TLS certs from the Venafi PKI secrets
# engine (guide 08). One copy per role; change the role name and the name globs.
# vault-enterprise-config generates the same thing from policies/templates/venafi-pki-consumer.hcl.tpl.
#
#   vault policy write -namespace=AUT venafi-pki-web-aut venafi-pki-consumer.hcl
#
# Paths are RELATIVE to the namespace the policy is written in — no "AUT/" prefix.
#
# The plugin's roles have NO allowed_domains, so names are controlled by:
#   1. the TPP policy folder's domain whitelist (CN and SANs) — AUTHORITATIVE, Venafi team;
#   2. this ACL — a PRE-FILTER only. Tested on Vault 1.20: alt_names is a comma-joined string and
#      Vault globs match commas, so "*.aut.corp.example.com" also lets
#      "evil.com,x.aut.corp.example.com" through and the cert gets DNS:evil.com.
# The plugin does not copy the CN into the SANs, so consumers must send alt_names (CN included).

# Issue: Vault generates the key, TPP enforces the folder policy.
path "venafi-pki/issue/web-aut" {
  capabilities = ["create", "update"]
  # Once allowed_parameters is set, any parameter NOT listed is rejected (e.g. ip_sans here).
  allowed_parameters = {
    "common_name"        = ["*.aut.corp.example.com"]
    "alt_names"          = ["*.aut.corp.example.com"]
    "ttl"                = []
    "private_key_format" = []
    "custom_fields"      = []   # drop if the TPP folder needs none
  }
}

# Sign: consumer keeps its key. The plugin takes CN and SANs from the CSR and ignores any
# common_name/alt_names parameters, so names cannot be restricted here at all; TPP must.
# path "venafi-pki/sign/host-csr-aut" {
#   capabilities = ["create", "update"]
#   allowed_parameters = { "csr" = [], "ttl" = [], "custom_fields" = [] }
# }

# cert-manager (Kubernetes) — exactly what its Vault issuer sends to sign/ (v1.21):
# path "venafi-pki/sign/k8s-cert-manager" {
#   capabilities = ["create", "update"]
#   allowed_parameters = {
#     "csr" = [], "ttl" = [], "common_name" = [], "alt_names" = [], "ip_sans" = [],
#     "uri_sans" = [], "exclude_cn_from_sans" = [], "custom_fields" = []
#   }
# }

# Optional: revoke this role's certs (cross-role revoke is blocked by the plugin since v0.16.0;
# needs the "revoke" scope on the TPP API integration).
# path "venafi-pki/revoke/web-aut" { capabilities = ["update"] }

# Never for consumers: the Venafi secret holds live TPP tokens; roles are admin-owned.
path "venafi-pki/venafi/*" { capabilities = ["deny"] }
path "venafi-pki/roles/*"  { capabilities = ["deny"] }
path "venafi-pki/cert/*"   { capabilities = ["deny"] }
path "venafi-pki/certs"    { capabilities = ["deny"] }
