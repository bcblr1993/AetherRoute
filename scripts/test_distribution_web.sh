#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WEB="$ROOT/Services/WebDistribution"
PUBLIC="$WEB/public"

test -x "$ROOT/scripts/deploy_distribution_web.sh" || {
  echo "web deploy script must be executable" >&2
  exit 1
}
test -x "$ROOT/scripts/verify_distribution_web.sh" || {
  echo "web verifier must be executable" >&2
  exit 1
}
test -x "$ROOT/scripts/rollback_distribution_web.sh" || {
  echo "web rollback script must be executable" >&2
  exit 1
}
test -x "$ROOT/scripts/prepare_distribution_web_payload.sh" || {
  echo "stable web payload preparer must be executable" >&2
  exit 1
}
test -x "$ROOT/scripts/test_distribution_web_payload.sh" || {
  echo "stable web payload test must be executable" >&2
  exit 1
}

for required in \
  "$WEB/nginx.conf" \
  "$WEB/docker-stack.yml" \
  "$WEB/templates/stable-release.html" \
  "$PUBLIC/index.html" \
  "$PUBLIC/404.html" \
  "$PUBLIC/privacy/index.html" \
  "$PUBLIC/support/index.html" \
  "$PUBLIC/license/index.html" \
  "$PUBLIC/releases/index.html" \
  "$PUBLIC/releases/0.1.0-preview/index.html" \
  "$PUBLIC/assets/site.css" \
  "$PUBLIC/assets/site.js" \
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

rg -F '当前 0.1.0 技术预览真实界面' "$PUBLIC/index.html" >/dev/null
rg -F 'Not a concept render.' "$PUBLIC/index.html" >/dev/null
test "$(rg -c 'data-localized-image' "$PUBLIC/index.html")" -eq 3 || {
  echo "homepage must expose exactly three localized product screenshots" >&2
  exit 1
}
rg -F 'document.querySelectorAll("[data-localized-image]")' "$PUBLIC/assets/site.js" >/dev/null
test "$(rg -c '<img[^>]*data-localized-image[^>]*[[:space:]]src=' "$PUBLIC/index.html")" -eq 3 || {
  echo "localized screenshots require a resilient default source" >&2
  exit 1
}
if rg -n 'mock-(sidebar|main|nav|status|title|copy|switch|route)' "$PUBLIC"; then
  echo "product website still contains a placeholder interface" >&2
  exit 1
fi

if rg -n --glob '!README.md' \
  '(downloads\.example|updates\.example|http://(aetherroute|downloads|updates)\.baizhiedu\.xin|token=|password=)' \
  "$WEB"; then
  echo "web distribution contains a placeholder, insecure URL, or credential" >&2
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

rg -F 'user: "101:101"' "$WEB/docker-stack.yml" >/dev/null
rg -F 'read_only: true' "$WEB/docker-stack.yml" >/dev/null
rg -F 'type: tmpfs' "$WEB/docker-stack.yml" >/dev/null
rg -F 'target: /tmp' "$WEB/docker-stack.yml" >/dev/null
rg -F 'AETHERROUTE_WEB_IMAGE:?' "$WEB/docker-stack.yml" >/dev/null
rg -F 'AETHERROUTE_WEB_RELEASE_ROOT:?' "$WEB/docker-stack.yml" >/dev/null
rg -F 'docker-compose -f' "$ROOT/scripts/deploy_distribution_web.sh" >/dev/null
rg -F 'restore_previous' "$ROOT/scripts/deploy_distribution_web.sh" >/dev/null
rg -F 'COPYFILE_DISABLE=1 tar --no-xattrs' "$ROOT/scripts/deploy_distribution_web.sh" >/dev/null
rg -F 'AetherRoute web service did not become healthy' "$ROOT/scripts/deploy_distribution_web.sh" >/dev/null
rg -F "docker service rollback" "$ROOT/scripts/deploy_distribution_web.sh" >/dev/null
rg -F 'public verification failed; the new release was not activated' \
  "$ROOT/scripts/deploy_distribution_web.sh" >/dev/null
rg -F 'Deployed and publicly verified AetherRoute web release:' \
  "$ROOT/scripts/deploy_distribution_web.sh" >/dev/null
rg -F 'preview)' "$ROOT/scripts/deploy_distribution_web.sh" >/dev/null
rg -F 'stable)' "$ROOT/scripts/deploy_distribution_web.sh" >/dev/null
rg -F 'prepare_distribution_web_preview_payload.sh' \
  "$ROOT/scripts/deploy_distribution_web.sh" >/dev/null
