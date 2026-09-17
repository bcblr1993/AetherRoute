#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PUBLIC="$ROOT/Services/WebDistribution/public"

test -d "$PUBLIC" || {
  echo "Error: public directory not found at $PUBLIC" >&2
  exit 1
}

# Verify required files for Cloudflare Pages
for file in "$PUBLIC/index.html" "$PUBLIC/404.html" "$PUBLIC/_headers" "$PUBLIC/_redirects" "$PUBLIC/robots.txt" "$PUBLIC/sitemap.xml"; do
  test -s "$file" || {
    echo "Error: missing required distribution file: $file" >&2
    exit 1
  }
done

echo "==> Deploying AetherRoute Web Distribution to Cloudflare Pages..."
npx --yes wrangler@3 pages deploy "$PUBLIC" --project-name=aetherroute --commit-dirty=true "$@"

echo "==> Successfully deployed to Cloudflare Pages: https://aetherroute.pages.dev/"
