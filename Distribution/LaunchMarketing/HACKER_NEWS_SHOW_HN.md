# Hacker News: Show HN Post

## Post Title
```
Show HN: AetherRoute – Native macOS routing client in Swift, TUN/Transparent Proxy, <35MB RAM
```

## Post Content / First Comment
```text
Hi HN,

For the past year, I've been frustrated by the state of proxy/routing clients on macOS. Almost every mainstream client today is either an Electron wrapper or a multi-platform port that eats 300MB+ RAM, lacks proper dark/light mode and accessibility support, and insists on brute-force overwriting the macOS system proxy (breaking internal dev servers, Docker, or local AI endpoints like Ollama).

I built AetherRoute (https://aetherroute.baizhiedu.xin/) to provide a truly native, macOS-first routing client.

Key architecture highlights:
- 100% Native Swift 6 / SwiftUI: Uses modern AppKit/SwiftUI components, supports Reduce Motion, VoiceOver, and consumes under 35MB of memory in idle and routing states.
- Dual System Network Extensions:
  * Transparent Proxy (`NEAppProxyProvider`): intercepts application network flows without changing your system-wide network proxy settings.
  * Packet Tunnel (`NEPacketTunnelProvider`): provides full-stack TUN packet capture for complete IPv4/IPv6 system routing.
- Protocol Engine: Integrated Rust/C data plane compiled strictly for Apple silicon (arm64), supporting VLESS + REALITY, Hysteria2, TUIC, VMess, Trojan, Shadowsocks, WireGuard, etc.
- Local Storage & Privacy: All configurations and subscription lists are encrypted at rest using AES-GCM, with keys stored in the macOS Data Protection Keychain. Zero analytics, zero phone-home pings, zero telemetry.
- Distribution: Distributed as an Apple Developer ID signed and Apple notarized DMG. Checksums are published transparently alongside every release.

Website: https://aetherroute.baizhiedu.xin/
Release notes: https://aetherroute.baizhiedu.xin/releases/

I would love to get your feedback on the architecture, UX, or Network Extension behaviors!
```
