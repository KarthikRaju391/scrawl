#!/bin/bash
# A published release, as a stranger downloads it: checks/release-assets.sh v0.1.5.1
# Fetches every asset anonymously (no token) and runs shasum -c on SHA256SUMS.txt: every line must match a
# downloaded file, and the DMG must be listed.
TAG=${1:?usage: checks/release-assets.sh <tag>}
D=$(mktemp -d /tmp/scrawl-assets.XXXX); cd "$D" || exit 1
urls=$(env -u GH_TOKEN -u GITHUB_TOKEN curl -s --max-time 30 "https://api.github.com/repos/KarthikRaju391/scrawl/releases/tags/$TAG" | python3 -c 'import json,sys; [print(a["browser_download_url"]) for a in json.load(sys.stdin).get("assets", [])]')
[ -z "$urls" ] && { echo "FAIL no assets found for $TAG"; echo "RESULT: FAIL (1)"; exit 1; }
for u in $urls; do env -u GH_TOKEN -u GITHUB_TOKEN curl -sfL --max-time 60 --retry 2 -o "$(basename "$u")" "$u" || echo "FAIL couldn't download $u"; done
echo "assets: $(ls | tr '\n' ' ')"
if [ -f SHA256SUMS.txt ] && shasum -a 256 -c SHA256SUMS.txt && grep -q '\.dmg$' SHA256SUMS.txt; then echo "PASS every file in SHA256SUMS.txt downloaded and matched ($TAG)"; echo "RESULT: PASS"
else echo "FAIL SHA256SUMS.txt doesn't check out against the downloaded assets ($TAG)"; echo "RESULT: FAIL (1)"; fi
rm -rf "$D"
