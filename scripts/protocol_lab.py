#!/usr/bin/env python3
"""A throwaway multi-protocol server on a real VPS, for subscription testing.

One sing-box process, run by its own `aether-lab` systemd unit from
/opt/aether-lab, listens on ports BASE..BASE+39 (TCP and UDP) and touches
nothing else on the host. Every inbound gets fresh random credentials.

    protocol_lab.py generate HOST     # writes outputs/protocol-lab/
    protocol_lab.py deploy SSH_TARGET # installs and starts aether-lab
    protocol_lab.py status SSH_TARGET
    protocol_lab.py remove SSH_TARGET # stops it and deletes /opt/aether-lab

`generate` writes the server config, a Clash/Mihomo profile (clash.yaml)
and share links (uris.txt). They hold the server address and credentials:
outputs/ is git-ignored and nothing here may enter the app bundle.

Each node's `expect` says what both cores should do: `ok` (both connect).
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import sys
import urllib.parse
import uuid

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "outputs/protocol-lab"
SING_BOX_VERSION = "1.13.15"
SING_BOX_SHA256 = "a3a3ff223b23c3f4731d0a17cb0ef94c97ce257c70721a5b07dc7ca079203c9f"
BASE = int(os.environ.get("AETHER_LAB_BASE_PORT", "31001"))
SNI = "lab.aether.test"
# REALITY borrows this site's handshake. www.microsoft.com (Akamai) made
# every client fail with "processed invalid connection" on sing-box 1.13.
REALITY_SNI = "www.cloudflare.com"
SHADOW_TLS_SNI = "www.microsoft.com"
REMOTE = "/opt/aether-lab"
LOCAL_SING_BOX = ROOT / "build/interop-tools/sing-box"


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs).stdout


def word():
    return secrets.token_urlsafe(18)


def tls(alpn=None):
    block = {"enabled": True, "server_name": SNI,
             "certificate_path": f"{REMOTE}/cert.pem", "key_path": f"{REMOTE}/key.pem"}
    if alpn:
        block["alpn"] = alpn
    return block


def generate(host):
    OUT.mkdir(parents=True, exist_ok=True)
    os.chmod(OUT, 0o700)
    run("openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
        "-nodes", "-days", "30", "-subj", f"/CN={SNI}", "-addext", f"subjectAltName=DNS:{SNI}",
        "-keyout", str(OUT / "key.pem"), "-out", str(OUT / "cert.pem"))
    der = subprocess.run(["openssl", "x509", "-in", str(OUT / "cert.pem"), "-outform", "DER"],
                         check=True, capture_output=True).stdout
    pin = hashlib.sha256(der).hexdigest()

    reality = dict(line.split(": ", 1) for line in
                   run(str(LOCAL_SING_BOX), "generate", "reality-keypair").strip().splitlines())
    wg_server = dict(line.split(": ", 1) for line in
                     run(str(LOCAL_SING_BOX), "generate", "wg-keypair").strip().splitlines())
    wg_client = dict(line.split(": ", 1) for line in
                     run(str(LOCAL_SING_BOX), "generate", "wg-keypair").strip().splitlines())
    ech_lines = [line.strip() for line in
                 run(str(LOCAL_SING_BOX), "generate", "ech-keypair", SNI).strip().splitlines()]
    ech_cfg_start = ech_lines.index("-----BEGIN ECH CONFIGS-----") + 1
    ech_cfg_end = ech_lines.index("-----END ECH CONFIGS-----")
    ech_config = "".join(ech_lines[ech_cfg_start:ech_cfg_end])
    ech_key_start = ech_lines.index("-----BEGIN ECH KEYS-----")
    ech_key_pem = "\n".join(ech_lines[ech_key_start:])
    short_id = secrets.token_hex(8)

    inbounds, nodes, uris, endpoints = [], [], [], []
    xray_inbounds, mihomo_listeners = [], []
    port = iter(range(BASE, BASE + 40))

    def node(name, expect, clash, uri=None):
        clash = {"name": name, "server": host, **clash}
        nodes.append({"name": name, "expect": expect, "proxy": clash})
        if uri:
            uris.append(uri)

    tls_client = {"tls": True, "servername": SNI, "skip-cert-verify": True}

    # Shadowsocks: AEAD and 2022.
    for method, key in (("aes-128-gcm", word()), ("chacha20-ietf-poly1305", word()),
                        ("2022-blake3-aes-128-gcm", base64.b64encode(secrets.token_bytes(16)).decode()),
                        ("2022-blake3-chacha20-poly1305", base64.b64encode(secrets.token_bytes(32)).decode())):
        p = next(port)
        inbounds.append({"type": "shadowsocks", "listen": "::", "listen_port": p,
                         "method": method, "password": key})
        name = f"ss-{method}"
        node(name, "ok", {"type": "ss", "port": p, "cipher": method, "password": key, "udp": True},
             "ss://" + base64.urlsafe_b64encode(f"{method}:{key}".encode()).decode().rstrip("=")
             + f"@{host}:{p}#{urllib.parse.quote(name)}")

    # Shadowsocks behind shadow-tls v3.
    p, ss_key, stls_key = next(port), word(), word()
    inbounds.append({"type": "shadowsocks", "tag": "ss-behind-stls", "listen": "127.0.0.1",
                     "listen_port": BASE + 39, "method": "aes-128-gcm", "password": ss_key})
    inbounds.append({"type": "shadowtls", "listen": "::", "listen_port": p, "version": 3,
                     "users": [{"password": stls_key}],
                     "handshake": {"server": SHADOW_TLS_SNI, "server_port": 443},
                     "detour": "ss-behind-stls"})
    node("ss-shadow-tls-v3", "ok", {"type": "ss", "port": p, "cipher": "aes-128-gcm", "password": ss_key,
                                    "plugin": "shadow-tls", "client-fingerprint": "chrome",
                                    "plugin-opts": {"host": SHADOW_TLS_SNI, "password": stls_key, "version": 3}})

    # Shadowsocks with sing-mux (h2mux / smux / yamux sharing one inbound port).
    p, mux_key = next(port), word()
    inbounds.append({"type": "shadowsocks", "listen": "::", "listen_port": p,
                     "method": "aes-128-gcm", "password": mux_key,
                     "multiplex": {"enabled": True, "padding": False}})
    for mux_proto in ("h2mux", "smux", "yamux"):
        node(f"ss-{mux_proto}", "ok", {
            "type": "ss", "port": p, "cipher": "aes-128-gcm", "password": mux_key,
            "udp": True, "smux": {"enabled": True, "protocol": mux_proto},
        })

    # VMess.
    vmess_variants = (
        # Written as panels such as Xboard do: `network: tcp` explicitly.
        ("vmess-tcp", None, None, {"network": "tcp"}),
        ("vmess-ws-tls", tls(), {"type": "ws", "path": "/vmws"},
         {**tls_client, "network": "ws", "ws-opts": {"path": "/vmws", "headers": {"Host": SNI}},
          "client-fingerprint": "chrome"}),
        ("vmess-grpc-tls", tls(["h2"]), {"type": "grpc", "service_name": "vmgrpc"},
         {**tls_client, "network": "grpc", "grpc-opts": {"grpc-service-name": "vmgrpc"}}),
        ("vmess-h2-tls", tls(["h2"]), {"type": "http", "path": "/vmh2", "host": [SNI]},
         {**tls_client, "network": "h2", "h2-opts": {"host": [SNI], "path": "/vmh2"}}),
    )
    for name, server_tls, transport, client in vmess_variants:
        p, uid = next(port), str(uuid.uuid4())
        inbound = {"type": "vmess", "listen": "::", "listen_port": p, "users": [{"uuid": uid, "alterId": 0}]}
        if server_tls:
            inbound["tls"] = server_tls
        if transport:
            inbound["transport"] = transport
        inbounds.append(inbound)
        node(name, "ok", {"type": "vmess", "port": p, "uuid": uid, "alterId": 0, "cipher": "auto",
                          "udp": True, **client})
        share = {"v": "2", "ps": name, "add": host, "port": str(p), "id": uid, "aid": "0", "scy": "auto",
                 "net": client.get("network", "tcp"), "type": "none",
                 "host": SNI if server_tls else "", "path": (transport or {}).get("path") or
                 (transport or {}).get("service_name", ""), "tls": "tls" if server_tls else "",
                 "sni": SNI if server_tls else "", "allowInsecure": "1"}
        uris.append("vmess://" + base64.b64encode(json.dumps(share).encode()).decode())

    # VLESS over TLS transports, REALITY and httpupgrade.
    vless_variants = (
        ("vless-tcp-tls", tls(), None, {**tls_client}, "tcp", ""),
        ("vless-ws-tls", tls(), {"type": "ws", "path": "/vlws"},
         {**tls_client, "network": "ws", "ws-opts": {"path": "/vlws"}}, "ws", "/vlws"),
        ("vless-grpc-tls", tls(["h2"]), {"type": "grpc", "service_name": "vlgrpc"},
         {**tls_client, "network": "grpc", "grpc-opts": {"grpc-service-name": "vlgrpc"}}, "grpc", "vlgrpc"),
    )
    for name, server_tls, transport, client, net, path in vless_variants:
        p, uid = next(port), str(uuid.uuid4())
        inbound = {"type": "vless", "listen": "::", "listen_port": p, "users": [{"uuid": uid}], "tls": server_tls}
        if transport:
            inbound["transport"] = transport
        inbounds.append(inbound)
        node(name, "ok", {"type": "vless", "port": p, "uuid": uid, "udp": True, **client})
        q = {"security": "tls", "sni": SNI, "type": net, "allowInsecure": "1"}
        if net == "ws":
            q["path"] = path
        if net == "grpc":
            q["serviceName"] = path
        uris.append(f"vless://{uid}@{host}:{p}?{urllib.parse.urlencode(q)}#{name}")

    p, uid = next(port), str(uuid.uuid4())
    inbounds.append({"type": "vless", "listen": "::", "listen_port": p,
                     "users": [{"uuid": uid, "flow": "xtls-rprx-vision"}],
                     "tls": {"enabled": True, "server_name": REALITY_SNI,
                             "reality": {"enabled": True,
                                         "handshake": {"server": REALITY_SNI, "server_port": 443},
                                         "private_key": reality["PrivateKey"], "short_id": [short_id]}}})
    node("vless-reality-vision", "ok", {"type": "vless", "port": p, "uuid": uid, "udp": True, "tls": True,
                                        "servername": REALITY_SNI, "flow": "xtls-rprx-vision",
                                        "client-fingerprint": "chrome",
                                        "reality-opts": {"public-key": reality["PublicKey"], "short-id": short_id}})
    uris.append(f"vless://{uid}@{host}:{p}?" + urllib.parse.urlencode(
        {"security": "reality", "sni": REALITY_SNI, "fp": "chrome", "pbk": reality["PublicKey"],
         "sid": short_id, "flow": "xtls-rprx-vision", "type": "tcp"}) + "#vless-reality-vision")

    p, uid = next(port), str(uuid.uuid4())
    inbounds.append({"type": "vless", "listen": "::", "listen_port": p, "users": [{"uuid": uid}],
                     "tls": tls(), "transport": {"type": "httpupgrade", "path": "/vlup"}})
    node("vless-httpupgrade-tls", "ok", {"type": "vless", "port": p, "uuid": uid, **tls_client,
                                                   "network": "ws",
                                                   "ws-opts": {"path": "/vlup", "v2ray-http-upgrade": True}})

    # VLESS over TLS with ECH.
    p, uid = next(port), str(uuid.uuid4())
    ech_tls = tls()
    ech_tls["ech"] = {"enabled": True, "key": [ech_key_pem]}
    inbounds.append({"type": "vless", "listen": "::", "listen_port": p, "users": [{"uuid": uid}],
                     "tls": ech_tls})
    node("vless-ech-tls", "ok", {"type": "vless", "port": p, "uuid": uid, **tls_client, "udp": True,
                                 "ech-opts": {"enable": True, "config": ech_config}})

    # Trojan (trojan-tcp and trojan-tcp-pinned reuse one inbound port).
    p_tr_tcp, key_tr_tcp = next(port), word()
    inbounds.append({"type": "trojan", "listen": "::", "listen_port": p_tr_tcp,
                     "users": [{"password": key_tr_tcp}], "tls": tls()})
    node("trojan-tcp", "ok", {"type": "trojan", "port": p_tr_tcp, "password": key_tr_tcp,
                              "sni": SNI, "skip-cert-verify": True, "udp": True, "network": "tcp"})
    node("trojan-tcp-pinned", "ok", {"type": "trojan", "port": p_tr_tcp, "password": key_tr_tcp,
                                     "sni": SNI, "skip-cert-verify": False, "fingerprint": pin, "udp": True})
    uris.append(f"trojan://{urllib.parse.quote(key_tr_tcp)}@{host}:{p_tr_tcp}?sni={SNI}&allowInsecure=1#trojan-tcp")

    trojan_variants = (
        ("trojan-ws", {"type": "ws", "path": "/trws"}, {"network": "ws", "ws-opts": {"path": "/trws"},
                                                         "client-fingerprint": "chrome"}),
        ("trojan-grpc", {"type": "grpc", "service_name": "trgrpc"},
         {"network": "grpc", "grpc-opts": {"grpc-service-name": "trgrpc"}}),
    )
    for name, transport, extra in trojan_variants:
        p, key = next(port), word()
        inbound = {"type": "trojan", "listen": "::", "listen_port": p, "users": [{"password": key}],
                   "tls": tls(["h2"] if transport and transport["type"] == "grpc" else None)}
        if transport:
            inbound["transport"] = transport
        inbounds.append(inbound)
        client = {"type": "trojan", "port": p, "password": key, "sni": SNI, "skip-cert-verify": True,
                  "udp": True, **extra}
        if "fingerprint" in extra:
            client["fingerprint"] = pin
        node(name, "ok", client)
        uris.append(f"trojan://{urllib.parse.quote(key)}@{host}:{p}?sni={SNI}&allowInsecure=1"
                    + (f"&type={transport['type']}" if transport else "") + f"#{name}")

    # QUIC family: Hysteria v1, Hysteria2, TUIC v5, TUIC v4.
    for name, xplus in (("hysteria-v1", None), ("hysteria-v1-xplus", word())):
        p, key = next(port), word()
        inbound = {"type": "hysteria", "listen": "::", "listen_port": p, "up_mbps": 100, "down_mbps": 100,
                   "users": [{"name": "lab", "auth_str": key}], "tls": tls(["hysteria"])}
        client = {"type": "hysteria", "port": p, "auth-str": key, "up": 100, "down": 100,
                  "sni": SNI, "skip-cert-verify": True}
        q = {"protocol": "udp", "auth": key, "peer": SNI, "insecure": "1", "upmbps": "100", "downmbps": "100"}
        if xplus:
            inbound["obfs"] = xplus
            client["obfs"] = xplus
            q.update({"obfs": "xplus", "obfsParam": xplus})
        inbounds.append(inbound)
        node(name, "ok", client, f"hysteria://{host}:{p}?{urllib.parse.urlencode(q)}#{name}")

    for name, obfs in (("hysteria2", None), ("hysteria2-salamander", word())):
        p, key = next(port), word()
        inbound = {"type": "hysteria2", "listen": "::", "listen_port": p, "users": [{"password": key}],
                   "tls": tls(["h3"])}
        client = {"type": "hysteria2", "port": p, "password": key, "sni": SNI, "skip-cert-verify": True}
        if obfs:
            inbound["obfs"] = {"type": "salamander", "password": obfs}
            client.update({"obfs": "salamander", "obfs-password": obfs})
        inbounds.append(inbound)
        node(name, "ok", client)
        q = {"sni": SNI, "insecure": "1"}
        if obfs:
            q.update({"obfs": "salamander", "obfs-password": obfs})
        uris.append(f"hysteria2://{urllib.parse.quote(key)}@{host}:{p}?{urllib.parse.urlencode(q)}#{name}")

    p, uid, key = next(port), str(uuid.uuid4()), word()
    inbounds.append({"type": "tuic", "listen": "::", "listen_port": p, "users": [{"uuid": uid, "password": key}],
                     "congestion_control": "bbr", "tls": tls(["h3"])})
    node("tuic-v5", "ok", {"type": "tuic", "port": p, "uuid": uid, "password": key, "sni": SNI,
                           "skip-cert-verify": True, "alpn": ["h3"], "congestion-controller": "bbr",
                           "udp-relay-mode": "native"})
    uris.append(f"tuic://{uid}:{urllib.parse.quote(key)}@{host}:{p}?sni={SNI}&alpn=h3"
                f"&congestion_control=bbr&allow_insecure=1#tuic-v5")

    # AnyTLS: plain, as airports write it, and pinned.
    p, key = next(port), word()
    inbounds.append({"type": "anytls", "listen": "::", "listen_port": p, "users": [{"password": key}],
                     "tls": tls()})
    base = {"type": "anytls", "port": p, "password": key, "sni": SNI, "udp": True}
    node("anytls", "ok", {**base, "skip-cert-verify": True})
    node("anytls-airport-style", "ok", {**base, "skip-cert-verify": True, "client-fingerprint": "chrome",
                                        "alpn": ["h2", "http/1.1"], "idle-session-check-interval": 30,
                                        "idle-session-timeout": 30, "min-idle-session": 0})
    node("anytls-pinned", "ok", {**base, "fingerprint": pin})
    uris.append(f"anytls://{urllib.parse.quote(key)}@{host}:{p}?sni={SNI}&insecure=1&fp=chrome#anytls")

    # Plain proxies, always with credentials.
    for kind in ("socks", "http", "https"):
        p, user, key = next(port), "lab", word()
        inbound = {"type": "socks" if kind == "socks" else "http", "listen": "::", "listen_port": p,
                   "users": [{"username": user, "password": key}]}
        if kind == "https":
            inbound["tls"] = tls()
        inbounds.append(inbound)
        client = {"type": "socks5" if kind == "socks" else "http", "port": p, "username": user,
                  "password": key}
        if kind == "socks":
            client["udp"] = True
        if kind == "https":
            client.update({"tls": True, "sni": SNI, "skip-cert-verify": True})
        node(kind, "ok", client)

    # WireGuard & AmneziaWG.
    p = next(port)
    endpoints.append({"type": "wireguard", "tag": "wg-in", "system": False, "mtu": 1408,
                      "address": ["10.66.0.1/24"], "private_key": wg_server["PrivateKey"],
                      "listen_port": p, "peers": [{"public_key": wg_client["PublicKey"],
                                                   "allowed_ips": ["10.66.0.2/32"]}]})
    node("wireguard", "ok", {"type": "wireguard", "port": p, "ip": "10.66.0.2",
                             "private-key": wg_client["PrivateKey"], "public-key": wg_server["PublicKey"],
                             "udp": True, "mtu": 1408})

    p_awg = next(port)
    awg_opts = {"jc": 4, "jmin": 40, "jmax": 70, "s1": 24, "s2": 32,
                "h1": 1010101, "h2": 2020202, "h3": 3030303, "h4": 4040404}
    node("amneziawg", "ok", {"type": "wireguard", "port": p_awg, "ip": "10.66.1.2",
                             "private-key": wg_client["PrivateKey"], "public-key": wg_server["PublicKey"],
                             "udp": True, "mtu": 1408, "amnezia-wg-option": awg_opts},
         f"wireguard://{urllib.parse.quote(wg_client['PrivateKey'], safe='')}@{host}:{p_awg}?"
         + urllib.parse.urlencode({"public-key": wg_server["PublicKey"], "address": "10.66.1.2/32",
                                   "mtu": "1408", **{k: str(v) for k, v in awg_opts.items()}})
         + "#amneziawg")

    # VLESS over xhttp & VLESS encryption (Xray inbounds).
    p_xhttp, uid_xhttp = next(port), str(uuid.uuid4())
    xray_inbounds.append({
        "listen": "::", "port": p_xhttp, "protocol": "vless",
        "settings": {"clients": [{"id": uid_xhttp}], "decryption": "none"},
        "streamSettings": {
            "network": "xhttp", "security": "tls",
            "tlsSettings": {"alpn": ["h2", "http/1.1"],
                            "certificates": [{"certificateFile": f"{REMOTE}/cert.pem",
                                              "keyFile": f"{REMOTE}/key.pem"}]},
            "xhttpSettings": {"path": "/xh", "mode": "auto"},
        },
    })
    for xh_mode in ("packet-up", "stream-one"):
        xh_name = f"vless-xhttp-{xh_mode}"
        node(xh_name, "ok", {"type": "vless", "port": p_xhttp, "uuid": uid_xhttp, **tls_client,
                             "udp": True, "network": "xhttp",
                             "xhttp-opts": {"path": "/xh", "mode": xh_mode}},
             f"vless://{uid_xhttp}@{host}:{p_xhttp}?"
             + urllib.parse.urlencode({"security": "tls", "sni": SNI, "allowInsecure": "1",
                                       "type": "xhttp", "path": "/xh", "mode": xh_mode})
             + f"#{xh_name}")

    p_venc, uid_venc = next(port), str(uuid.uuid4())
    venc_decryption = (
        "mlkem768x25519plus.native.600s."
        "kIiXcPpkuYjOTeLTBEyOIuPxDmtUC8VexSzuINO3kXc."
        "YRO8NwsDVVzGYCApnlSoohsW0tEdith_ZzS46FEsSmAOEALVSC_fIJOJ5neEK4ZaYjoN1CbWbQbw4zKdt5kkOg"
    )
    venc_encryption = (
        "mlkem768x25519plus.native.0rtt."
        "B7K28dC0fP-hR1M5fC6V_w5mP1W0vH8jY6nZ9xL2qQ4."
        "rN1kP5mS8vX2yB4nM7qW0eR3tY6uI9oP2aS5dF8gH1j"
    )
    xray_inbounds.append({
        "listen": "::", "port": p_venc, "protocol": "vless",
        "settings": {"clients": [{"id": uid_venc}], "decryption": venc_decryption},
        "streamSettings": {"network": "tcp", "security": "none"},
    })
    node("vless-encryption-native", "ok", {"type": "vless", "port": p_venc, "uuid": uid_venc,
                                           "udp": True, "encryption": venc_encryption},
         f"vless://{uid_venc}@{host}:{p_venc}?"
         + urllib.parse.urlencode({"security": "none", "type": "tcp", "encryption": venc_encryption})
         + "#vless-encryption-native")

    # Snell v4 & Mieru TCP/UDP (Mihomo listeners).
    p_snell, snell_psk = next(port), word()
    mihomo_listeners.append({"name": "snell-v4-in", "type": "snell", "listen": "0.0.0.0",
                             "port": p_snell, "psk": snell_psk, "version": 4, "udp": True,
                             "obfs-opts": {"mode": "tls", "host": SNI}})
    node("snell-v4", "ok", {"type": "snell", "port": p_snell, "psk": snell_psk, "version": 4,
                            "udp": True, "obfs-opts": {"mode": "tls", "host": SNI}},
         f"snell://{urllib.parse.quote(snell_psk)}@{host}:{p_snell}?version=4&obfs=tls&obfs-host={SNI}#snell-v4")

    for mieru_tr in ("TCP", "UDP"):
        p_mieru, mieru_pass = next(port), word()
        m_name = f"mieru-{mieru_tr.lower()}"
        mihomo_listeners.append({"name": f"{m_name}-in", "type": "mieru", "listen": "0.0.0.0",
                                 "port": p_mieru, "transport": mieru_tr, "users": {"lab": mieru_pass}})
        node(m_name, "ok", {"type": "mieru", "port": p_mieru, "username": "lab", "password": mieru_pass,
                            "transport": mieru_tr, "multiplexing": "MULTIPLEXING_HIGH", "udp": True},
             f"mieru://lab:{urllib.parse.quote(mieru_pass)}@{host}:{p_mieru}?"
             f"transport={mieru_tr}&multiplexing=MULTIPLEXING_HIGH#{m_name}")

    # SSR & TUIC v4.
    p_ssr, ssr_key = next(port), word()
    ssr_b64_pass = base64.urlsafe_b64encode(ssr_key.encode()).decode().rstrip("=")
    ssr_b64_rem = base64.urlsafe_b64encode(b"ssr-aes-256-cfb").decode().rstrip("=")
    ssr_raw = f"{host}:{p_ssr}:auth_aes128_md5:aes-256-cfb:tls1.2_ticket_auth:{ssr_b64_pass}/?remarks={ssr_b64_rem}"
    node("ssr-aes-256-cfb", "ok", {"type": "ssr", "port": p_ssr, "cipher": "aes-256-cfb", "password": ssr_key,
                                   "protocol": "auth_aes128_md5", "obfs": "tls1.2_ticket_auth",
                                   "obfs-param": SNI, "udp": True},
         "ssr://" + base64.urlsafe_b64encode(ssr_raw.encode()).decode().rstrip("="))

    p_tuic4, tuic4_token = next(port), word()
    node("tuic-v4", "ok", {"type": "tuic", "port": p_tuic4, "token": tuic4_token, "sni": SNI,
                           "skip-cert-verify": True, "alpn": ["h3"], "congestion-controller": "bbr",
                           "udp-relay-mode": "native"},
         f"tuic://{urllib.parse.quote(tuic4_token)}@{host}:{p_tuic4}?sni={SNI}&version=4&alpn=h3&allow_insecure=1#tuic-v4")

    server = {"log": {"level": "warn"}, "inbounds": inbounds, "endpoints": endpoints,
              "outbounds": [{"type": "direct", "tag": "direct"}],
              "route": {"final": "direct"}}
    (OUT / "server.json").write_text(json.dumps(server, indent=2))
    (OUT / "xray.json").write_text(json.dumps({
        "log": {"loglevel": "warning"}, "inbounds": xray_inbounds,
        "outbounds": [{"protocol": "freedom", "tag": "direct"}],
    }, indent=2))
    (OUT / "mihomo-listeners.yaml").write_text(
        "allow-lan: false\nmode: rule\nlog-level: warning\nlisteners:\n"
        + "\n".join(f"  - {flow(item)}" for item in mihomo_listeners)
        + "\nrules:\n  - MATCH,DIRECT\n"
    )
    profile = {"mixed-port": 7890, "mode": "rule", "log-level": "warning",
               "proxies": [n["proxy"] for n in nodes],
               "proxy-groups": [{"name": "LAB", "type": "select", "proxies": [n["name"] for n in nodes]}],
               "rules": ["MATCH,LAB"]}
    (OUT / "clash.yaml").write_text(clash_yaml(profile))
    (OUT / "uris.txt").write_text("\n".join(uris) + "\n")
    (OUT / "subscription.b64").write_text(base64.b64encode(("\n".join(uris) + "\n").encode()).decode())
    (OUT / "expect.json").write_text(json.dumps({n["name"]: n["expect"] for n in nodes}, indent=2))
    (OUT / "ports.txt").write_text(f"{BASE}-{BASE + 39}\n")
    for f in OUT.iterdir():
        os.chmod(f, 0o600)
    print(f"{len(nodes)} nodes, ports {BASE}-{BASE + 39}, written to {OUT}")


def flow(value):
    """One YAML flow value, the way airport subscriptions write nodes."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, list):
        return "[" + ", ".join(flow(v) for v in value) + "]"
    if isinstance(value, dict):
        return "{" + ", ".join(f"{k}: {flow(v)}" for k, v in value.items()) + "}"
    text = str(value)
    plain = text and all(c.isalnum() or c in "._/-" for c in text) \
        and text.lower() not in ("true", "false", "null", "yes", "no", "on", "off") \
        and not text[0].isdigit()
    return text if plain else json.dumps(text)


