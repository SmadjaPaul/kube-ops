#!/usr/bin/env bash
# PLT-149 contract for the exact-name split-DNS resolver (k8s/infrastructure/network/dns-exact-resolver).
# Static only: renders the kustomize root, validates invariants, then checks that
# deliberately broken copies FAIL (negative cases). No cluster, network or DNS access.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
root="$repo_root/k8s/infrastructure/network/dns-exact-resolver"
work="$(mktemp -d "${TMPDIR:-/tmp}/dns-exact-resolver-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

command -v kustomize >/dev/null 2>&1 || { echo 'DNS_EXACT_RESOLVER_CONTRACT_TEST=BLOCKED missing_tool=kustomize' >&2; exit 2; }
kustomize build "$root" > "$work/render.yaml"

python3 -I - "$work/render.yaml" <<'PY'
import copy, ipaddress, re, sys
import yaml

FQDN = re.compile(r"^(?=.{1,253}$)([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$")
VIP = "10.0.20.192"          # Gateway/internal VIP (cilium-gateway-internal)
GATEWAY_EXTERNAL = "10.0.20.193"
POOL = ipaddress.ip_network("10.0.20.192/28")
UNIFI = "10.0.20.1"
EXCLUDED = {"tv.smadja.dev"}
TYPES = ("A", "AAAA", "HTTPS", "SVCB")


def docs_of(render):
    return [d for d in yaml.safe_load_all(render) if d]


def find(docs, kind, name):
    return next(d for d in docs if d.get("kind") == kind and d["metadata"]["name"] == name)


def parse_corefile(text):
    """Return {qtype: (match_regex, answer_or_None, rcode, fallthrough)} for the four template blocks."""
    blocks = {}
    for m in re.finditer(r"template IN (\w+) smadja\.dev \{(.*?)\n\s*\}", text, re.S):
        qtype, body = m.group(1), m.group(2)
        match = re.search(r'match "([^"]*)"', body)
        answer = re.search(r'answer "([^"]*)"', body)
        rcode = re.search(r"rcode (\S+)", body)
        blocks[qtype] = (
            match.group(1) if match else None,
            answer.group(1) if answer else None,
            rcode.group(1) if rcode else None,
            "fallthrough" in body,
        )
    return blocks


def names_from_regex(regex):
    if not (regex.startswith("^(") and regex.endswith(")[.]$")):
        return None
    return [n.replace("[.]", ".") for n in regex[2:-len(")[.]$")].split("|")]



def simulate(blocks, qname, qtype):
    """Documented CoreDNS 1.14 template semantics (plugin/template: ServeDNS + match):
    zone gate (smadja.dev) else next plugin; per template in Corefile order: a TYPE
    mismatch always continues to the next template; a regex mismatch continues only
    with `fallthrough`, else SERVFAIL; a regex match answers (empty answer + NOERROR
    = NODATA) and never falls through; no template left = next plugin (forward)."""
    if not (qname == "smadja.dev." or qname.endswith(".smadja.dev.")):
        return "forward"
    for t in ("A", "AAAA", "HTTPS", "SVCB"):  # Corefile order is checked separately
        if t not in blocks:
            continue
        regex, answer, rcode, fall = blocks[t]
        if t != qtype:
            continue
        if re.search(regex, qname):
            return "A:" + answer.rsplit(" ", 1)[-1] if answer else "NODATA" if rcode == "NOERROR" else "rcode:" + str(rcode)
        if not fall:
            return "SERVFAIL"
    return "forward"

