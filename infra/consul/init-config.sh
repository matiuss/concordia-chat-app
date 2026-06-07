#!/bin/sh
# Dynamically builds and writes Consul config entries for the service mesh.
# Must run after Consul is healthy; sidecars must depend on this completing.
#
# Required env vars:
#   CONSUL_HTTP_TOKEN   — management token (matches server.hcl tokens.initial_management)
#   CONSUL_SIDECAR_TOKEN — token secret to create for Envoy sidecars

CONSUL_HTTP_TOKEN="${CONSUL_HTTP_TOKEN:-root}"
CONSUL_SIDECAR_TOKEN="${CONSUL_SIDECAR_TOKEN:-sidecar-token}"
CONSUL_ADDR="http://consul:8500"

echo "=== Consul config init ==="

# ── ACL bootstrap: create service-mesh policy + sidecar token ─────────────
echo "Creating service-mesh ACL policy..."
cat > /tmp/service-mesh-policy.hcl << 'EOF'
service_prefix "" { policy = "write" }
node_prefix ""    { policy = "read"  }
agent_prefix ""   { policy = "read"  }
EOF

consul acl policy create \
  -http-addr="$CONSUL_ADDR" \
  -name=service-mesh \
  -rules=@/tmp/service-mesh-policy.hcl \
  2>/dev/null || echo "  policy already exists, skipping"

echo "Creating sidecar token (secret: $CONSUL_SIDECAR_TOKEN)..."
consul acl token create \
  -http-addr="$CONSUL_ADDR" \
  -policy-name=service-mesh \
  -secret="$CONSUL_SIDECAR_TOKEN" \
  2>/dev/null || echo "  token already exists, skipping"

# ── Fetch Consul CA trust domain ──────────────────────────────────────────
echo "Fetching Consul CA trust domain..."
TRUST_DOMAIN=""
i=1
while [ $i -le 30 ]; do
  TRUST_DOMAIN=$(wget -qO- \
    --header="X-Consul-Token: $CONSUL_HTTP_TOKEN" \
    "$CONSUL_ADDR/v1/agent/connect/ca/roots" 2>/dev/null \
    | grep -o '"TrustDomain":"[^"]*"' \
    | cut -d'"' -f4)
  if [ -n "$TRUST_DOMAIN" ]; then
    break
  fi
  echo "  attempt $i/30: CA not ready yet, retrying in 2s..."
  sleep 2
  i=$((i + 1))
done

if [ -z "$TRUST_DOMAIN" ]; then
  echo "ERROR: could not fetch trust domain from Consul CA after 30 attempts" >&2
  exit 1
fi

echo "  trust domain: $TRUST_DOMAIN"

# Extract the UUID portion (everything before ".consul")
UUID=$(printf '%s' "$TRUST_DOMAIN" | sed 's/\.consul$//')

# Consul's xDS listener references upstream clusters by this naming scheme:
#   {svc}.{namespace}.{datacenter}.internal.{uuid}.consul
SERVERS_CLUSTER="servers.default.dc1.internal.${UUID}.consul"
CHAT_CLUSTER="chat.default.dc1.internal.${UUID}.consul"

# SPIFFE URIs
GW_SPIFFE="spiffe://${TRUST_DOMAIN}/ns/default/dc/dc1/svc/gateway"
SRV_SPIFFE="spiffe://${TRUST_DOMAIN}/ns/default/dc/dc1/svc/servers"
CHT_SPIFFE="spiffe://${TRUST_DOMAIN}/ns/default/dc/dc1/svc/chat"

# SDS config shared by both leaf-cert and CA-bundle requests
SDS='{"api_config_source":{"api_type":"GRPC","transport_api_version":"V3","grpc_services":[{"envoy_grpc":{"cluster_name":"local_agent"}}],"set_node_on_first_message_only":true},"resource_api_version":"V3"}'

