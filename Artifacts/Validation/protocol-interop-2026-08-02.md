# Protocol interoperability evidence — 2026-08-02

- Status: passed
- Started: 2026-08-02T06:15:02Z
- Finished: 2026-08-02T06:15:40Z
- Source manifest SHA-256: `cc21ea438ebd8262bcbe331f4d41d1d206c16d836da0fe4fb2014fda2682cfe5`
- Test binary SHA-256: `b964b5724d0f553037600c45415ed0f78fc448da2f216fa234f259b3ec0895fa`
- Remote host class: Apple silicon macOS
- System proxy, DNS, default routes, and interface-list fingerprint: unchanged
- Staged source fingerprint: unchanged
- Temporary remote and controller workspaces: deleted

## Coverage

- sing-box: 21 HTTP(S), SOCKS5, Shadowsocks, VMess, VLESS, Trojan, AnyTLS, Hysteria2, and TUIC v5 scenarios; two cold-start cycles.
- Xray: VLESS REALITY handshake and restart recovery; two cycles.
- wireguard-go/gVisor: TCP, UDP, handler destruction/recreation, and server restart; two server cycles and three handler cycles per server.
- OpenSSH: Ed25519 public-key authentication, encrypted private-key passphrase, and host-key verification; two cycles.
- Mihomo: ShadowQUIC TCP, UDP, same-handler reconnect, 0-RTT rejection recovery, and server restart; two cycles.

## Raw-log digests

- `sing-box-matrix.log`: `30f372b8b59092f52bc0b54a136152e26347b276456da43deb9d5c0fea4f66a5`
- `xray-reality.log`: `aaee314c2eb2cea4f5a4d85d88d704e43e782845e28f1f718ce5ce55da5ab4e6`
- `wireguard-go.log`: `6c84f64f43f789daba19e461c1297bb68030b406de90c2c13f5d97faa12bbf4f`
- `openssh.log`: `9a7c94177a616ce750ecf6e6faa20a658b8b8d12b67392d51fd4ba625bbe170c`
- `mihomo-shadowquic.log`: `015427845bcaddcafb8499d4e3f62ef6f98a4de237a7633f4cf221e4a7725170`
- `result.env`: `47a2b1efd84cc4035075a390fa670518278262cf58caee616bff737efa69b1dc`

This evidence proves isolated client/server interoperability for the listed fixtures. It does not claim that arbitrary public nodes, unavailable servers, or future provider-specific extensions are valid.
