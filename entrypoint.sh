#!/bin/sh
# A fresh in-memory Tailscale identity per container. No enrollment key enters
# argv, a file, logs, an image layer, or persistent Tailscale state.
set -eu
umask 077
fail() { printf '%s\n' "$1" >&2; exit 1; }
[ -n "${TS_AUTHKEY:-}" ] || fail 'TS_AUTHKEY is required'
case "${TS_HOSTNAME:-baas-exit}" in
  ''|*[!a-zA-Z0-9-]*) fail 'TS_HOSTNAME must be a DNS label' ;;
esac
auth_key=$TS_AUTHKEY
unset TS_AUTHKEY
for executable in tailscale tailscaled iptables ip6tables; do
  command -v "$executable" >/dev/null || fail 'exit-node image is missing a runtime dependency'
done
[ -c /dev/net/tun ] || fail '/dev/net/tun is required'
mkdir -p /run/baas-exit

# Defense in depth: this exit node cannot initiate Tailnet traffic, nor
# forward session traffic into its host's private LAN. Tailscale ACLs still
# enforce the tenant boundary at both ends and must be provisioned first.
iptables -t mangle -A OUTPUT -o tailscale0 -m conntrack ! --ctstate ESTABLISHED,RELATED -j DROP
ip6tables -t mangle -A OUTPUT -o tailscale0 -m conntrack ! --ctstate ESTABLISHED,RELATED -j DROP
# No remote access to the node itself: new connections from the Tailnet to
# the container (as opposed to forwarded exit traffic) are dropped.
iptables -A INPUT -i tailscale0 -m conntrack ! --ctstate ESTABLISHED,RELATED -j DROP
ip6tables -A INPUT -i tailscale0 -m conntrack ! --ctstate ESTABLISHED,RELATED -j DROP
for cidr in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4; do
  iptables -t mangle -A FORWARD -i tailscale0 -d "$cidr" -j DROP
done
for cidr in ::1/128 fc00::/7 fe80::/10 ff00::/8; do
  ip6tables -t mangle -A FORWARD -i tailscale0 -d "$cidr" -j DROP
done

# mem: prevents node credentials surviving the container. Silence the daemon's
# upstream diagnostics; only our secret-free readiness/errors are public.
tailscaled --state=mem: --socket=/run/baas-exit/tailscaled.sock --tun=tailscale0 >/dev/null 2>&1 &
daemon_pid=$!
cleanup() {
  unset auth_key
  kill "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 0' INT TERM
attempt=0
while [ ! -S /run/baas-exit/tailscaled.sock ]; do
  kill -0 "$daemon_pid" 2>/dev/null || fail 'tailscaled could not start'
  attempt=$((attempt+1))
  [ "$attempt" -lt 100 ] || fail 'tailscaled startup timed out'
  sleep 0.1
done
if ! printf '%s' "$auth_key" | tailscale --socket=/run/baas-exit/tailscaled.sock up \
    --auth-key=file:/dev/stdin --hostname="${TS_HOSTNAME:-baas-exit}" \
    --advertise-exit-node --accept-routes=false --accept-dns=false --ssh=false \
    --timeout=60s >/dev/null 2>&1; then
  unset auth_key
  fail 'exit-node enrollment failed; issue a fresh one-time key'
fi
unset auth_key
printf '%s\n' 'BaaS exit node enrolled; wait until it shows as online in the BaaS Console.'
wait "$daemon_pid"