# build_cluster_json <cluster_name> <dns_addr> <port> <peer_san>
# Prints a single-line Envoy Cluster protobuf JSON with STRICT_DNS + mTLS.
# Uses globals: GW_SPIFFE, SDS
build_cluster_json() {
  _CN="$1"; _ADDR="$2"; _PORT="$3"; _SAN="$4"
  printf '{"@type":"type.googleapis.com/envoy.config.cluster.v3.Cluster","name":"%s","type":"STRICT_DNS","connect_timeout":"5s","dns_lookup_family":"V4_ONLY","load_assignment":{"cluster_name":"%s","endpoints":[{"lb_endpoints":[{"endpoint":{"address":{"socket_address":{"address":"%s","port_value":%s}}}}]}]},"transport_socket":{"name":"envoy.transport_sockets.tls","typed_config":{"@type":"type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext","common_tls_context":{"tls_params":{"tls_minimum_protocol_version":"TLSv1_2"},"tls_certificate_sds_secret_configs":[{"name":"%s","sds_config":%s}],"combined_validation_context":{"default_validation_context":{"match_typed_subject_alt_names":[{"san_type":"URI","matcher":{"exact":"%s"}}]},"validation_context_sds_secret_config":{"name":"ROOTCA","sds_config":%s}}}}}}' \
    "$_CN" "$_CN" "$_ADDR" "$_PORT" "$GW_SPIFFE" "$SDS" "$_SAN" "$SDS"
}

# Escape the cluster JSON to embed it as a JSON string value (escape \ then ")
SERVERS_ESC=$(build_cluster_json "$SERVERS_CLUSTER" "servers" "21001" "$SRV_SPIFFE" \
  | sed 's/\\/\\\\/g; s/"/\\"/g')
CHAT_ESC=$(build_cluster_json "$CHAT_CLUSTER" "chat" "21000" "$CHT_SPIFFE" \
  | sed 's/\\/\\\\/g; s/"/\\"/g')

cat > /tmp/gw-defaults.json <<JSONEOF
{
  "Kind": "service-defaults",
  "Name": "gateway",
  "UpstreamConfig": {
    "Overrides": [
      { "Name": "servers", "EnvoyClusterJSON": "${SERVERS_ESC}" },
      { "Name": "chat",    "EnvoyClusterJSON": "${CHAT_ESC}" }
    ]
  }
}
JSONEOF

echo "Writing proxy-defaults..."
consul config write -http-addr="$CONSUL_ADDR" /config/proxy-defaults.json || {
  echo "ERROR: failed to write proxy-defaults" >&2
  exit 1
}

# ── Chat service: L7 protocol + retry policy ──────────────────────────────
# Protocol: http enables L7 routing on the chat sidecar (required for
# service-router retries to be applied by the gateway-sidecar outbound proxy).
echo "Writing chat service-defaults (protocol: http)..."
cat > /tmp/chat-service-defaults.json << 'EOF'
{
  "Kind": "service-defaults",
  "Name": "chat",
  "Protocol": "http"
}
EOF
consul config write -http-addr="$CONSUL_ADDR" /tmp/chat-service-defaults.json || {
  echo "ERROR: failed to write chat service-defaults" >&2
  exit 1
}

# Retry policy: up to 2 automatic retries on transient 502/503 responses.
# Independent of the application-level circuit breaker, which trips on
# timeouts (context.DeadlineExceeded) — not on 5xx status codes.
echo "Writing chat service-router (2 retries on 502/503)..."
cat > /tmp/chat-service-router.json << 'EOF'
{
  "Kind": "service-router",
  "Name": "chat",
  "Routes": [
    {
      "Destination": {
        "Service": "chat",
        "NumRetries": 2,
        "RetryOnStatusCodes": [502, 503]
      }
    }
  ]
}
EOF
consul config write -http-addr="$CONSUL_ADDR" /tmp/chat-service-router.json || {
  echo "ERROR: failed to write chat service-router" >&2
  exit 1
}

echo "Writing gateway service-defaults..."
consul config write -http-addr="$CONSUL_ADDR" /tmp/gw-defaults.json || {
  echo "ERROR: failed to write gateway service-defaults" >&2
  exit 1
}

echo "=== Config entries applied successfully ==="
