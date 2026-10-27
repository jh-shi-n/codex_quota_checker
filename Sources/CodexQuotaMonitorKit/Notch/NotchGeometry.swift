import AppKit
import Foundation

fileprivate func finiteNonNegative(_ value: CGFloat) -> CGFloat {
    guard value.isFinite else { return 0 }
    return max(0, value)
}

fileprivate func sanitizedRect(_ rect: CGRect) -> CGRect {
    let x = rect.origin.x.isFinite ? rect.origin.x : 0
    let y = rect.origin.y.isFinite ? rect.origin.y : 0
    return CGRect(
        x: x,
        y: y,
        width: finiteNonNegative(rect.width),
        height: finiteNonNegative(rect.height)
    )
}

public enum NotchSide: String, Codable, Equatable, Sendable {
    case left
    case right
}

/// Pure candidate used to test screen-selection policy without constructing
/// AppKit screens. A production notch screen must expose both auxiliary areas.
public struct NotchScreenCandidate: Equatable, Sendable {
    public let identifier: String
    public let auxiliaryTopLeftArea: CGRect?
    public let auxiliaryTopRightArea: CGRect?

    public init(
        identifier: String,
        auxiliaryTopLeftArea: CGRect?,
        auxiliaryTopRightArea: CGRect?
    ) {
        self.identifier = identifier
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
    }

    public var hasNotchAuxiliaryAreas: Bool {
        NotchGeometry.hasNotchAuxiliaryAreas(
            left: auxiliaryTopLeftArea,
            right: auxiliaryTopRightArea
        )
    }
}

/// A value-only snapshot of the screen areas used for notch-adjacent layout.
public struct NotchLayout: Equatable, Sendable {
    public let screenFrame: CGRect
    public let leftArea: CGRect
    public let rightArea: CGRect
    public let leftAnchor: CGPoint
    public let rightAnchor: CGPoint

    public init(
        screenFrame: CGRect,
        leftArea: CGRect,
        rightArea: CGRect,
        leftAnchor: CGPoint,
        rightAnchor: CGPoint
    ) {
        self.screenFrame = screenFrame
        self.leftArea = leftArea
        self.rightArea = rightArea
        self.leftAnchor = leftAnchor
        self.rightAnchor = rightAnchor
    }

