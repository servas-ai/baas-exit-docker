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

## Start (one command)

```sh
git clone https://github.com/servas-ai/baas-exit-docker.git
cd baas-exit-docker
./up.sh            # if Docker needs root: sudo ./up.sh
```

`up.sh` builds the image, asks for the one-time exit key (hidden input) and
starts the container with restart policy `unless-stopped`.

Get the key in the BaaS Console: **Tenant & exit keys -> Issue one-time key**.
It is valid for 10 minutes, works once and is shown once. Do not paste it into
files, chats or your shell history.

Then in the Console choose **Refresh status**: the node appears under
**Available tenant exits** as **online**. Once it is your tenant's default exit
(the operator sets that once), sessions use it automatically:

```sh
bcli session create --wait
```

The public IP the browser shows is the public IP of this Docker host.

Optional settings: `TS_HOSTNAME=my-exit ./up.sh` (node name shown in the
Console; letters, digits, `-`; default `baas-exit`), `NAME=...` (container
name).

## Restarts and reboots

The node identity is saved in the Docker volume `baas-exit-state`. The key is
only needed the very first time: after `docker restart`, a Docker restart or
a host reboot the container comes back by itself and reconnects without a key.
Running `./up.sh` again is safe; it does nothing if the node is already running.

```sh
docker logs baas-exit       # status
docker stop baas-exit       # stop (stays stopped, also after reboot)
./up.sh                     # start again, no key needed
./up.sh --reset             # forget the identity and enroll with a new key
```

While the node is stopped, new sessions fail and running sessions lose
internet access (there is no fallback route).

## Security

- The enrollment key is read from the environment once, passed to
  `tailscale up` via stdin and then dropped. It never appears in arguments,
  files, logs or image layers. Still: never run `docker inspect` on the
  container or export its environment, because Docker keeps the variable the
  host passed in.
- The only persistent data is the node identity in the volume
  `baas-exit-state` (needed to survive reboots). Remove it with
  `./up.sh --reset`. Do not use host networking.
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
| `up.sh` | build, ask for the key, start with `unless-stopped` |
| `entrypoint.sh` | firewall rules, `tailscaled`, one-shot enrollment, reconnect with saved identity |
