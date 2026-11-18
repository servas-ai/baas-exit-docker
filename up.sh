#!/usr/bin/env bash
# Start the BaaS exit node: builds the image, asks for the one-time exit key
# and runs the container with restart policy "unless-stopped".
#
#   ./up.sh            start (asks for the key only if not enrolled yet)
#   ./up.sh --reset    forget the saved identity and enroll again (new key)
#
# Settings (optional): NAME=baas-exit  TS_HOSTNAME=baas-exit  IMAGE=baas-exit:local
set -euo pipefail
cd "$(dirname "$0")"

NAME=${NAME:-baas-exit}
TS_HOSTNAME=${TS_HOSTNAME:-baas-exit}
IMAGE=${IMAGE:-baas-exit:local}
VOLUME="${NAME}-state"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
command -v docker >/dev/null || die 'docker is not installed'
docker info >/dev/null 2>&1 || die 'cannot talk to Docker (try: sudo ./up.sh)'
[ -c /dev/net/tun ] || die '/dev/net/tun is missing on this host'

if [ "${1:-}" = --reset ]; then
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker volume rm "$VOLUME" >/dev/null 2>&1 || true
  echo "Removed container and saved identity."
fi

echo "Building image $IMAGE ..."
docker build -q -t "$IMAGE" . >/dev/null

if docker container inspect "$NAME" >/dev/null 2>&1; then
  if [ "$(docker container inspect -f '{{.State.Running}}' "$NAME")" = true ]; then
    echo "$NAME is already running. Status: docker logs $NAME"
    exit 0
  fi
  docker rm "$NAME" >/dev/null
fi

key=
fresh=0
if ! docker volume inspect "$VOLUME" >/dev/null 2>&1; then
  echo "BaaS Console -> Tenant & exit keys -> Issue one-time key"
  read -r -s -p 'One-time exit key: ' key || true; printf '\n'
  key=$(printf '%s' "$key" | tr -d '[:space:]')
  [ -n "$key" ] || die 'no key entered'
  docker volume create "$VOLUME" >/dev/null
  fresh=1
else
  echo "Saved identity found, no key needed (use --reset to enroll again)."
fi

TS_AUTHKEY=$key docker run -d --name "$NAME" --restart unless-stopped \
  --cap-add=NET_ADMIN --device=/dev/net/tun \
  --sysctl net.ipv4.ip_forward=1 --sysctl net.ipv6.conf.all.forwarding=1 \
  --read-only --tmpfs /run:rw,nosuid,nodev --tmpfs /tmp:rw,nosuid,nodev \
  -v "$VOLUME:/var/lib/baas-exit" \
  --env TS_AUTHKEY --env TS_HOSTNAME="$TS_HOSTNAME" \
  "$IMAGE" >/dev/null
key=

echo "Waiting for the node to come up ..."
for _ in $(seq 1 90); do
  logs=$(docker logs "$NAME" 2>&1 || true)
  case "$logs" in
    *enrolled*|*reconnected*) echo "$logs" | tail -n 1; echo "OK: $NAME is up. Check the BaaS Console (Refresh status)."; exit 0 ;;
  esac
  if [ "$(docker container inspect -f '{{.State.Running}}' "$NAME")" != true ] || [ -n "$logs" ]; then
    case "$logs" in
      *failed*|*required*|*could*|*missing*|*must*)
        docker stop "$NAME" >/dev/null 2>&1 || true
        docker rm "$NAME" >/dev/null 2>&1 || true
        [ "$fresh" = 1 ] && docker volume rm "$VOLUME" >/dev/null 2>&1 || true
        die "$(echo "$logs" | tail -n 1)" ;;
    esac
  fi
  sleep 1
done
die "node did not come up within 90 s, see: docker logs $NAME"
