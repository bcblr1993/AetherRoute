# AetherRoute Web Distribution (Cloudflare Pages)

This directory contains the official, static web distribution site for AetherRoute. It is deployed to and hosted exclusively on **Cloudflare Pages**:

- **Official Web Site**: `https://www.aethernative.com/`
- **Releases Directory**: `https://www.aethernative.com/releases/`
- **Artifact Downloads**: Distributed directly via GitHub Releases (`https://github.com/bcblr1993/AetherRoute/releases`) with Apple Notarized DMGs and published SHA-256 checksums.

## Architecture

1. **Zero-Server Maintenance**: Pure static HTML/CSS/JS site with pre-rendered pages, requiring no VPS, Docker Swarm, or Nginx containers.
2. **Global Anycast Edge**: Automated SSL/TLS certificates and sub-30ms global latency through Cloudflare Pages CDN.
3. **Security Headers & Routing**: Configured via `public/_headers` and `public/_redirects` adhering to modern security policies (CSP, X-Frame-Options, HSTS).
4. **Independent Privacy Boundary**: No analytics, no tracking cookies, and no third-party telemetry scripts.

## Deployment

Deploying changes to Cloudflare Pages is automated using `wrangler`:

```sh
# Deploy directly to Cloudflare Pages production
./scripts/deploy_cloudflare_pages.sh
```

Or manually:

```sh
npx wrangler pages deploy Services/WebDistribution/public --project-name=aetherroute
```
