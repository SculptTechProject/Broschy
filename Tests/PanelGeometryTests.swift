import Foundation

@main
struct PanelGeometryTests {
    static func main() {
        let builtIn = rect(x: 0, y: 0, width: 1512, height: 982)
        let menuCases: [(safeArea: CGFloat, menuBar: CGFloat, expected: CGFloat)] = [
            (38, 22, 38), (0, 22, 22), (0, 24, 24), (-1, 24, 24)
        ]
        for value in menuCases {
            let height = PanelGeometry.compactHeight(safeAreaTop: value.safeArea, menuBarHeight: value.menuBar)
            precondition(height == value.expected, "Compact height must match the menu band without extra pixels")
            let resting = PanelGeometry.frame(centerX: 756, screenFrame: builtIn, width: 316, height: height)
            precondition(resting.origin.y == 982 - value.expected && resting.size.height == value.expected,
                         "The resting panel must fit entirely inside the menu bar without extra pixels")
            precondition(resting.origin.y + resting.size.height == 982,
                         "The resting panel must touch the screen's top edge")
        }

        let normal = PanelGeometry.compactWidth(notchWidth: 188, panelWidth: 480, wide: false)
        let wide = PanelGeometry.compactWidth(notchWidth: 188, panelWidth: 480, wide: true)
        precondition(normal == 316 && wide == 436, "Both compact layouts must retain the requested wing widths")
        precondition(PanelGeometry.previewWidth(compactWidth: normal, panelWidth: 480) == 328)
        precondition(PanelGeometry.previewWidth(compactWidth: wide, panelWidth: 480) == 448)

        let capped = PanelGeometry.compactWidth(notchWidth: 250, panelWidth: 480, wide: true)
        precondition(capped == 468, "A wide resting panel must leave room for the hover preview")
        precondition(PanelGeometry.previewWidth(compactWidth: capped, panelWidth: 480) == 480,
                     "The preview may reach, but must not exceed, the expanded panel width")
        precondition(PanelGeometry.compactWidth(notchWidth: 188, panelWidth: 300, wide: false) == 288)
        precondition(PanelGeometry.compactWidth(notchWidth: 188, panelWidth: 10, wide: true) == 0)
        precondition(PanelGeometry.compactWidth(notchWidth: 188, panelWidth: 0, wide: false) == 0)
        precondition(PanelGeometry.previewWidth(compactWidth: 0, panelWidth: 10) == 10)

        let resting = PanelGeometry.frame(centerX: 756, screenFrame: builtIn, width: normal, height: 38)
        let preview = PanelGeometry.frame(centerX: 756, screenFrame: builtIn,
            width: PanelGeometry.previewWidth(compactWidth: normal, panelWidth: 480),
            height: 38 + PanelGeometry.previewHeightGrowth)
        assertFrame(resting, x: 598, y: 944, width: 316, height: 38)
        assertFrame(preview, x: 592, y: 940, width: 328, height: 42)
        precondition(preview.origin.y + preview.size.height == resting.origin.y + resting.size.height,
                     "Hover growth must not move the top anchor")

        let screens = [builtIn,
            rect(x: 1512, y: -200, width: 1920, height: 1080),
            rect(x: -1920, y: -200, width: 1920, height: 1080),
            rect(x: -400, y: 982, width: 1920, height: 1080)]
        for screen in screens {
            let left = screen.origin.x
            let right = left + screen.size.width
            let centerX = left + screen.size.width / 2
            let top = screen.origin.y + screen.size.height
            for center in [left - 1000, left, centerX, right, right + 1000] {
                let frame = PanelGeometry.frame(centerX: center, screenFrame: screen, width: 480, height: 388)
                precondition(frame.origin.x >= left && frame.origin.x + frame.size.width <= right,
                             "The panel must remain on its chosen display, including negative origins")
                precondition(frame.origin.y + frame.size.height == top && frame.size.height == 388,
                             "Display origins must not change the top anchor or requested height")
            }
            let oversized = PanelGeometry.frame(centerX: centerX, screenFrame: screen, width: screen.size.width + 500, height: 22)
            precondition(oversized.origin.x == left && oversized.size.width == screen.size.width,
                         "An oversized frame must fit the display instead of extending past both edges")
        }
        assertFrame(PanelGeometry.frame(centerX: 2472, screenFrame: screens[1], width: 480, height: 388),
                    x: 2232, y: 492, width: 480, height: 388)
        assertFrame(PanelGeometry.frame(centerX: -960, screenFrame: screens[2], width: 480, height: 388),
                    x: -1200, y: 492, width: 480, height: 388)
        assertFrame(PanelGeometry.frame(centerX: 560, screenFrame: screens[3], width: 480, height: 388),
                    x: 320, y: 1674, width: 480, height: 388)

        let surface = PanelGeometry.frame(centerX: 756, screenFrame: builtIn, width: 480, height: 388)
        let canvas = PanelGeometry.frame(centerX: 756, screenFrame: builtIn,
            width: 480 + PanelGeometry.animationPadding * 2,
            height: 388 + PanelGeometry.animationPadding)
        assertFrame(surface, x: 516, y: 594, width: 480, height: 388)
        assertFrame(canvas, x: 512, y: 590, width: 488, height: 392)
        precondition(canvas.origin.y + canvas.size.height == surface.origin.y + surface.size.height,
                     "Animation clearance belongs below the top-anchored surface")

        print("Panel geometry checks passed")
    }

    private static func rect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(origin: CGPoint(x: x, y: y), size: CGSize(width: width, height: height))
    }

    private static func assertFrame(_ frame: CGRect, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        precondition(frame.origin.x == x && frame.origin.y == y && frame.size.width == width && frame.size.height == height,
                     "Unexpected panel geometry")
    }
}
