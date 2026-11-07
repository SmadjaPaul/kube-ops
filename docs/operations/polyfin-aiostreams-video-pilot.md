# Polyfin 0.60 — AIOStreams in-cluster Stremio integration (PLT-134)

**Status: prepared, not installed.** This is a gated native addon install
for the existing Polyfin at `media.smadja.dev`. It keeps AIOStreams as the
**sole video aggregator**, with no duplicate Comet/Meteor/TMDB/addon installs.
Nebula/Eclipse music and the existing family AIOStreams configuration are
untouched.

## Private architecture

```text
Jellyfin-compatible client -> Polyfin (media.smadja.dev)
                              |
                              | Stremio manifest, catalogs, metadata, streams
                              v
                     http://aiostreams.media.svc.cluster.local:80
                              |
                              v
                         AIOStreams -> existing addons/TorBox (control only)
                              |
                              +-- direct client-to-CDN URL, when supported
```

AIOStreams Service is `aiostreams.media.svc.cluster.local:80`, with
Pod target port 3000. Cilium explicitly admits **Polyfin -> AIOStreams
TCP/3000** and AIOStreams ingress from the Polyfin Pod identity. No
wildcard LAN or Internet egress is opened by this PR.

**Do not use the public hostname as the runtime manifest destination.**
The existing `BASE_URL=https://aiostreams.smadja.dev` and legacy Gateway
path remain unchanged for existing clients. The operator may supply a
legacy saved manifest URL as an *input identifier*, but the helper rewrites
the exact approved origin to the private Service before installing it.
No HTTP request is sent to the public AIOStreams hostname by the helper.
The service can later move behind LAN/VPN access, independently of Polyfin.

### Private URL security

AIOStreams profile manifests often contain bearer-like path/query values.
Store the exact current manifest URL in a protected file (0600), obtained
through an approved operator secret source. Never put it in Git, a command
argument, a commit, Linear, a pod annotation, a debug log or a screenshot.

The helper accepts only:
- `http://aiostreams.media.svc.cluster.local/…/manifest.json` (preferred);
- `https://aiostreams.smadja.dev/…/manifest.json` (legacy input **rewritten**).

It refuses all other hostnames, ports, userinfo, fragments and protocols.
The upstream Polyfin v0.60 native admin API explicitly permits LAN manifest
sources for server administrators; members must not install private sources.
A local preflight uses an operator's `kubectl port-forward` to the Kubernetes
Service, preserving the opaque path/query, with redirects disabled.

```sh
# Operator terminal 1: control-plane tunnel, no exposed public addon URL
kubectl -n media port-forward svc/aiostreams 13000:80

# Operator terminal 2: never paste the tokenized URL into the CLI itself
export POLYFIN_AIOSTREAMS_MANIFEST_URL_FILE=/secure/path/aiostreams-manifest-url
node --test scripts/polyfin-aiostreams-pilot.test.mjs
node scripts/polyfin-aiostreams-pilot.mjs
# Preflight only: prints booleans and manifest counts; no source creation.
```

Install requires the existing native Polyfin admin authentication, either
`POLYFIN_ADMIN_COOKIE_FILE` or both `POLYFIN_ADMIN_USERNAME_FILE` and
`POLYFIN_ADMIN_PASSWORD_FILE`. These are already supported by
`scripts/polyfin-nebula-pilot.mjs` and verify `isAdministrator=true`.
Do not reuse family user OIDC cookies as administrator credentials.

```sh
# Explicit operator approval after successful private manifest preflight:
POLYFIN_APPLY_AIOSTREAMS=YES node scripts/polyfin-aiostreams-pilot.mjs --apply
```

Before creation the helper lists existing Stremio sources and refuses
a known AIOStreams/name collision. No replacement of Nebula or an
existing tokenized AIOStreams profile is permitted. Record only names,
kinds, enabled catalog counts and Polyfin-local UUID (not the secret URL).

## Acceptance before declaring video READY

1. Confirm exact Polyfin and AIOStreams Pod identities; Cilium/Hubble
   permits the Service destination at TCP/3000 without the legacy Gateway.
2. Fetch the configured manifest through the local port-forward, validate
   Stremio `stream` resource and movie/series type. Do not print the URL.
3. Native administrator installs at most one source with the **private**
   URL, using the already-qualified helper after explicit approval.
4. Inspect **Content -> Sources / Libraries**; if no video catalogs exist,
   report the missing capability without installing duplicate public addons.
5. Using authorized fixtures, verify FR/EN movie, anime JP+FR subtitles and
   one series, with non-admin family users. Assert stream/CDN handoff.
   Direct-client CDN playback must be *measured*, not assumed:
   Polyfin may relay/transcode depending on the client and source.
6. Verify source names, library state and no cross-user history leakage.
   Do not change `tv.smadja.dev`, AIOStreams's own configuration or Nebula.
7. Never silently remove a created addon: run a separately approved
   rollback, targeted to the exact Polyfin-local UUID only.

## Free radio pilot (PLT-135)

`k8s/applications/media/polyfin/radios-configmap.yaml` contains only a
curated, non-tokenized Radio France M3U (FIP and variants, Inter, Musique,
Info, Mouv). It is mounted read-only at `/iptv/radios.m3u`.

**It is not automatically registered as an IPTV source.** On the next
approved admin acceptance, test only this file from **Content -> Sources ->
IPTV source** with the full path `/iptv/radios.m3u`. Polyfin v0.60 permits
server-file M3U imports only to administrators. The audio-only playback
behavior of the Jellyfin-compatible client must be tested before calling
the radios READY. XMLTV is optional; no EPG is invented for the stations.

Free-to-watch *video* Live TV is a separate PLT-135 acceptance: require
an operator-verified, rights-compliant direct source and optional authorized
EPG. No Xtream credentials, pirated lists, DRM workarounds, unknown LAN
IPTV URLs, or broad egress are introduced.

References:
- https://github.com/moodiness/polyfin/blob/v0.60.0/docs/addons-and-libraries.md
- https://github.com/moodiness/polyfin/blob/v0.60.0/docs/iptv.md
- https://developers.radiofrance.fr/doc/tutorial-by-example/list-brands
- https://developers.radiofrance.fr/doc/tutorial-by-example/list-locals-and-webradios

## OpenTofu ownership

`terraform-provider-polyfin v0.1.0` requires HTTPS for
`manifest_url_wo` and is **not yet appropriate** for this HTTP private
Service URL. Do not force the current resource to take over an existing
addon, and do not migrate the AIOStreams state into Polyfin.
A separately tested provider change, release and explicit import by
Polyfin-local UUID are required before declarative ownership.
Atlantis stays plan-only; there is no production apply or import in this PR.
