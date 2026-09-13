# Hacker News: Show HN Post

## Post Title
```
Show HN: AetherRoute – Native macOS routing client in Swift, TUN/Transparent Proxy, <35MB RAM
```

## Post Content / First Comment
```text
Hi HN,

For the past year, I've been frustrated by the state of proxy/routing clients on macOS. Almost every mainstream client today is either an Electron wrapper or a multi-platform port that eats 300MB+ RAM, lacks proper dark/light mode and accessibility support, and insists on brute-force overwriting the macOS system proxy (breaking internal dev servers, Docker, or local AI endpoints like Ollama).

I built AetherRoute (https://aetherroute.pages.dev/) to provide a truly native, macOS-first routing client.

### Key Highlights:
- **100% Native Swift & SwiftUI**: Crafted strictly for Apple silicon. Under 35MB idle RSS memory, instant cold launch, 120Hz smooth scrolling.
- **Dual Network Extensions**: Packet Tunnel (TUN) for system-wide virtual interface routing, and Transparent Proxy for granular flow routing without polluting macOS system proxy settings.
- **Fail-Closed Security**: Configuration profiles encrypted at rest using AES-GCM; keys anchored in the macOS Data Protection Keychain.
- **Comprehensive Protocol Support**: Native parsing and routing across 12 modern protocol families (VLESS + REALITY, VMess, Hysteria2, TUIC, AnyTLS, Trojan, Shadowsocks, WireGuard, ShadowQUIC, etc.).
- **Apple Notarized**: Signed with Apple Developer ID, notarized by Apple, Gatekeeper clean.

Website: https://aetherroute.pages.dev/
Release notes: https://aetherroute.pages.dev/releases/

I would love to get your feedback on the architecture, UX, or Network Extension behaviors!
```
