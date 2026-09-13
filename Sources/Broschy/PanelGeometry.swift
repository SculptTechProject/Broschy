import Foundation

enum PanelGeometry {
    static let previewHeightGrowth: CGFloat = 4
    static let animationPadding: CGFloat = 4

    static func compactHeight(safeAreaTop: CGFloat, menuBarHeight: CGFloat) -> CGFloat {
        safeAreaTop > 0 ? safeAreaTop : menuBarHeight
    }

    static func compactWidth(notchWidth: CGFloat, panelWidth: CGFloat, wide: Bool) -> CGFloat {
        max(0, min(panelWidth - 12, notchWidth + (wide ? 248 : 128)))
    }

    static func previewWidth(compactWidth: CGFloat, panelWidth: CGFloat) -> CGFloat {
        max(0, min(panelWidth, compactWidth + 12))
    }

    /// Preserve the screen's top edge while keeping the window horizontally visible.
    static func frame(centerX: CGFloat, screenFrame: CGRect, width: CGFloat, height: CGFloat) -> CGRect {
        let visibleWidth = max(0, min(width, screenFrame.size.width))
        let visibleHeight = max(0, height)
        let left = screenFrame.origin.x
        let right = left + screenFrame.size.width
        let top = screenFrame.origin.y + screenFrame.size.height
        let x = min(max(centerX - visibleWidth / 2, left), right - visibleWidth)
        return CGRect(origin: CGPoint(x: x, y: top - visibleHeight),
                      size: CGSize(width: visibleWidth, height: visibleHeight))
    }
}
