# BaaS exit node: a Tailscale exit node for one BaaS tenant.
# Base: official Tailscale image, pinned by digest (linux/amd64 + arm64 index).
ARG TAILSCALE_IMAGE=tailscale/tailscale:v1.102.3@sha256:8c42c4574ab066384fcb72f69e086a2ff1dd3652eb6f56856cee34bcf0d2f680
FROM ${TAILSCALE_IMAGE}

# nftables backend for tailscaled's own rules; iptables/ip6tables point to the
# nft frontends so our filter rules and tailscaled share one backend.
RUN apk add --no-cache nftables \
 && ln -sf /usr/sbin/iptables-nft /usr/sbin/iptables \
 && ln -sf /usr/sbin/ip6tables-nft /usr/sbin/ip6tables
ENV TS_DEBUG_FIREWALL_MODE=nftables

COPY --chmod=0755 entrypoint.sh /usr/local/bin/baas-exit
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD tailscale --socket=/run/baas-exit/tailscaled.sock status >/dev/null 2>&1 || exit 1
ENTRYPOINT ["/usr/local/bin/baas-exit"]
