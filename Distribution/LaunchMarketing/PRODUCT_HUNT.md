# Product Hunt Launch Kit: AetherRoute 1.0.0

## 1. Basic Information
- **Name**: AetherRoute
- **Tagline**: The private, native routing client engineered for Apple silicon
- **Website URL**: https://aetherroute.pages.dev/
- **Categories**: Developer Tools, Mac Apps, Privacy, Network & Utilities
- **Platforms**: macOS (Apple silicon M-series, macOS 15+)
- **Pricing**: 100% Free / Open Distribution (No subscription, No accounts required)

---

## 2. Product Description (Max 260 chars for short pitch)
AetherRoute is a blazing-fast, 100% native Swift 6 routing engine for macOS. Dual network extensions (Packet Tunnel + Transparent Proxy), zero telemetry, AES-GCM encrypted local storage, and instant switching across 12 modern protocol families.

---

## 3. Maker's First Comment (Pinned in discussion)

> Hey Product Hunt community! 👋
>
> I'm thrilled to introduce **AetherRoute** — a macOS-native routing and network client I built from scratch to fix everything that frustrated me about existing proxy tools on the Mac.
>
> ### Why AetherRoute?
> Most cross-platform proxy tools out there are bloated with Electron wrappers, constantly rewrite your global macOS system proxy settings, and consume 300MB+ of RAM just to sit in your menu bar. 
>
> We wanted something that genuinely belongs on macOS:
> 1. **100% Native Swift & SwiftUI**: Crafted exclusively for Apple silicon (M1-M4), consuming under 35MB of memory with instant cold starts and smooth 120Hz ProMotion UI.
> 2. **Dual Modern macOS Network Extensions**:
>    - **Packet Tunnel (TUN)**: Full virtual interface routing for complete IPv4/IPv6 packet handling.
>    - **Transparent Proxy**: Granular app-flow interception that avoids messing up your macOS system proxy settings.
> 3. **Zero Telemetry & Local Privacy By Design**: Your profiles are secured locally using AES-GCM with keys anchored directly in the Apple Data Protection Keychain. Zero analytics, zero cloud accounts, and completely fail-closed.
> 4. **12 Modern Protocol Families**: Out-of-the-box support for VLESS (with REALITY), VMess, Hysteria2, TUIC, AnyTLS, Trojan, Shadowsocks, WireGuard, ShadowQUIC, and more.
> 5. **Apple Notarized & Gatekeeper Ready**: Digitally signed with Apple Developer ID and fully notarized.
>
> ### Free to Use
> AetherRoute 1.0.0 is completely free to download and use. No ads, no tracking, and no paywalls.
>
> Try it out, install via Homebrew (`brew install --cask aetherroute`), and let me know what you think! I'm hanging out here all day to answer your questions and listen to your feedback. 🚀
