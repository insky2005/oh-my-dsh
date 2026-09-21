import Foundation

// Headless tests for the image preview zoom math (ImageZoom.swift), the model
// behind the Files panel image preview (adaptive fit + manual zoom).
// Usage: tests/file-panel/run.sh

func test(_ name: String, _ cond: Bool) {
    print((cond ? "ok" : "FAIL") + " - " + name)
    if !cond { exit(1) }
}

let big = NSSize(width: 4000, height: 2000)
let viewport = NSSize(width: 1000, height: 1000)

// --- adaptive fit ----------------------------------------------------------

// A wide image is limited by the width; the ratio must stay exact (no distortion).
test("a wide image fits by width",
     ImageZoom.fitMagnification(imageSize: big, viewport: viewport) == 0.25)
test("a tall image fits by height",
     ImageZoom.fitMagnification(imageSize: NSSize(width: 500, height: 4000), viewport: viewport) == 0.25)
test("a square image fits the shorter side",
     ImageZoom.fitMagnification(imageSize: NSSize(width: 800, height: 800), viewport: viewport) == 1)

// Small images are NOT blown up: fit makes big files readable, it must not blur
// a 32 px icon.
test("a tiny image is not enlarged",
     ImageZoom.fitMagnification(imageSize: NSSize(width: 32, height: 32), viewport: viewport) == 1)
test("an image exactly the viewport size stays at 100 %",
     ImageZoom.fitMagnification(imageSize: viewport, viewport: viewport) == 1)

// Degenerate inputs must not produce a zero/NaN magnification (an image opened
// before the panel has a size would otherwise disappear).
let empty = NSSize(width: 0, height: 0)
test("a zero viewport falls back to 100 %",
     ImageZoom.fitMagnification(imageSize: big, viewport: empty) == 1)
test("a zero image falls back to 100 %",
     ImageZoom.fitMagnification(imageSize: empty, viewport: viewport) == 1)

// --- manual zoom -----------------------------------------------------------

test("clamping keeps the lower bound", ImageZoom.clamped(0) == ImageZoom.minMagnification)
test("clamping keeps the upper bound", ImageZoom.clamped(9999) == ImageZoom.maxMagnification)
test("clamping ignores NaN", ImageZoom.clamped(.nan) == ImageZoom.minMagnification)

let zoomedIn = ImageZoom.stepped(1, direction: 1)
test("a zoom step in multiplies by the ratio", zoomedIn == ImageZoom.stepRatio)
test("a zoom step out divides by the ratio", ImageZoom.stepped(zoomedIn, direction: -1) == 1)
test("stepping out at the limit stays at the limit",
     ImageZoom.stepped(ImageZoom.minMagnification, direction: -1) == ImageZoom.minMagnification)
test("stepping in at the limit stays at the limit",
     ImageZoom.stepped(ImageZoom.maxMagnification, direction: 1) == ImageZoom.maxMagnification)
test("a zero step keeps the zoom", ImageZoom.stepped(2, direction: 0) == 2)

// Repeated stepping must stay monotonic and bounded (no oscillation at the ends).
var zoom: CGFloat = 1
var increasing = true
var previous = zoom
for _ in 0..<40 {
    zoom = ImageZoom.stepped(zoom, direction: 1)
    if zoom < previous { increasing = false }
    previous = zoom
}
test("forty steps in stays monotonic and bounded", increasing && zoom <= ImageZoom.maxMagnification)
test("forty steps in reaches the maximum", zoom == ImageZoom.maxMagnification)

print("done")
