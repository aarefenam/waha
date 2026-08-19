#!/usr/bin/env python3
"""Kelola rute publik Cloudflare Tunnel untuk satu instance WAHA.

Dipakai oleh `wahactl add` / `wahactl rm` supaya menambah pelanggan baru cukup
satu perintah: instance, ingress rule tunnel, dan record DNS sekaligus.

Kredensial dibaca dari environment (diisi wahactl dari cf-api.env):
    CF_API_TOKEN, CF_ACCOUNT_ID, CF_TUNNEL_ID, CF_ZONE_ID

Pemakaian:
    cf-route.py add <hostname> <service-url>
    cf-route.py del <hostname>
"""

import json
import os
import sys
import urllib.error
import urllib.request

API = "https://api.cloudflare.com/client/v4"


def env(name):
    value = os.environ.get(name, "").strip()
    if not value:
        fail(f"{name} belum diisi")
    return value


def fail(message):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def call(method, path, payload=None):
    url = f"{API}{path}"
    data = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", f"Bearer {env('CF_API_TOKEN')}")
    request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = json.load(response)
    except urllib.error.HTTPError as error:
        body = json.load(error)
    except urllib.error.URLError as error:
        fail(f"tidak bisa menghubungi Cloudflare: {error.reason}")
    if not body.get("success"):
        fail(f"Cloudflare menolak {method} {path}: {body.get('errors')}")
    return body.get("result")


def get_ingress():
    result = call("GET", f"/accounts/{env('CF_ACCOUNT_ID')}/cfd_tunnel/{env('CF_TUNNEL_ID')}/configurations")
    config = (result or {}).get("config") or {}
    return config.get("ingress") or []


def put_ingress(rules):
    # Cloudflare mewajibkan aturan terakhir tanpa hostname sebagai catch-all
    rules = [rule for rule in rules if rule.get("hostname")]
    rules.append({"service": "http_status:404"})
    call(
        "PUT",
        f"/accounts/{env('CF_ACCOUNT_ID')}/cfd_tunnel/{env('CF_TUNNEL_ID')}/configurations",
        {"config": {"ingress": rules}},
    )


def find_dns(hostname):
    records = call("GET", f"/zones/{env('CF_ZONE_ID')}/dns_records?name={hostname}")
    return records[0] if records else None


def add(hostname, service):
    rules = [rule for rule in get_ingress() if rule.get("hostname") != hostname]
    rules.append({"hostname": hostname, "service": service})
    put_ingress(rules)
    print(f"ingress  : {hostname} -> {service}")

    target = f"{env('CF_TUNNEL_ID')}.cfargotunnel.com"
    existing = find_dns(hostname)
    payload = {
        "type": "CNAME",
        "name": hostname,
        "content": target,
        "proxied": True,
        "comment": "WAHA via cloudflared",
    }
    if existing:
        call("PUT", f"/zones/{env('CF_ZONE_ID')}/dns_records/{existing['id']}", payload)
        print(f"dns      : {hostname} -> {target} (diperbarui)")
    else:
        call("POST", f"/zones/{env('CF_ZONE_ID')}/dns_records", payload)
        print(f"dns      : {hostname} -> {target} (baru)")


def delete(hostname):
    rules = get_ingress()
    if any(rule.get("hostname") == hostname for rule in rules):
        put_ingress([rule for rule in rules if rule.get("hostname") != hostname])
        print(f"ingress  : {hostname} dihapus")
    existing = find_dns(hostname)
    if existing:
        call("DELETE", f"/zones/{env('CF_ZONE_ID')}/dns_records/{existing['id']}")
        print(f"dns      : {hostname} dihapus")


def main():
    args = sys.argv[1:]
    if len(args) == 3 and args[0] == "add":
        add(args[1], args[2])
    elif len(args) == 2 and args[0] == "del":
        delete(args[1])
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
