# Reddit Launch Posts

## 1. r/macapps Post

**Title**: 
`[Free] AetherRoute – A clean, native macOS routing & proxy app built with Swift & SwiftUI (TUN + Transparent Proxy, <35MB RAM, Apple Notarized)`

**Flair**: `Release` / `Free App`

**Body**:
Hey r/macapps!

If you use tools like Clash, Verge, or V2ray on macOS, you’ve probably noticed they’re almost always built on Electron, suck up lots of memory, and sometimes break your system proxy or dev ports (like Docker, Ollama, localhost:3000).

I spent months building **AetherRoute**—a 100% native macOS client written entirely in Swift and SwiftUI.

### Highlights:
- **True macOS Native UI**: Designed according to Apple Human Interface Guidelines with dark/light mode, keyboard navigation shortcuts (Cmd+1..6), and clean typography.
- **Under 35MB Memory**: Lightweight, fast startup, zero Electron bloat.
- **Dual Network Engines**:
  - **Packet Tunnel (TUN)**: Complete virtual adapter for full-system traffic.
  - **Transparent Proxy**: Captures traffic without constantly modifying your macOS System Settings proxy.
- **12 Modern Protocol Families**: VLESS + REALITY, Hysteria2, TUIC, VMess, Trojan, Shadowsocks, WireGuard, AnyTLS, etc.
- **Clash YAML Import & Native Subscriptions**: Easily import your existing subscription links or YAML files with strict boundary checking.
- **Privacy-First**: Profiles are encrypted with AES-GCM in your Apple Data Protection Keychain. Zero telemetry, no cloud accounts, no data collection.
- **Apple Notarized**: Signed with Apple Developer ID and passed Apple Notarization.

**Download & Info**: https://aetherroute.baizhiedu.xin/  
**Homebrew**: `brew install --cask aetherroute`

Feedback and feature requests are very welcome!

---

## 2. r/selfhosted Post

**Title**:
`AetherRoute: macOS native client for modern self-hosted proxy protocols (VLESS REALITY, Hysteria2, TUIC, WireGuard) with AES-GCM Keychain encryption`

**Flair**: `Software`

**Body**:
Hi r/selfhosted,

Many of us run self-hosted routing endpoints or VPS tunnels (Xray, Hysteria2, Sing-box, TUIC, WireGuard). However, client apps on macOS often suffer from messy configurations, sketchy third-party Electron wrappers, or intrusive system proxy tampering.

I built **AetherRoute** as a dedicated, native macOS routing client.

### Key Architecture for Self-Hosters:
- **Native Network Extensions**: Implements both `NEPacketTunnelProvider` and `NEAppProxyProvider`.
- **Fail-Closed Design**: If the network extension or protocol bridge isn't completely ready, traffic does not leak or half-connect.
- **Local Proxy Ports**: Local HTTP & SOCKS5 ports bind strictly to `127.0.0.1` and never write to macOS global proxy unless you explicitly copy the environment command.
- **Strict Configuration Sanitization**: When importing subscription YAMLs, script execution, external plug-ins, or remote WebUI downloads are completely disallowed to protect host integrity.
- **No telemetry / No telemetry servers**: All configuration data is stored locally with AES-GCM authenticated encryption.

Website: https://aetherroute.baizhiedu.xin/  
Would love feedback from fellow self-hosters managing modern VPS protocol nodes!
