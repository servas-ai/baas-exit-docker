#!/bin/sh
# BaaS exit node. The enrollment key is only needed on the first start; it
# never enters argv, a file, logs or an image layer.
# With a volume at /var/lib/baas-exit the node identity survives restarts
# (restart policy, host reboot). Without it the identity is in memory only.
set -eu
umask 077
fail() { printf '%s\n' "$1" >&2; exit 1; }
hostname=${TS_HOSTNAME:-baas-exit}
case "$hostname" in
  ''|*[!a-zA-Z0-9-]*) fail 'TS_HOSTNAME must be a DNS label' ;;
esac
auth_key=${TS_AUTHKEY:-}
unset TS_AUTHKEY
for executable in tailscale tailscaled iptables ip6tables; do
  command -v "$executable" >/dev/null || fail 'exit-node image is missing a runtime dependency'
done
[ -c /dev/net/tun ] || fail '/dev/net/tun is required'
mkdir -p /run/baas-exit
sock=/run/baas-exit/tailscaled.sock
state_dir=/var/lib/baas-exit
if [ -d "$state_dir" ] && [ -w "$state_dir" ]; then
  state="$state_dir/tailscaled.state"
else
  state=mem:
fi

# Append a rule only if it is not there yet (safe on container restart).
rule() {
  tool=$1; shift
  table=filter
  if [ "$1" = -t ]; then table=$2; shift 2; fi
  chain=$1; shift
  "$tool" -t "$table" -C "$chain" "$@" 2>/dev/null || "$tool" -t "$table" -A "$chain" "$@"
}
# Defense in depth: this exit node cannot initiate Tailnet traffic, nor
# forward session traffic into its host's private LAN. Tailscale ACLs still
# enforce the tenant boundary at both ends and must be provisioned first.
rule iptables -t mangle OUTPUT -o tailscale0 -m conntrack ! --ctstate ESTABLISHED,RELATED -j DROP
rule ip6tables -t mangle OUTPUT -o tailscale0 -m conntrack ! --ctstate ESTABLISHED,RELATED -j DROP
# No remote access to the node itself: new connections from the Tailnet to
# the container (as opposed to forwarded exit traffic) are dropped.
rule iptables INPUT -i tailscale0 -m conntrack ! --ctstate ESTABLISHED,RELATED -j DROP
rule ip6tables INPUT -i tailscale0 -m conntrack ! --ctstate ESTABLISHED,RELATED -j DROP
for cidr in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4; do
  rule iptables -t mangle FORWARD -i tailscale0 -d "$cidr" -j DROP
done
for cidr in ::1/128 fc00::/7 fe80::/10 ff00::/8; do
  rule ip6tables -t mangle FORWARD -i tailscale0 -d "$cidr" -j DROP
done

# Silence the daemon's upstream diagnostics; only our secret-free
# readiness/errors are printed.
tailscaled --state="$state" --socket="$sock" --tun=tailscale0 >/dev/null 2>&1 &
daemon_pid=$!
cleanup() {
  auth_key=
  kill "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 0' INT TERM
attempt=0
while [ ! -S "$sock" ]; do
  kill -0 "$daemon_pid" 2>/dev/null || fail 'tailscaled could not start'
  attempt=$((attempt+1))
  [ "$attempt" -lt 100 ] || fail 'tailscaled startup timed out'
  sleep 0.1
done

# Already enrolled (identity from the state volume)? Then no key is needed.
backend=
attempt=0
while :; do
  backend=$(tailscale --socket="$sock" status --json --peers=false 2>/dev/null \
    | sed -n 's/.*"BackendState": *"\([A-Za-z]*\)".*/\1/p' | head -n 1) || true
  case "$backend" in NeedsLogin|Starting|Running|Stopped) break ;; esac
  attempt=$((attempt+1))
  [ "$attempt" -lt 150 ] || fail 'tailscaled did not report a state'
  sleep 0.1
done

set -- --hostname="$hostname" --advertise-exit-node --accept-routes=false \
  --accept-dns=false --ssh=false --timeout=60s
if [ "$backend" = NeedsLogin ]; then
  [ -n "$auth_key" ] || fail 'not enrolled yet: TS_AUTHKEY (one-time exit key) is required'
  if ! printf '%s' "$auth_key" | tailscale --socket="$sock" up --auth-key=file:/dev/stdin "$@" >/dev/null 2>&1; then
    auth_key=
    fail 'exit-node enrollment failed; issue a fresh one-time key'
  fi
  auth_key=
  printf '%s\n' 'BaaS exit node enrolled; wait until it shows as online in the BaaS Console.'
else
  auth_key=
  tailscale --socket="$sock" up "$@" >/dev/null 2>&1 \
    || fail 'exit node could not reconnect; re-enroll with a fresh one-time key'
  printf '%s\n' 'BaaS exit node reconnected with its saved identity.'
fi
wait "$daemon_pid"
