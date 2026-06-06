FROM hashicorp/consul:1.18 AS consul-bin
FROM envoyproxy/envoy:v1.28-latest
COPY --from=consul-bin /bin/consul /usr/local/bin/consul
ENTRYPOINT ["consul", "connect", "envoy"]