    /// Solid black connector between the two quota wings. On a notch display
    /// this is the exact auxiliary-area gap; on an external display it is the
    /// compact centered gap synthesized by `NotchGeometry.layout`.
    public var centerBridgeFrame: CGRect {
        let minX = leftArea.maxX
        let maxX = rightArea.minX
        let minY = max(leftArea.minY, rightArea.minY)
        let maxY = min(leftArea.maxY, rightArea.maxY)
        guard minX.isFinite, maxX.isFinite, minY.isFinite, maxY.isFinite,
              maxX > minX, maxY > minY else {
            return .zero
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Calculates the safe content frame inside the original auxiliary area.
    /// The notch bridge is deliberately excluded so rings and hover effects
    /// never move into the camera housing.
    public func contentFrame(
        side: NotchSide,
        itemCount: Int,
        style: NotchDisplayStyle = .ring,
        diameter: CGFloat = QuotaDonutMetrics.maximumDiameter,
        spacing: CGFloat = QuotaDonutMetrics.accountSpacing
    ) -> CGRect {
        guard itemCount > 0 else { return .zero }

        let safeSpacing = finiteNonNegative(spacing)
        let area = sanitizedRect(side == .left ? leftArea : rightArea)
        let safeDiameter = resolvedDiameter(
            side: side,
            itemCount: itemCount,
            style: style,
            diameter: diameter,
            spacing: safeSpacing
        )
        let visualFootprint = QuotaClusterMetrics.visualFootprint(
            itemCount: itemCount,
            style: style,
            diameter: safeDiameter,
            spacing: safeSpacing
        )
        guard safeDiameter > 0 else { return .zero }
        let width = min(visualFootprint.width, finiteNonNegative(area.width))
        let height = finiteNonNegative(area.height)
        guard height > 0 else { return .zero }
        let y = area.midY - height / 2

        let anchoredX: CGFloat
        switch side {
        case .left:
            let anchorX = leftAnchor.x.isFinite ? leftAnchor.x : area.maxX
            anchoredX = anchorX - width
        case .right:
            anchoredX = rightAnchor.x.isFinite ? rightAnchor.x : area.minX
        }

        let x = min(max(anchoredX, area.minX), area.maxX - width)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Calculates the full transparent panel frame. Its fixed bridge extends
    /// only toward the camera/notch and leaves the safe content frame intact.
    public func panelFrame(
        side: NotchSide,
        itemCount: Int,
        style: NotchDisplayStyle = .ring,
        diameter: CGFloat = QuotaDonutMetrics.maximumDiameter,
        spacing: CGFloat = QuotaDonutMetrics.accountSpacing,
        notchBridgeWidth: CGFloat = QuotaClusterMetrics.notchBridgeWidth,
        toastWidth: CGFloat = 0
    ) -> CGRect {
        let content = contentFrame(
            side: side,
            itemCount: itemCount,
            style: style,
            diameter: diameter,
            spacing: spacing
        )
        guard !content.isEmpty else { return .zero }
        let bridge = finiteNonNegative(notchBridgeWidth)
        let baseFrame: CGRect

        switch side {
        case .left:
            baseFrame = CGRect(
                x: content.minX,
                y: content.minY,
                width: content.width + bridge,
                height: content.height
            )
        case .right:
            baseFrame = CGRect(
                x: content.minX - bridge,
                y: content.minY,
                width: content.width + bridge,
                height: content.height
            )
        }

        let expansion = resolvedToastWidth(
            side: side,
            basePanel: baseFrame,
            requestedWidth: toastWidth
        )
        switch side {
        case .left:
            return CGRect(
                x: baseFrame.minX - expansion,
                y: baseFrame.minY,
                width: baseFrame.width + expansion,
                height: baseFrame.height
            )
        case .right:
            return CGRect(
                x: baseFrame.minX,
                y: baseFrame.minY,
                width: baseFrame.width + expansion,
                height: baseFrame.height
            )
        }
    }

    /// Returns the outward expansion that remains inside the corresponding
    /// auxiliary area. The bridge is intentionally included in `basePanel`,
    /// so the camera-nearest edge is never moved by toast presentation.
    public func resolvedToastWidth(
        side: NotchSide,
        itemCount: Int,
        style: NotchDisplayStyle = .ring,
        diameter: CGFloat = QuotaDonutMetrics.maximumDiameter,
        spacing: CGFloat = QuotaDonutMetrics.accountSpacing,
        notchBridgeWidth: CGFloat = QuotaClusterMetrics.notchBridgeWidth,
        requestedWidth: CGFloat
    ) -> CGFloat {
        let base = panelFrame(
            side: side,
            itemCount: itemCount,
            style: style,
            diameter: diameter,
            spacing: spacing,
            notchBridgeWidth: notchBridgeWidth,
            toastWidth: 0
        )
        return resolvedToastWidth(side: side, basePanel: base, requestedWidth: requestedWidth)
    }

    /// Reduces the item diameter when a screen's auxiliary area cannot fit all
    /// requested items. This keeps every item inside both panel and area.
    public func resolvedDiameter(
        side: NotchSide,
        itemCount: Int,
        style: NotchDisplayStyle = .ring,
        diameter: CGFloat = QuotaDonutMetrics.maximumDiameter,
        spacing: CGFloat = QuotaDonutMetrics.accountSpacing
    ) -> CGFloat {
        guard itemCount > 0 else { return 0 }
        let area = sanitizedRect(side == .left ? leftArea : rightArea)
        let safeSpacing = finiteNonNegative(spacing)
        let safeDiameter = finiteNonNegative(diameter)
        let upperBound = min(safeDiameter, min(finiteNonNegative(area.width), finiteNonNegative(area.height)))
        guard upperBound > 0 else { return 0 }

        func fits(_ candidate: CGFloat) -> Bool {
            guard candidate.isFinite, candidate > 0 else { return false }
            let visualFootprint = QuotaClusterMetrics.visualFootprint(
                itemCount: itemCount,
                style: style,
                diameter: candidate,
                spacing: safeSpacing
            )
            return visualFootprint.width <= area.width && visualFootprint.height <= area.height
        }

        guard !fits(upperBound) else { return upperBound }

        var lower = CGFloat.zero
        var upper = upperBound
        for _ in 0..<48 {
            let middle = (lower + upper) / 2
            if fits(middle) {
                lower = middle
            } else {
                upper = middle
            }
        }
        return lower
    }

    public func itemFrames(
        side: NotchSide,
        itemCount: Int,
        style: NotchDisplayStyle = .ring,
        diameter: CGFloat = QuotaDonutMetrics.maximumDiameter,
        spacing: CGFloat = QuotaDonutMetrics.accountSpacing,
        notchBridgeWidth: CGFloat = QuotaClusterMetrics.notchBridgeWidth,
        toastWidth: CGFloat = 0
    ) -> [CGRect] {
        guard itemCount > 0 else { return [] }

        let content = contentFrame(side: side, itemCount: itemCount, style: style, diameter: diameter, spacing: spacing)
        let safeDiameter = min(
            resolvedDiameter(side: side, itemCount: itemCount, style: style, diameter: diameter, spacing: spacing),
            content.height
        )
        guard safeDiameter > 0 else { return [] }
        _ = notchBridgeWidth
        _ = toastWidth
        let inset = QuotaClusterMetrics.visualInset(forDiameter: safeDiameter, style: style)
        let contentInset = inset + QuotaClusterMetrics.containmentMargin
        let itemWidth = safeDiameter
        let offset = itemWidth + finiteNonNegative(spacing)
        return (0..<itemCount).map { index in
            let x = content.minX + contentInset + CGFloat(index) * offset
            return CGRect(x: x, y: content.midY - safeDiameter / 2, width: itemWidth, height: safeDiameter)
        }
    }

    private func resolvedToastWidth(
        side: NotchSide,
        basePanel: CGRect,
        requestedWidth: CGFloat
    ) -> CGFloat {
        guard !basePanel.isEmpty else { return 0 }
        let area = sanitizedRect(side == .left ? leftArea : rightArea)
        let requested = finiteNonNegative(requestedWidth)
        let available: CGFloat
        switch side {
        case .left:
            available = finiteNonNegative(basePanel.minX - area.minX)
        case .right:
            available = finiteNonNegative(area.maxX - basePanel.maxX)
        }
        return min(requested, available)
    }
}

/// Pure geometry plus the AppKit bridge for current `NSScreen` auxiliary areas.
public enum NotchGeometry {
    public static func hasNotchAuxiliaryAreas(left: CGRect?, right: CGRect?) -> Bool {
        guard let left, let right else { return false }
        let safeLeft = sanitizedRect(left)
        let safeRight = sanitizedRect(right)
        return safeLeft.width > 0 && safeLeft.height > 0 && safeRight.width > 0 && safeRight.height > 0
    }

    /// Selects the first candidate with both non-empty auxiliary areas. A nil
    /// result is an explicit "hide panels" state for the production manager.
    public static func selectScreen(from candidates: [NotchScreenCandidate]) -> NotchScreenCandidate? {
        candidates.first(where: { $0.hasNotchAuxiliaryAreas })
    }

    public static func layout(
        screenFrame: CGRect,
        auxiliaryTopLeftArea: CGRect?,
        auxiliaryTopRightArea: CGRect?,
        menuBarHeight: CGFloat = 24
    ) -> NotchLayout {
        let safeScreen = sanitizedRect(screenFrame)
        let safeLeftArea = auxiliaryTopLeftArea.map(sanitizedRect)
        let safeRightArea = auxiliaryTopRightArea.map(sanitizedRect)
        let safeMenuBarHeight = finiteNonNegative(menuBarHeight)
        let inferredHeight = max(
            1,
            max(
                safeLeftArea?.height ?? 0,
                max(safeRightArea?.height ?? 0, safeMenuBarHeight)
            )
        )
        let topY = safeScreen.maxY - inferredHeight
        let centerX = safeScreen.midX

        // On a display without a notch the auxiliary areas may be nil. The
        // fallback is derived from the current screen bounds, never a notch
        // pixel constant.
        let fallbackBridgeWidth = min(
            finiteNonNegative(safeScreen.width),
            min(160, max(72, inferredHeight * 4))
        )
        let fallbackLeftMaxX = centerX - fallbackBridgeWidth / 2
        let fallbackRightMinX = centerX + fallbackBridgeWidth / 2
        let leftArea = safeLeftArea ?? CGRect(
            x: safeScreen.minX,
            y: topY,
            width: finiteNonNegative(fallbackLeftMaxX - safeScreen.minX),
            height: inferredHeight
        )
        let rightArea = safeRightArea ?? CGRect(
            x: fallbackRightMinX,
            y: topY,
            width: finiteNonNegative(safeScreen.maxX - fallbackRightMinX),
            height: inferredHeight
        )

        return NotchLayout(
            screenFrame: safeScreen,
            leftArea: leftArea,
            rightArea: rightArea,
            leftAnchor: CGPoint(x: leftArea.maxX, y: leftArea.midY),
            rightAnchor: CGPoint(x: rightArea.minX, y: rightArea.midY)
        )
    }

    @available(macOS 14.0, *)
    public static func layout(for screen: NSScreen, menuBarHeight: CGFloat? = nil) -> NotchLayout {
        let inferredMenuBarHeight = menuBarHeight ?? max(1, screen.frame.maxY - screen.visibleFrame.maxY)
        return layout(
            screenFrame: screen.frame,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea,
            menuBarHeight: inferredMenuBarHeight
        )
    }

    @available(macOS 14.0, *)
    public static func isNotchScreen(_ screen: NSScreen) -> Bool {
        hasNotchAuxiliaryAreas(
            left: screen.auxiliaryTopLeftArea,
            right: screen.auxiliaryTopRightArea
        )
    }

    /// Resolves the display configured as primary in macOS. Unlike
    /// `NSScreen.main`, `CGMainDisplayID()` does not follow the active window,
    /// so repeated relayouts stay on the user's configured main display.
    @available(macOS 14.0, *)
    public static func primaryScreen(from screens: [NSScreen]) -> NSScreen? {
        let displayIDs = screens.map { screen -> UInt32? in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
        }
        guard let index = primaryScreenIndex(
            displayIDs: displayIDs,
            mainDisplayID: CGMainDisplayID()
        ) else {
            return nil
        }
        return screens[index]
    }

    /// Pure selection seam used to verify multi-display ordering without
    /// constructing AppKit-owned `NSScreen` instances in tests.
    public static func primaryScreenIndex(
        displayIDs: [UInt32?],
        mainDisplayID: UInt32
    ) -> Int? {
        guard !displayIDs.isEmpty else { return nil }
        return displayIDs.firstIndex(where: { $0 == mainDisplayID }) ?? 0
    }
}
