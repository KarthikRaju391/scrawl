#!/bin/bash
# robot/old-commit.sh <commit> [scenarios]: build an old commit with the robot hook added (the same
# app/Robot.swift, minus lines marked "robot:modern" that use newer features), and run the robot on it.
# Report: build/robot-<commit>/report.html.
set -e
cd "$(dirname "$0")/.."
C=$1; ONLY=$2
W=/tmp/scrawl-robot-$C
rm -rf "$W"; git worktree remove --force "$W" 2>/dev/null || true
git worktree add --detach "$W" "$C" >/dev/null
# Lines marked "robot:needs <text>" go when the old sources don't have <text> (a feature added later).
python3 - app/Robot.swift "$W" > "$W/app/Robot.swift" <<'PY'
import sys, re, glob
src, w = sys.argv[1], sys.argv[2]
old = "".join(open(f).read() for f in glob.glob(w + "/app/*.swift") if not f.endswith("/Robot.swift"))
for line in open(src).read().split("\n")[:-1] if open(src).read().endswith("\n") else open(src).read().split("\n"):
    m = re.search(r"// robot:needs (.+)$", line)
    if m and m.group(1).strip() not in old: continue
    print(line)
PY
python3 - "$W/app/main.swift" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p).read()
if "--test-robot" in s: sys.exit(0)   # this commit already has the hook
hook = '        #if !RELEASE\n        if let i = CommandLine.arguments.firstIndex(of: "--test-robot"), i + 1 < CommandLine.arguments.count { let r = Robot(app: self, dir: CommandLine.arguments[i + 1]); robot = r; r.start() }\n        #endif\n'
m = re.search(r"func startTestReplayIfAsked\(\) \{\n", s)
assert m, "no startTestReplayIfAsked"
s = s[:m.end()] + hook + s[m.end():]
s = s.replace("    func startTestReplayIfAsked() {", "    var robot: AnyObject?\n    func startTestReplayIfAsked() {", 1)
# The robot never locks the pointer or brings the app forward, whatever the old code did on entering draw mode.
s = s.replace("    func enterDrawMode(lock: Bool = true) {\n", "    func enterDrawMode(lock: Bool = true) {\n        let lock = lock && !CommandLine.arguments.contains(\"--test-robot\")\n", 1)
# Very old commits list their test flags: the robot is one (no real trackpad input, no saved tools).
s = s.replace('"--test-zoomlock"]', '"--test-zoomlock", "--test-robot"]')
open(p, "w").write(s)
c = p.replace("main.swift", "Canvas.swift"); t = open(c).read()
open(c, "w").write(t.replace('"--test-zoomlock"]', '"--test-zoomlock", "--test-robot"]'))
PY
# Old build scripts list the bench's excluded files; keep the robot out of the bench too.
sed -i '' 's/-e main.swift/-e main.swift -e Robot.swift/' "$W/build.sh"
(cd "$W" && ./build.sh > "$W/build.err" 2>&1) || { grep error "$W/build.err" | head -20; echo "BUILD FAILED"; exit 1; }
APP=$(ls -d "$W"/build/*.app | head -1)   # older builds were called "Trackpad Draw.app"
python3 robot/robot.py --app "$APP/Contents/MacOS/TrackpadDraw" --out "build/robot-$C" --label "$C" ${ONLY:+--only $ONLY} || true
git worktree remove --force "$W" >/dev/null 2>&1 || true
