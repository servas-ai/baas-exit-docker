# baas-exit-docker

Container image for a **BaaS exit node**: the browser sessions of your BaaS
tenant leave the internet through this container, so websites see the public
IP of the host it runs on.

The container joins the BaaS network as a Tailscale exit node. The host itself
needs **no Tailscale installation** and no account; all it needs is Docker.

## Requirements

- Linux host with Docker and `/dev/net/tun`
- A BaaS user that belongs to a tenant which the operator has enabled
- A **one-time exit key** from the BaaS Console

## 1. Build the image

```sh
git clone https://github.com/servas-ai/baas-exit-docker.git
cd baas-exit-docker
docker build -t baas-exit:local .
```

The base is the official `tailscale/tailscale` image, pinned by digest in the
`Dockerfile`. Override it with `--build-arg TAILSCALE_IMAGE=...` only if you
know why.

## 2. Get a one-time exit key

BaaS Console → **Tenant & exit keys → Issue one-time key**.

The key is valid for 10 minutes, works once and is shown once. Do not paste it
into files, chats or your shell history.

## 3. Start the exit node

```bash
read -r -s -p 'One-time exit key: ' TS_AUTHKEY; printf '\n'
export TS_AUTHKEY
docker run -d --pull=never --name baas-exit --restart=no --log-driver=none \
  --cap-add=NET_ADMIN --device=/dev/net/tun \
  --sysctl net.ipv4.ip_forward=1 --sysctl net.ipv6.conf.all.forwarding=1 \
  --read-only --tmpfs /run:rw,nosuid,nodev --tmpfs /tmp:rw,nosuid,nodev \
  --env TS_AUTHKEY --env TS_HOSTNAME=baas-exit \
  baas-exit:local
unset TS_AUTHKEY
```

`TS_HOSTNAME` is the name the node gets in the BaaS Console (letters, digits,
`-`; default `baas-exit`).

Then in the Console choose **Refresh status**: the node appears under
**Available tenant exits** as **online**. Once the operator has set it as your
tenant's default exit, sessions use it automatically:

```sh
bcli session create --wait
```

The public IP the browser shows must match the public IP of this Docker host.

## Stop and restart

```sh
docker stop baas-exit
```

While it is stopped, new sessions fail and running sessions lose internet
access (there is no fallback route). The node identity lives only in memory,
so a restart needs a **fresh key and a fresh container**:

```sh
docker rm baas-exit
# issue a new one-time key, then run step 3 again
```

## Security

- The enrollment key is read from the environment once, passed to
  `tailscale up` via stdin and then dropped. It never appears in arguments,
  files, logs or image layers. Still: never run `docker inspect` on the
  container or export its environment, because Docker keeps the variable the
  host passed in.
- No persistent state: `tailscaled` runs with `--state=mem:`. Do not add a
  state volume and do not use host networking.
- Built-in firewall rules in the container:
  - the node cannot open new connections into the BaaS network,
  - nothing from the BaaS network can open connections to the node itself,
  - forwarded session traffic cannot reach private, link-local, loopback,
    multicast or CGNAT ranges (no access to your LAN).
- The BaaS network policy additionally allows only sessions of your own tenant
  to use this exit.
- Revoking a key in the Console (**Exit keys**) stops further enrollments with
  it. It does not remove a node that is already enrolled; ask the operator to
  remove that node.

## Files

| File | Purpose |
| --- | --- |
| `Dockerfile` | official Tailscale image + nftables + entrypoint |
| `entrypoint.sh` | firewall rules, in-memory `tailscaled`, one-shot enrollment |
