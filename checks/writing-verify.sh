#!/bin/bash
# Formal checks of writing mode (docs/writing-spec.md): bounded model checking, fuzzing of the real CanvasView, and
# replay of the recorded sessions.
#   checks/writing-verify.sh [--explore 5] [--fuzz 300] [--replay data] [--waits 200,400,1000]
# With no arguments: --explore 4 --fuzz 200 --waits 200,400,1000. SRC=<dir> builds from another source tree (mutants).
cd "$(dirname "$0")/.."
SRC=${SRC:-.}
OUT=${OUT:-build/writing-verify}
mkdir -p "$(dirname "$OUT")"
FILES=$(ls "$SRC"/app/*.swift | grep -v -e /main.swift -e TestZoomLock.swift -e TestPersist.swift -e TestInput.swift -e TestAbout.swift -e TestMapping.swift -e TestEdge.swift -e TestKeys.swift -e TestNewLine.swift -e TestPage.swift -e TestGallery.swift -e TestArrows.swift -e TestMeta.swift -e TestGallerySpeed.swift -e TestToolDraw.swift -e TestTaps.swift -e TestArrowKeys.swift -e TestToast.swift -e TestJitter.swift -e TestGalleryKeys.swift -e TestGalleryFlow.swift -e TestGalleryReplay.swift -e TestGalleryOrder.swift -e TestAccessibility.swift -e TestMenus.swift -e TestModes.swift -e Robot.swift -e TestPan.swift -e UsageEvents.swift -e AppMenu.swift -e AppGallery.swift)
swiftc -O -swift-version 5 -j ${JOBS:-4} -o "$OUT" $FILES "$SRC"/bench/writingModel.swift "$SRC"/bench/writingVerify.swift "$SRC"/tools/writing-verify/main.swift \
  -framework AppKit -framework Metal -framework MetalKit -framework QuartzCore -framework Carbon -framework PDFKit || exit 2
[ -n "$BUILD_ONLY" ] && exit 0
[ $# -eq 0 ] && set -- --explore 4 --fuzz 200
exec "$OUT" --test-writing-verify "$@"