def problems(docs, corefile_override=None, service_ip=None, cnp_mutator=None, deploy_mutator=None):
    bad = []
    cm = find(docs, "ConfigMap", "dns-exact-resolver")
    text = corefile_override if corefile_override is not None else cm["data"]["Corefile"]

    if "*" in text:
        bad.append("Corefile contains '*' (wildcard)")
    if not re.search(r"^\s*\.:1053 \{", text, re.M):
        bad.append("Corefile must listen on 1053 (non-root pod; Service maps 53)")
    if re.search(r"^\s*forward\b.*(10\.96\.0\.10|kube-dns)", text, re.M):
        bad.append("Corefile forwards toward kube-dns (loop risk)")
    if not re.search(r"^\s*forward \. " + re.escape(UNIFI) + r"\s*$", text, re.M):
        bad.append("Corefile must forward non-listed names to UniFi " + UNIFI)
    if re.search(r"^\s*(kubernetes|hosts|file)\b", text, re.M):
        bad.append("Corefile enables a plugin outside the contract (kubernetes/hosts/file)")

    blocks = parse_corefile(text)
    if set(blocks) != set(TYPES):
        bad.append(f"template blocks must be exactly {TYPES}, got {sorted(blocks)}")
    regexes = {q: blocks[q][0] for q in blocks}
    if len(set(regexes.values())) != 1 or None in regexes.values():
        bad.append("the four template blocks must share one identical exact-name match")
    names = names_from_regex(next(iter(regexes.values()))) if regexes else None
    if not names:
        bad.append("exact-name match is not a plain alternation of exact names")
        names = []
    if len(names) != len(set(names)):
        bad.append("duplicate names in the exact-name list")
    for n in names:
        if not FQDN.match(n):
            bad.append(f"{n}: not an exact FQDN")
        if not n.endswith(".smadja.dev") or n.count(".") < 2 or n == "smadja.dev":
            bad.append(f"{n}: apex or outside smadja.dev")
        if n in EXCLUDED:
            bad.append(f"{n}: excluded name (tv.smadja.dev) listed")
        if "*" in n:
            bad.append(f"{n}: wildcard")
    for required in ("media.smadja.dev", "auth.smadja.dev", "matrix.smadja.dev"):
        if required not in names:
            bad.append(f"{required}: required name missing")

    # NODATA contract: AAAA/HTTPS/SVCB answer NOERROR with no record; A is the VIP only.
    a_answer = blocks.get("A", (None, None, None, None))[1]
    if a_answer != "{{ .Name }} 300 IN A " + VIP:
        bad.append(f"A answer must be the Gateway VIP {VIP}, got {a_answer!r}")
    for q in ("AAAA", "HTTPS", "SVCB"):
        _, ans, rcode, fall = blocks.get(q, (None, None, None, None))
        if ans is not None or rcode != "NOERROR":
            bad.append(f"{q} must be NOERROR/NODATA (no answer, rcode NOERROR)")
        if not fall:
            bad.append(f"{q} must fall through non-listed names")

    # Behavioural check on the documented template semantics (no runtime available in CI).
    if not bad and names:
        order = re.findall(r"template IN (\w+) smadja\.dev", text)
        if order != list(TYPES):
            bad.append(f"template block order must be {TYPES}, got {order}")
        for n in (names[0], "media.smadja.dev"):
            q = n + "."
            if simulate(blocks, q, "A") != "A:" + VIP:
                bad.append(f"{n} A must answer the VIP")
            for t in ("AAAA", "HTTPS", "SVCB"):
                if simulate(blocks, q, t) != "NODATA":
                    bad.append(f"{n} {t} must be NODATA, never forwarded")
            if simulate(blocks, q, "TXT") != "forward":
                bad.append(f"{n} TXT must be forwarded")
        for n in ("tv.smadja.dev.", "smadja.dev.", "x.media.smadja.dev.", "mediaXsmadja.dev.", "example.com."):
            for t in TYPES:
                if simulate(blocks, n, t) != "forward":
                    bad.append(f"{n} {t} must be forwarded to UniFi (got {simulate(blocks, n, t)})")

    svc = find(docs, "Service", "dns-exact-resolver")
    ip = service_ip or svc["metadata"]["annotations"].get("lbipam.cilium.io/ips", "")
    try:
        addr = ipaddress.ip_address(ip)
        if addr not in POOL or ip in (VIP, GATEWAY_EXTERNAL):
            bad.append(f"LB IP {ip} must be in internal-gateway-pool and free (not {VIP}, {GATEWAY_EXTERNAL})")
    except ValueError:
        bad.append(f"LB IP annotation invalid: {ip!r}")
    if any(p.get("targetPort") not in ("dns-udp", "dns-tcp") for p in svc["spec"]["ports"]):
        bad.append("Service targetPort must be the named DNS container ports")
    if svc["spec"].get("type") != "LoadBalancer":
        bad.append("Service must be type LoadBalancer")
    if svc["spec"].get("externalTrafficPolicy") != "Local":
        bad.append("Service must use externalTrafficPolicy Local (keeps UniFi source IP)")
    protos = {(p["port"], p["protocol"]) for p in svc["spec"]["ports"]}
    if protos != {(53, "UDP"), (53, "TCP")}:
        bad.append("Service must expose exactly 53/UDP and 53/TCP")

    dep = find(docs, "Deployment", "dns-exact-resolver")
    if deploy_mutator:
        deploy_mutator(dep)
    pod = dep["spec"]["template"]["spec"]
    c = pod["containers"][0]
    if pod.get("dnsPolicy") != "Default":
        bad.append("dnsPolicy must be Default (no kube-dns dependency)")
    if pod.get("automountServiceAccountToken") is not False:
        bad.append("automountServiceAccountToken must be false")
    if not c.get("readinessProbe") or not c.get("livenessProbe"):
        bad.append("liveness and readiness probes are required")
    if not c.get("resources", {}).get("limits") or not c.get("resources", {}).get("requests"):
        bad.append("requests and limits are required")
    if not (c.get("securityContext", {}).get("runAsNonRoot") is True and pod.get("securityContext", {}).get("runAsNonRoot") is True):
        bad.append("runAsNonRoot must be true (container or pod level)")
    if (pod.get("securityContext", {}).get("runAsUser") in (0, None)) and c.get("securityContext", {}).get("runAsNonRoot") is not True:
        bad.append("runAsUser must be non-zero")
    if not c.get("securityContext", {}).get("readOnlyRootFilesystem"):
        bad.append("readOnlyRootFilesystem must be true")
    caps = c.get("securityContext", {}).get("capabilities", {})
    if "ALL" not in caps.get("drop", []):
        bad.append("capabilities.drop must contain ALL")
    if caps.get("add", []) != ["NET_BIND_SERVICE"]:
        bad.append(f"capabilities.add must be exactly [NET_BIND_SERVICE] (upstream /coredns file capability), got {caps.get('add')}")
    if c.get("securityContext", {}).get("allowPrivilegeEscalation") is not False:
        bad.append("allowPrivilegeEscalation must be false")
    if pod.get("securityContext", {}).get("seccompProfile", {}).get("type") != "RuntimeDefault":
        bad.append("seccompProfile must be RuntimeDefault")
    if dep["spec"].get("replicas", 1) != 1:
        bad.append("replicas must be 1 (single node, no PDB)")

    cnp = find(docs, "CiliumNetworkPolicy", "dns-exact-resolver")
    if cnp_mutator:
        cnp_mutator(cnp)
    spec = cnp["spec"]
    ingress_cidrs = [c for r in spec.get("ingress", []) for c in r.get("fromCIDR", [])]
    if ingress_cidrs != [UNIFI + "/32"]:
        bad.append(f"ingress DNS must come only from {UNIFI}/32, got {ingress_cidrs}")
    egress = spec.get("egress", [])
    egress_cidrs = [c for r in egress for c in r.get("toCIDR", [])]
    if egress_cidrs != [UNIFI + "/32"] or any(r.get("toEntities") or r.get("toEndpoints") or r.get("toFQDNs") for r in egress):
        bad.append(f"egress must be only to {UNIFI}/32")
    if "world" in str(spec) or "kube-apiserver" in str(spec):
        bad.append("policy must not open world or kube-apiserver")

    # PLT-149 lot 1.4: observability (scrape target + alerts).
    try:
        msvc = find(docs, "Service", "dns-exact-resolver-metrics")
        if [p.get("port") for p in msvc["spec"]["ports"]] != [9153] or msvc["spec"].get("type", "ClusterIP") != "ClusterIP":
            bad.append("metrics Service must be ClusterIP exposing only 9153")
        sm = find(docs, "ServiceMonitor", "dns-exact-resolver")
        if sm["metadata"]["labels"].get("release") != "kube-prometheus-stack":
            bad.append("ServiceMonitor needs label release=kube-prometheus-stack")
        if not all(msvc["metadata"]["labels"].get(k) == v for k, v in sm["spec"]["selector"]["matchLabels"].items()):
            bad.append("ServiceMonitor selector does not match the metrics Service")
        rule = find(docs, "PrometheusRule", "dns-exact-resolver")
        if rule["metadata"]["labels"].get("release") != "kube-prometheus-stack":
            bad.append("PrometheusRule needs label release=kube-prometheus-stack")
        alerts = {r["alert"] for g in rule["spec"]["groups"] for r in g["rules"]}
        for a in ("DnsExactResolverDown", "DnsExactResolverServfail", "DnsExactResolverHighLatency"):
            if a not in alerts:
                bad.append("missing alert " + a)
    except StopIteration:
        bad.append("metrics Service, ServiceMonitor and PrometheusRule must be rendered")

    return bad, names


