datacenter  = "dc1"
data_dir    = "/consul/data"
log_level   = "INFO"
server      = true
bootstrap   = true
client_addr = "0.0.0.0"
bind_addr   = "0.0.0.0"

ui_config {
  enabled = false
}

connect {
  enabled = true
}

ports {
  http  = 8500
  grpc  = 8502
  https = -1
  dns   = -1
}

# ACLs — deny-by-default. initial_management is the bootstrap/root token.
# Set CONSUL_MGMT_TOKEN and CONSUL_SIDECAR_TOKEN via .env before any non-local deployment.
acl {
  enabled                  = true
  default_policy           = "deny"
  enable_token_persistence = true

  tokens {
    initial_management = "root"
    agent              = "root"
  }
}
