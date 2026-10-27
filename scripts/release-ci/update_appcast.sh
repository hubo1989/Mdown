#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  update_appcast.sh \
    --appcast appcast.xml \
    --version 2.8.0 \
    --pub-date "Wed, 04 Mar 2026 10:00:00 +0000" \
    --signature "<sparkle signature>" \
    --length 12345 \
    --zip-url "https://github.com/hubo1989/Mdown/releases/download/V2.8.0/Mdown_V2.8.0.zip"
EOF
}

APPCAST=""
NOTES=""
DESCRIPTION_HTML_FILE=""
VERSION=""
PUB_DATE=""
SIGNATURE=""
LENGTH=""
ZIP_URL=""
MIN_SYSTEM_VERSION="11.5"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --appcast)
      APPCAST="$2"
      shift 2
      ;;
    --notes)
      NOTES="$2"
      shift 2
      ;;
    --description-html-file)
      DESCRIPTION_HTML_FILE="$2"
      shift 2
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    --pub-date)
      PUB_DATE="$2"
      shift 2
      ;;
    --signature)
      SIGNATURE="$2"
      shift 2
      ;;
    --length)
      LENGTH="$2"
      shift 2
      ;;
    --zip-url)
      ZIP_URL="$2"
      shift 2
      ;;
    --minimum-system-version)
      MIN_SYSTEM_VERSION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

[[ -z "$APPCAST" || -z "$VERSION" || -z "$PUB_DATE" || -z "$SIGNATURE" || -z "$LENGTH" || -z "$ZIP_URL" ]] && {
  usage
  exit 1
}

sanitize_cdata() {
  printf '%s' "$1" | sed 's/]]>/]]]]><![CDATA[>/g'
}

description_body=""
if [[ -n "$DESCRIPTION_HTML_FILE" && -f "$DESCRIPTION_HTML_FILE" ]]; then
  description_body="$(cat "$DESCRIPTION_HTML_FILE")"
else
  description_body="$(printf '      <p>Mdown 更新，请查看 GitHub Releases 中的更新说明。</p>\n      <p>See GitHub Releases for the Mdown changelog.</p>\n      <p><a href="https://github.com/hubo1989/Mdown/releases">GitHub Releases</a></p>')"
fi

item_file="$(mktemp)"
{
  echo "    <item>"
  echo "      <title>${VERSION}</title>"
  echo "      <link>https://github.com/hubo1989/Mdown/releases</link>"
  echo "      <description><![CDATA["
  printf '%s\n' "$description_body"
  echo "          ]]>      </description>"
  echo "      <pubDate>${PUB_DATE}</pubDate>"
  echo "      <enclosure url=\"${ZIP_URL}\" sparkle:shortVersionString=\"${VERSION}\" sparkle:version=\"${VERSION}\" sparkle:edSignature=\"${SIGNATURE}\" length=\"${LENGTH}\" type=\"application/octet-stream\"/>"
  echo "      <sparkle:minimumSystemVersion>${MIN_SYSTEM_VERSION}</sparkle:minimumSystemVersion>"
  echo "    </item>"
} >"$item_file"

perl -0777 -i -pe "s@\\s*<item>\\s*<title>\\Q${VERSION}\\E</title>.*?</item>@@sg" "$APPCAST"

ITEM_CONTENT="$(cat "$item_file")"
export ITEM_CONTENT
perl -0777 -i -pe '
  BEGIN { $item = $ENV{"ITEM_CONTENT"}; }
  if (!s{(<channel>\s*<title>.*?</title>\n)(\s*)(<item>)}{$1 . $item . "\n" . $2 . $3}se) {
    if (!s{(\s*</channel>)}{$item . "\n" . $1}se) {
      die "Failed to locate appcast insertion point\n";
    }
  }
' "$APPCAST"

rm -f "$item_file"