docs = docs_of(open(sys.argv[1]).read())
good, names = problems(docs)
if good:
    for p in good:
        print("ASSERTION_FAILED " + p, file=sys.stderr)
    sys.exit(1)
print(f"exact names rendered: {len(names)}")

# Negative cases: each broken variant must be rejected.
cm = find(docs, "ConfigMap", "dns-exact-resolver")
core = cm["data"]["Corefile"]
first_regex = re.search(r'match "([^"]*)"', core).group(1)
cases = {
    "wildcard in list": core.replace(first_regex, first_regex.replace("^(", "^(*[.]smadja[.]dev|", 1)),
    "apex in list": core.replace(first_regex, first_regex.replace("^(", "^(smadja[.]dev|", 1)),
    "tv excluded name listed": core.replace(first_regex, first_regex.replace("^(", "^(tv[.]smadja[.]dev|", 1)),
    "blocks disagree": core.replace('match "' + first_regex + '"', 'match "' + first_regex.replace("^(", "^(zz[.]smadja[.]dev|", 1) + '"', 1),
    "AAAA answers": core.replace("template IN AAAA smadja.dev {", "template IN AAAA smadja.dev {\n        answer \"{{ .Name }} 300 IN AAAA 2001:db8::1\"", 1),
    "A without fallthrough (breaks non-listed A)": re.sub(r"(template IN A smadja\.dev \{.*?rcode NOERROR)\n\s*fallthrough", r"\1", core, count=1, flags=re.S),
    "AAAA without fallthrough (non-listed AAAA SERVFAIL)": re.sub(r"(template IN AAAA smadja\.dev \{.*?rcode NOERROR)\n\s*fallthrough", r"\1", core, count=1, flags=re.S),
    "SVCB without fallthrough": re.sub(r"(template IN SVCB smadja\.dev \{.*?rcode NOERROR)\n\s*fallthrough", r"\1", core, count=1, flags=re.S),
    "HTTPS rcode NXDOMAIN": re.sub(r"(template IN HTTPS smadja\.dev \{.*?)rcode NOERROR", r"\1rcode NXDOMAIN", core, count=1, flags=re.S),
    "blocks reordered": core.replace("template IN AAAA smadja.dev {", "template IN ZZZZ smadja.dev {", 1),
    "forward to kube-dns": core.replace("forward . 10.0.20.1", "forward . 10.96.0.10"),
    "A points elsewhere": core.replace("300 IN A 10.0.20.192\"", "300 IN A 10.0.20.194\"", 1),
}
for label, mutated in cases.items():
    bad, _ = problems(docs, corefile_override=mutated)
    if not bad:
        print(f"NEGATIVE_CASE_NOT_REJECTED {label}", file=sys.stderr)
        sys.exit(1)

