#!/bin/bash

set -euo pipefail

SOURCE="${1:-}"
OUTPUT="${2:-}"
REPOSITORY="${ECHO_RELEASE_REPOSITORY:-KeikaJames/Echo_Player}"

fail() {
    echo "site-release-sync: $*" >&2
    exit 1
}

[ -n "$SOURCE" ] && [ -f "$SOURCE" ] || fail "缺少 Release JSON"
[ -n "$OUTPUT" ] && [ -d "$(dirname "$OUTPUT")" ] || fail "输出目录不存在"
command -v jq >/dev/null 2>&1 || fail "缺少 jq"

RELEASE_PREFIX="https://github.com/$REPOSITORY/releases/"
jq -e --arg prefix "$RELEASE_PREFIX" '
    .draft == false and
    .prerelease == false and
    (.tag_name | type == "string" and test("^v[0-9]+([.][0-9]+){1,2}$")) and
    (.name == null or (.name | type == "string" and length <= 160)) and
    (.published_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
    (.html_url | type == "string" and startswith($prefix + "tag/")) and
    ((.body // "") | type == "string" and utf8bytelength <= 131072 and test("(^|\\n)SHA256: [0-9a-fA-F]{64}(\\n|$)")) and
    ((.assets // []) | type == "array") and
    any((.assets // [])[];
      ((.name | type) == "string") and
      (.name | ascii_downcase | endswith(".zip")) and
      ((.browser_download_url | type) == "string") and
      (.browser_download_url | startswith($prefix + "download/")) and
      ((.size | type) == "number" and .size > 0)
    )
' "$SOURCE" >/dev/null || fail "Release 数据不可信"

TEMP="$(mktemp "${OUTPUT}.XXXXXX")"
trap 'rm -f "$TEMP"' EXIT
jq -S --arg prefix "$RELEASE_PREFIX" '
    [(.assets // [])[]
      | select((.name | type) == "string")
      | select(.name | ascii_downcase | endswith(".zip"))
      | select((.browser_download_url | type) == "string")
      | select(.browser_download_url | startswith($prefix + "download/"))
      | select((.size | type) == "number" and .size > 0)
      | {name: .name, size: .size, url: .browser_download_url}
    ][0] as $asset
    | {
        asset: $asset,
        body: (.body // ""),
        name: (.name // .tag_name),
        published_at: .published_at,
        schema: 1,
        status: "published",
        tag_name: .tag_name,
        url: .html_url
      }
' "$SOURCE" > "$TEMP"
mv "$TEMP" "$OUTPUT"
trap - EXIT

echo "site-release-sync: 已生成 $OUTPUT"
