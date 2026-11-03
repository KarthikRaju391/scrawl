#!/bin/bash
# Only the installed app is Scrawl to macOS: Spotlight, Open With and `open -b` must never find a dev build, a test copy
# or a mounted DMG. Lists every bundle LaunchServices knows with Scrawl's ids (release and dev) and fails unless the
# only one is /Applications/Scrawl.app. Builds unregister their output (build.sh); release installs register
# /Applications/Scrawl.app (scripts/install-applications.sh).
LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
. "$(dirname "$0")/../release.conf"
found=$($LS -dump 2>/dev/null | awk '/^path:/{sub(/^path: */,""); sub(/ \(0x[0-9a-f]+\)$/,""); p=$0} /^identifier:/{print $2"\t"p}' | grep -E "^($BUNDLE_ID|local\.trackpad-draw)	" | sort -u)
others=$(echo "$found" | grep -v "	/Applications/Scrawl.app$" | grep -v '^$')
echo "$found" | sed 's/^/  registered: /'
if [ -z "$others" ] && echo "$found" | grep -q "	/Applications/Scrawl.app$"; then echo "PASS only /Applications/Scrawl.app is registered as Scrawl"; echo "RESULT: PASS"
else echo "FAIL other Scrawl bundles are registered (or /Applications/Scrawl.app isn't):"; echo "$others" | sed 's/^/    /'; echo "RESULT: FAIL (1)"; fi