for label, ip in {"LB on gateway internal VIP": "10.0.20.192", "LB on gateway external VIP": "10.0.20.193", "LB outside pool": "10.0.20.250"}.items():
    bad, _ = problems(docs, service_ip=ip)
    if not bad:
        print(f"NEGATIVE_CASE_NOT_REJECTED {label}", file=sys.stderr)
        sys.exit(1)

def open_world(cnp):
    cnp["spec"]["egress"].append({"toEntities": ["world"]})
bad, _ = problems(docs, cnp_mutator=open_world)
if not bad:
    print("NEGATIVE_CASE_NOT_REJECTED egress to world", file=sys.stderr)
    sys.exit(1)

def cluster_dns(dep):
    dep["spec"]["template"]["spec"]["dnsPolicy"] = "ClusterFirst"
bad, _ = problems(docs, deploy_mutator=cluster_dns)
if not bad:
    print("NEGATIVE_CASE_NOT_REJECTED dnsPolicy ClusterFirst", file=sys.stderr)
    sys.exit(1)

def sec_mut(fn):
    def m(dep):
        fn(dep["spec"]["template"]["spec"]["containers"][0]["securityContext"])
    return m

for label, fn in {
    "no capability added": lambda s: s["capabilities"].pop("add"),
    "SYS_ADMIN added": lambda s: s["capabilities"].__setitem__("add", ["NET_BIND_SERVICE", "SYS_ADMIN"]),
    "NET_RAW instead": lambda s: s["capabilities"].__setitem__("add", ["NET_RAW"]),
    "drop ALL removed": lambda s: s["capabilities"].__setitem__("drop", ["NET_RAW"]),
    "privilege escalation allowed": lambda s: s.__setitem__("allowPrivilegeEscalation", True),
}.items():
    bad, _ = problems(docs, deploy_mutator=sec_mut(fn))
    if not bad:
        print(f"NEGATIVE_CASE_NOT_REJECTED {label}", file=sys.stderr)
        sys.exit(1)