test "$(rg -c 'ssh -o BatchMode=yes -o StrictHostKeyChecking=yes' \
  "$ROOT/scripts/deploy_distribution_web.sh")" -eq 4
rg -F 'scp -q -o BatchMode=yes -o StrictHostKeyChecking=yes' \
  "$ROOT/scripts/deploy_distribution_web.sh" >/dev/null
rg -F 'ssh -o BatchMode=yes -o StrictHostKeyChecking=yes' \
  "$ROOT/scripts/rollback_distribution_web.sh" >/dev/null
preview_preparer="$ROOT/scripts/prepare_distribution_web_preview_payload.sh"
sh -n "$preview_preparer"
rg -F 'preview candidate must contain exactly five audited files' \
  "$preview_preparer" >/dev/null
rg -F '.releaseStatus == "notarized-test-candidate"' \
  "$preview_preparer" >/dev/null
rg -F 'for file in "$DMG" "$MANIFEST" "$SOURCE_MANIFEST" "$README" "$SUMS"' \
  "$preview_preparer" >/dev/null
rg -F 'rollback_completed:1:' "$ROOT/scripts/deploy_distribution_web.sh" >/dev/null
rg -F 'completed:1:' "$ROOT/scripts/rollback_distribution_web.sh" >/dev/null
rg -F 'Swarm dropped the required read-only-container tmpfs mount' "$ROOT/scripts/deploy_distribution_web.sh" >/dev/null
rg -F 'Public web distribution verified:' "$ROOT/scripts/verify_distribution_web.sh" >/dev/null
rg -F 'public preview audit file differs from the release candidate' \
  "$ROOT/scripts/verify_distribution_web.sh" >/dev/null
rg -F '(cd "$audit" && shasum -a 256 -c SHA256SUMS)' \
  "$ROOT/scripts/verify_distribution_web.sh" >/dev/null
rg -F 'verify_audit_directory=$CANDIDATE_DIRECTORY' \
  "$ROOT/scripts/deploy_distribution_web.sh" >/dev/null
rg -F 'PREVIOUS' "$ROOT/scripts/rollback_distribution_web.sh" >/dev/null
rg -F 'access_log off;' "$WEB/nginx.conf" >/dev/null
rg -F 'server_tokens off;' "$WEB/nginx.conf" >/dev/null
rg -F 'try_files /current.update.json =404;' "$WEB/nginx.conf" >/dev/null
rg -F 'Cache-Control "no-store, max-age=0"' "$WEB/nginx.conf" >/dev/null
rg -F 'Content-Security-Policy' "$WEB/nginx.conf" >/dev/null
rg -F 'image/png "public, max-age=0, must-revalidate"' "$WEB/nginx.conf" >/dev/null
rg -F 'production manifest does not preserve the exact candidate manifest' \
  "$ROOT/scripts/prepare_distribution_web_payload.sh" >/dev/null
rg -F 'signed update envelope does not describe the exact stable release' \
  "$ROOT/scripts/prepare_distribution_web_payload.sh" >/dev/null
rg -F 'stable artifact was not produced from the current source manifest' \
  "$ROOT/scripts/prepare_distribution_web_payload.sh" >/dev/null

find "$PUBLIC" -name '*.html' -type f -print0 | while IFS= read -r -d '' html; do
  rg -F '<meta name="viewport"' "$html" >/dev/null || {
    echo "missing responsive viewport: $html" >&2
    exit 1
  }
  rg -F 'data-language-toggle' "$html" >/dev/null || {
    echo "missing language switch: $html" >&2
    exit 1
  }
  rg -F '/assets/site.css?v=20260807.07' "$html" >/dev/null || {
    echo "missing versioned stylesheet URL: $html" >&2
    exit 1
  }
  rg -F '/assets/site.js?v=20260807.07' "$html" >/dev/null || {
    echo "missing versioned script URL: $html" >&2
    exit 1
  }
done

for route in \
  /releases/ \
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

rg -F 'error_page 404 /404.html;' "$WEB/nginx.conf" >/dev/null
rg -F 'try_files $uri $uri/ =404;' "$WEB/nginx.conf" >/dev/null

expected_sha=4a18a47dfbd0886008753b9bbbbe9e4a36c5b1f7dc9f62951df59bea69299c20
count=$(rg -l "$expected_sha" "$PUBLIC" | wc -l | tr -d ' ')
test "$count" -eq 1 || {
  echo "preview checksum must appear exactly once in the public site" >&2
  exit 1
}

echo "Web distribution static guards passed"
"$ROOT/scripts/test_distribution_web_payload.sh"

