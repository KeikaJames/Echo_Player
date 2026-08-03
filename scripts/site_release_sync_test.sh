#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

jq -n '{
    draft: false,
    prerelease: false,
    tag_name: "v1.2",
    name: "Echo Player v1.2",
    published_at: "2026-08-04T01:02:03Z",
    html_url: "https://github.com/KeikaJames/Echo_Player/releases/tag/v1.2",
    body: "SHA256: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n\n# 新版本\n\n- 播放：更稳定\n<script>alert(1)</script>",
    assets: [{
      name: "Echo.Player.v1.2.zip",
      size: 1048576,
      browser_download_url: "https://github.com/KeikaJames/Echo_Player/releases/download/v1.2/Echo.Player.v1.2.zip"
    }]
  }' > "$WORK/release.json"

"$ROOT/scripts/sync_site_release.sh" "$WORK/release.json" "$WORK/site.json"
jq -e '
    .schema == 1 and
    .status == "published" and
    .tag_name == "v1.2" and
    .asset.size == 1048576 and
    (.body | contains("<script>"))
' "$WORK/site.json" >/dev/null

jq '.draft = true' "$WORK/release.json" > "$WORK/draft.json"
if "$ROOT/scripts/sync_site_release.sh" "$WORK/draft.json" "$WORK/rejected.json" 2>/dev/null; then
    echo "site-release-sync-test: 接受了 Draft" >&2
    exit 1
fi

jq '.html_url = "https://example.com/releases/tag/v1.2"' "$WORK/release.json" > "$WORK/foreign.json"
if "$ROOT/scripts/sync_site_release.sh" "$WORK/foreign.json" "$WORK/rejected.json" 2>/dev/null; then
    echo "site-release-sync-test: 接受了外部地址" >&2
    exit 1
fi

for tag in 'v1.2+build.1' 'v1.2;touch-pwn' 'v1.2$(touch-pwn)' 'v1.2/foo'; do
    jq --arg tag "$tag" '.tag_name = $tag' "$WORK/release.json" > "$WORK/injected.json"
    if "$ROOT/scripts/sync_site_release.sh" "$WORK/injected.json" "$WORK/rejected.json" 2>/dev/null; then
        echo "site-release-sync-test: 接受了非法 tag: $tag" >&2
        exit 1
    fi
done

jq '.assets = []' "$WORK/release.json" > "$WORK/no-asset.json"
if "$ROOT/scripts/sync_site_release.sh" "$WORK/no-asset.json" "$WORK/rejected.json" 2>/dev/null; then
    echo "site-release-sync-test: 接受了无下载资产的 Release" >&2
    exit 1
fi

jq '.body = "没有校验值"' "$WORK/release.json" > "$WORK/no-hash.json"
if "$ROOT/scripts/sync_site_release.sh" "$WORK/no-hash.json" "$WORK/rejected.json" 2>/dev/null; then
    echo "site-release-sync-test: 接受了无校验值的 Release" >&2
    exit 1
fi

echo "site-release-sync-test: 通过"