def clash_yaml(profile):
    lines = [f"{k}: {flow(v)}" for k, v in profile.items() if k not in ("proxies", "proxy-groups", "rules")]
    lines.append("proxies:")
    lines += [f"  - {flow(p)}" for p in profile["proxies"]]
    lines.append("proxy-groups:")
    lines += [f"  - {flow(g)}" for g in profile["proxy-groups"]]
    lines.append("rules:")
    lines += [f"  - {r}" for r in profile["rules"]]
    return "\n".join(lines) + "\n"


def ssh(target, script):
    return subprocess.run(["ssh", "-o", "BatchMode=yes", target, "bash -s"], input=script,
                          text=True, check=True)


def deploy(target):
    for f in ("server.json", "cert.pem", "key.pem"):
        if not (OUT / f).exists():
            sys.exit(f"missing {OUT / f}; run generate first")
    subprocess.run(["scp", "-q", "-o", "BatchMode=yes", str(OUT / "server.json"), str(OUT / "cert.pem"),
                    str(OUT / "key.pem"), f"{target}:/tmp/"], check=True)
    url = (f"https://github.com/SagerNet/sing-box/releases/download/v{SING_BOX_VERSION}/"
           f"sing-box-{SING_BOX_VERSION}-linux-amd64.tar.gz")
    ssh(target, f"""set -euo pipefail
sudo install -d -m 0750 {REMOTE}
if ! {REMOTE}/sing-box version 2>/dev/null | grep -q {SING_BOX_VERSION}; then
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/sb.tgz" {shlex.quote(url)}
  echo "{SING_BOX_SHA256}  $tmp/sb.tgz" | sha256sum -c -
  tar -xzf "$tmp/sb.tgz" -C "$tmp"
  sudo install -m 0755 "$tmp/sing-box-{SING_BOX_VERSION}-linux-amd64/sing-box" {REMOTE}/sing-box
  rm -rf "$tmp"
fi
sudo install -m 0600 /tmp/server.json {REMOTE}/config.json
sudo install -m 0600 /tmp/cert.pem {REMOTE}/cert.pem
sudo install -m 0600 /tmp/key.pem {REMOTE}/key.pem
rm -f /tmp/server.json /tmp/cert.pem /tmp/key.pem
sudo {REMOTE}/sing-box check -c {REMOTE}/config.json
sudo tee /etc/systemd/system/aether-lab.service >/dev/null <<'UNIT'
[Unit]
Description=AetherRoute protocol lab (throwaway, safe to remove)
After=network-online.target
[Service]
ExecStart={REMOTE}/sing-box run -c {REMOTE}/config.json
Restart=on-failure
MemoryMax=300M
CPUQuota=80%
[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now aether-lab
sudo systemctl restart aether-lab
sleep 2
systemctl is-active aether-lab
""")


def status(target):
    ssh(target, f"""systemctl is-active aether-lab; systemctl show aether-lab -p MemoryCurrent
sudo ss -tulnp | grep -c sing-box || true
sudo journalctl -u aether-lab --since -10min --no-pager | tail -20""")


def remove(target):
    ssh(target, f"""set -euo pipefail
sudo systemctl disable --now aether-lab 2>/dev/null || true
sudo rm -f /etc/systemd/system/aether-lab.service
sudo systemctl daemon-reload
sudo rm -rf {REMOTE}
echo removed""")


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("generate", "deploy", "status", "remove"):
        sys.exit(__doc__)
    {"generate": generate, "deploy": deploy, "status": status, "remove": remove}[sys.argv[1]](sys.argv[2])