print("negative cases rejected: %d" % (len(cases) + 3 + 2 + 5))
PY

# Offline self-test of the runtime checker (no network): packet parsing + verdicts.
python3 -I - "$repo_root/scripts/plt149/check_resolver_nodata.py" <<'PY'
import importlib.util, struct, sys
spec = importlib.util.spec_from_file_location("chk", sys.argv[1])
chk = importlib.util.module_from_spec(spec); spec.loader.exec_module(chk)

def reply(name, qtype, answers=(), rcode=0, ttl=300):
    q = chk.build_query(name, qtype)[12:]
    body = b"".join(b"\xc0\x0c" + struct.pack(">HHIH", t, 1, ttl, len(r)) + r for t, r in answers)
    return struct.pack(">HHHHHH", 0x1234, 0x8400 | rcode, 1, len(answers), 0, 0) + q + body

vip = bytes([10, 0, 20, 192])
good = {"A": chk.parse_response(reply("a.smadja.dev", 1, [(1, vip)]))}
for t in ("AAAA", "HTTPS", "SVCB"):
    good[t] = chk.parse_response(reply("a.smadja.dev", chk.QTYPES[t]))
assert chk.evaluate("a.smadja.dev", good) == [], "good verdict"
bad = dict(good); bad["AAAA"] = chk.parse_response(reply("a.smadja.dev", 28, [(28, bytes(16))] * 2))
assert len(chk.evaluate("a.smadja.dev", bad)) == 1, "AAAA with answers must fail"
bad = dict(good); bad["HTTPS"] = chk.parse_response(reply("a.smadja.dev", 65, rcode=2))
assert chk.evaluate("a.smadja.dev", bad), "HTTPS SERVFAIL must fail"
bad = dict(good); bad["A"] = chk.parse_response(reply("a.smadja.dev", 1, [(1, vip)], ttl=5))
assert chk.evaluate("a.smadja.dev", bad), "A with upstream TTL must fail"
bad = dict(good); bad["A"] = chk.parse_response(reply("a.smadja.dev", 1, [(1, bytes([10, 0, 20, 194]))]))
assert chk.evaluate("a.smadja.dev", bad), "A != VIP must fail"
print("checker self-test ok")
PY

printf '%s\n' 'DNS_EXACT_RESOLVER_CONTRACT_TEST=PASS'
