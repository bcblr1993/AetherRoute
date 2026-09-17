#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WEB="$ROOT/Services/WebDistribution"
PUBLIC="$WEB/public"

test -x "$ROOT/scripts/deploy_cloudflare_pages.sh" || {
  echo "deploy_cloudflare_pages.sh must be executable" >&2
  exit 1
}

for required in \
  "$PUBLIC/index.html" \
  "$PUBLIC/404.html" \
  "$PUBLIC/_headers" \
  "$PUBLIC/_redirects" \
  "$PUBLIC/privacy/index.html" \
  "$PUBLIC/support/index.html" \
  "$PUBLIC/license/index.html" \
  "$PUBLIC/releases/index.html" \
  "$PUBLIC/releases/1.0.12/index.html" \
  "$PUBLIC/releases/1.0.11/index.html" \
  "$PUBLIC/releases/1.0.10/index.html" \
  "$PUBLIC/releases/1.0.9/index.html" \
  "$PUBLIC/releases/1.0.8/index.html" \
  "$PUBLIC/releases/1.0.7/index.html" \
  "$PUBLIC/releases/1.0.5/index.html" \
  "$PUBLIC/releases/1.0.4/index.html" \
  "$PUBLIC/releases/1.0.3/index.html" \
  "$PUBLIC/releases/1.0.2/index.html" \
  "$PUBLIC/releases/1.0.1/index.html" \
  "$PUBLIC/releases/1.0.0/index.html" \
  "$PUBLIC/releases/0.1.0-preview/index.html" \
  "$PUBLIC/assets/site.css" \
  "$PUBLIC/assets/site.js" \
  "$PUBLIC/assets/aetherroute-dark-zh.png" \
  "$PUBLIC/assets/aetherroute-dark-en.png" \
  "$PUBLIC/assets/favicon-dark.png" \
  "$PUBLIC/assets/apple-touch-icon.png" \
  "$PUBLIC/assets/aetherroute-mark.svg" \
  "$PUBLIC/assets/aetherroute-overview-zh.png" \
  "$PUBLIC/assets/aetherroute-overview-en.png" \
  "$PUBLIC/assets/aetherroute-profiles-zh.png" \
  "$PUBLIC/assets/aetherroute-profiles-en.png" \
  "$PUBLIC/assets/aetherroute-settings-zh.png" \
  "$PUBLIC/assets/aetherroute-settings-en.png" \
  "$PUBLIC/robots.txt" \
  "$PUBLIC/sitemap.xml" \
  "$PUBLIC/site.webmanifest"
do
  test -s "$required" || {
    echo "missing web distribution asset: $required" >&2
    exit 1
  }
done

rg -F 'AetherRoute 1.0.12' "$PUBLIC/index.html" >/dev/null
rg -F '1e4b5c8af64394e0a4f455f7b440e865d8e2f6806e36fe8513ac513f53d63e02' "$PUBLIC/index.html" >/dev/null

test "$(rg -c 'data-localized-image' "$PUBLIC/index.html")" -ge 1 || {
  echo "homepage must expose localized product screenshots" >&2
  exit 1
}
rg -F 'document.querySelectorAll("[data-localized-image]")' "$PUBLIC/assets/site.js" >/dev/null
test "$(rg -c '<img[^>]*data-localized-image[^>]*[[:space:]]src=' "$PUBLIC/index.html")" -ge 1 || {
  echo "localized screenshots require a resilient default source" >&2
  exit 1
}
if rg -n 'mock-(sidebar|main|nav|status|title|copy|switch|route)' "$PUBLIC"; then
  echo "product website still contains a placeholder interface" >&2
  exit 1
fi

if rg -n --glob '!README.md' \
  '(downloads\.example|updates\.example|baizhiedu\.xin|token=|password=)' \
  "$WEB"; then
  echo "web distribution contains a placeholder, obsolete domain, or credential" >&2
  exit 1
fi

support="$PUBLIC/support/index.html"
rg -F '通用 → 登录项与扩展' "$support" >/dev/null
rg -F '不要操作上方的“登录时打开”列表' "$support" >/dev/null
rg -F '点右侧信息按钮 ⓘ，打开 AetherRoute' "$support" >/dev/null
rg -F '已批准，重新检查' "$support" >/dev/null
rg -F '不需要降低系统安全性' "$support" >/dev/null
rg -F 'does not require disabling SIP' "$support" >/dev/null
rg -F 'https://support.apple.com/guide/mac-help/mtusr003/mac' "$support" >/dev/null

# Cloudflare Pages header security and cache guards
headers="$PUBLIC/_headers"
rg -F 'Content-Security-Policy' "$headers" >/dev/null
rg -F 'X-Frame-Options: DENY' "$headers" >/dev/null
rg -F 'X-Content-Type-Options: nosniff' "$headers" >/dev/null
rg -F 'Referrer-Policy: strict-origin-when-cross-origin' "$headers" >/dev/null
rg -F 'Cache-Control: public, max-age=0, must-revalidate' "$headers" >/dev/null

find "$PUBLIC" -name '*.html' -type f -print0 | while IFS= read -r -d '' html; do
  rg -F '<meta name="viewport"' "$html" >/dev/null || {
    echo "missing responsive viewport: $html" >&2
    exit 1
  }
  rg -F 'data-language-toggle' "$html" >/dev/null || {
    echo "missing language switch: $html" >&2
    exit 1
  }
  rg -F '/assets/site.css?v=20260914.08' "$html" >/dev/null || {
    echo "missing versioned stylesheet URL: $html" >&2
    exit 1
  }
  rg -F '/assets/site.js?v=20260916.05' "$html" >/dev/null || {
    echo "missing versioned script URL: $html" >&2
    exit 1
  }
done

for route in \
  /releases/ \
  /releases/1.0.12/ \
  /releases/1.0.11/ \
  /releases/1.0.10/ \
  /releases/1.0.9/ \
  /releases/1.0.8/ \
  /releases/1.0.7/ \
  /releases/1.0.5/ \
  /releases/1.0.4/ \
  /releases/1.0.3/ \
  /releases/1.0.2/ \
  /releases/1.0.1/ \
  /releases/1.0.0/ \
  /releases/0.1.0-preview/ \
  /privacy/ \
  /support/ \
  /license/
do
  rg -F "\"$route\"" "$PUBLIC/assets/site.js" >/dev/null || {
    echo "missing localized document title: $route" >&2
    exit 1
  }
done

# Check SEO and sitemap
rg -F 'https://aetherroute.pages.dev/sitemap.xml' "$PUBLIC/robots.txt" >/dev/null
rg -F 'https://aetherroute.pages.dev/releases/1.0.12/' "$PUBLIC/sitemap.xml" >/dev/null
rg -F 'https://aetherroute.pages.dev/releases/1.0.11/' "$PUBLIC/sitemap.xml" >/dev/null
rg -F 'https://aetherroute.pages.dev/releases/1.0.10/' "$PUBLIC/sitemap.xml" >/dev/null
rg -F 'https://aetherroute.pages.dev/releases/1.0.9/' "$PUBLIC/sitemap.xml" >/dev/null
rg -F 'https://aetherroute.pages.dev/releases/1.0.8/' "$PUBLIC/sitemap.xml" >/dev/null
rg -F 'https://aetherroute.pages.dev/releases/1.0.7/' "$PUBLIC/sitemap.xml" >/dev/null
rg -F 'https://aetherroute.pages.dev/releases/1.0.1/' "$PUBLIC/sitemap.xml" >/dev/null

echo "Web distribution static and Cloudflare Pages guards passed"
