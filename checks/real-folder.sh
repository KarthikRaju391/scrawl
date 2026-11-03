#!/bin/bash
# Nothing but the app he runs may write Karthik's notebook folder (3 Nov: a bench run wrote a test canvas over it).
# Fingerprints ~/Library/Application Support/Scrawl (every file's size, date and checksum), runs the bench, the
# writing-mode checks and a test-mode app run, and fails if anything there changed.
#   checks/real-folder.sh               the real folder
#   checks/real-folder.sh --self-test   a temp folder standing in for it, written to mid-run: must FAIL
cd "$(dirname "$0")/.."
DIR="$HOME/Library/Application Support/Scrawl"; SELF=""
if [ "$1" = "--self-test" ]; then SELF=1; DIR=$(mktemp -d /tmp/scrawl-realfolder.XXXX); echo notebook > "$DIR/Notebook.tdnb"; fi
print() { [ -d "$DIR" ] && (cd "$DIR" && find . -type f -exec stat -f "%N %z %m" {} \; -exec shasum {} \; | sort) || echo "(no folder)"; }
before=$(print)
./build/bench > /tmp/scrawl-realfolder-bench.log 2>&1; b=$?
checks/writing-verify.sh > /tmp/scrawl-realfolder-wv.log 2>&1; w=$?
checks/newline.sh > /tmp/scrawl-realfolder-nl.log 2>&1
[ -n "$SELF" ] && echo "a stray write" >> "$DIR/Notebook.tdnb"
after=$(print)
echo "bench exit $b, writing-verify exit $w (logs in /tmp/scrawl-realfolder-*.log)"
if [ "$before" = "$after" ]; then echo "PASS nothing in $DIR changed during the bench, writing-verify and a test-mode app run"; echo "RESULT: PASS"
else echo "FAIL $DIR changed:"; diff <(echo "$before") <(echo "$after") | head -10; echo "RESULT: FAIL (1)"; fi
[ -n "$SELF" ] && rm -rf "$DIR"
