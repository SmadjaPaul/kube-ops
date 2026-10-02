# qBittorrent + Gluetun V1 — staged

This package is intentionally not referenced by the media root yet.

The two containers share one Kubernetes Pod network namespace. qBittorrent
therefore uses the routes/firewall installed by Gluetun without Docker
`network_mode` tricks. Only qBittorrent belongs behind the VPN; Sonarr,
Radarr, Lidarr, Prowlarr, Bazarr, Jellyfin, BookOrbit and SABnzbd stay on the
normal cluster network.

## Activation blockers

1. Choose a supported VPN provider.
2. Add a provider-specific ExternalSecret named `gluetun-vpn`.
3. Add the narrow Cilium egress required by that provider/tunnel.
4. Canary `/dev/net/tun` on Talos with only `NET_ADMIN`.
5. If containerd returns an actual TUN permission error, review whether
   `privileged: true` is required for **Gluetun only**; do not broaden the
   qBittorrent container.
6. Configure qBittorrent WebUI credentials and categories:
   `tv`, `movies`, `music`, `books`.
7. Prove the kill switch: stopping the VPN must remove qBittorrent Internet
   reachability while normal Sonarr/Radarr/Lidarr egress remains unchanged.

The internal WebUI route is `https://qbittorrent.smadja.dev`.
Torrent peer ports are intentionally not exposed through a Kubernetes Service;
VPN port forwarding, when supported by the chosen provider, is handled through
Gluetun.
