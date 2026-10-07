# venafi-pki-consumer.hcl — namespace AUT
# Least-privilege policy for a workload that requests TLS certs from the Venafi PKI
# secrets engine (guide 08). One copy per role; change the role name and CN glob.
#
#   vault policy write -namespace=AUT venafi-pki-web-aut venafi-pki-consumer.hcl
#
# The plugin's roles have NO allowed_domains setting, so names are restricted here
# (and by domain whitelisting on the TPP policy folder).

# Issue: Vault generates the key, TPP enforces the folder policy.
path "venafi-pki/issue/web-aut" {
  capabilities = ["create", "update"]
  # Once allowed_parameters is set, any parameter NOT listed is rejected.
  allowed_parameters = {
    "common_name"        = ["*.aut.corp.example.com"]
    "alt_names"          = []   # [] = any value; tighten if consumers send SANs
    "ttl"                = []
    "private_key_format" = []
    "custom_fields"      = []   # drop if the TPP folder needs none
  }
}

# Sign: consumer keeps its key. The CN comes from the CSR, so it cannot be globbed
# here; rely on TPP domain whitelisting for this path.
# path "venafi-pki/sign/host-csr-aut" {
#   capabilities = ["create", "update"]
#   allowed_parameters = { "csr" = [], "ttl" = [] }
# }

# Optional: let the workload revoke its own role's certs (needs the TPP 'revoke' scope).
# path "venafi-pki/revoke/web-aut" { capabilities = ["update"] }

# Never for consumers: the Venafi secret holds live TPP tokens; roles are admin-owned.
path "venafi-pki/venafi/*" { capabilities = ["deny"] }
path "venafi-pki/roles/*"  { capabilities = ["deny"] }
path "venafi-pki/cert/*"   { capabilities = ["deny"] }
path "venafi-pki/certs"    { capabilities = ["deny"] }
