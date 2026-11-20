#!/usr/bin/env python3
"""PLT-149 runtime proof for the exact-name resolver (dns-exact-resolver).

For every exact name of the Corefile: A must be the Gateway VIP with TTL 300
(the template's own TTL: UniFi/ExternalDNS answers carry TTL 5, so a TTL other
than 300 means the template did NOT answer), and AAAA/HTTPS(65)/SVCB(64) must be
NOERROR with zero answers (NODATA). Plain UDP, hand-built packets, stdlib only.

Interception guard: UniFi can redirect every UDP/53 packet of a VLAN to itself.
Before measuring, a sentinel address that cannot host a resolver is queried; if
it answers, the run is invalid (exit 3): the resolver was never reached. Run the
check from a path that is NOT intercepted (the resolver only accepts UniFi
10.0.20.1 per its CiliumNetworkPolicy), or through UniFi once it forwards the
names to the resolver (then use --server 10.0.20.1 --skip-sentinel).

Exit: 0 all good, 1 assertion failed, 2 usage/network error, 3 interception.
"""
import argparse
import os
import re
import socket
import struct
import sys

VIP = "10.0.20.192"
TEMPLATE_TTL = 300
QTYPES = {"A": 1, "AAAA": 28, "SVCB": 64, "HTTPS": 65}
HERE = os.path.dirname(os.path.abspath(__file__))
CONFIGMAP = os.path.join(HERE, "..", "..", "k8s", "infrastructure", "network",
                         "dns-exact-resolver", "configmap.yaml")


def build_query(name, qtype, qid=0x1234):
    header = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)  # RD=1, 1 question
    qname = b"".join(bytes([len(p)]) + p.encode("ascii") for p in name.rstrip(".").split(".")) + b"\x00"
    return header + qname + struct.pack(">HH", qtype, 1)


def skip_name(msg, off):
    while True:
        n = msg[off]
        if n == 0:
            return off + 1
        if n & 0xC0 == 0xC0:
            return off + 2
        off += 1 + n


def parse_response(msg):
    """Return dict(rcode, aa, ancount, answers=[(type, ttl, rdata)])."""
    if len(msg) < 12:
        raise ValueError("short DNS message")
    _, flags, qd, an, _, _ = struct.unpack(">HHHHHH", msg[:12])
    off = 12
    for _ in range(qd):
        off = skip_name(msg, off) + 4
    answers = []
    for _ in range(an):
        off = skip_name(msg, off)
        rtype, _cls, ttl, rdlen = struct.unpack(">HHIH", msg[off:off + 10])
        off += 10
        answers.append((rtype, ttl, msg[off:off + rdlen]))
        off += rdlen
    return {"rcode": flags & 0xF, "aa": bool(flags & 0x400), "ancount": an, "answers": answers}


def ask(server, port, name, qtype, timeout):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(build_query(name, qtype), (server, port))
        return parse_response(s.recv(4096))
    finally:
        s.close()


def names_from_configmap(path):
    text = open(path, encoding="utf-8").read()
    m = re.search(r'match "\^\(([^"]*)\)\[\.\]\$"', text)
    if not m:
        raise SystemExit("exact-name list not found in " + path)
    return [n.replace("[.]", ".") for n in m.group(1).split("|")]


def evaluate(name, results):
    """results: {type_name: parsed response}. Return a list of failure strings."""
    bad = []
    a = results["A"]
    ips = [socket.inet_ntoa(r[2]) for r in a["answers"] if r[0] == 1 and len(r[2]) == 4]
    if a["rcode"] != 0 or ips != [VIP]:
        bad.append(f"{name} A: rcode={a['rcode']} answers={ips} (expected exactly [{VIP}])")
    elif any(r[1] != TEMPLATE_TTL for r in a["answers"]):
        bad.append(f"{name} A: ttl={[r[1] for r in a['answers']]} (template TTL is {TEMPLATE_TTL}: "
                   "answer did not come from the template)")
    for t in ("AAAA", "HTTPS", "SVCB"):
        r = results[t]
        if r["rcode"] != 0 or r["ancount"] != 0:
            bad.append(f"{name} {t}: rcode={r['rcode']} answers={r['ancount']} (expected NOERROR, 0 answer)")
    return bad


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--server", default="10.0.20.194")
    p.add_argument("--port", type=int, default=53)
    p.add_argument("--timeout", type=float, default=3.0)
    p.add_argument("--configmap", default=CONFIGMAP)
    p.add_argument("--names", nargs="*", help="override the name list")
    p.add_argument("--sentinel", default="192.0.2.53", help="address that must NOT answer DNS")
    p.add_argument("--skip-sentinel", action="store_true")
    p.add_argument("--control", default="tv.smadja.dev", help="unlisted name: must not be SERVFAIL (fallthrough)")
    args = p.parse_args(argv)

    names = args.names or names_from_configmap(args.configmap)
    probe = names[0]

    if not args.skip_sentinel:
        try:
            ask(args.sentinel, args.port, probe, QTYPES["A"], min(args.timeout, 2.0))
        except (socket.timeout, OSError):
            pass
        else:
            print(f"INTERCEPTED: {args.sentinel} answered DNS; UDP/53 is redirected on this path, "
                  "the resolver was never queried. Measurement invalid.", file=sys.stderr)
            return 3

    failures = []
    try:
        for name in names:
            res = {t: ask(args.server, args.port, name, q, args.timeout) for t, q in QTYPES.items()}
            failures += evaluate(name, res)
        if args.control:
            for t in ("A", "AAAA"):
                r = ask(args.server, args.port, args.control, QTYPES[t], args.timeout)
                if r["rcode"] == 2:
                    failures.append(f"{args.control} {t}: SERVFAIL (non-listed names must reach the forward)")
    except (socket.timeout, OSError) as e:
        print(f"NETWORK_ERROR {e}", file=sys.stderr)
        return 2

    for f in failures:
        print("FAIL " + f, file=sys.stderr)
    if failures:
        return 1
    print(f"RESOLVER_NODATA_CHECK=PASS names={len(names)} server={args.server}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
