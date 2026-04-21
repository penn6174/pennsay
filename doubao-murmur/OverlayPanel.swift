import AppKit
import QuartzCore

struct OverlaySnapshot: Codable {
    var frame: CGRect
    var cornerRadius: CGFloat
    var labelText: String
    var stage: String
    var waveformHeights: [CGFloat]
    var screenFrame: CGRect
    var visibleFrame: CGRect
    var windowNumber: Int
    var isVisible: Bool
}

enum OverlayStage: String {
    case hidden
    case listening
    case refining
    case error
}

final class OverlayPanel: NSPanel {
    private enum Metrics {
        static let height: CGFloat = 56
        static let minWidth: CGFloat = 160
        static var maxWidth: CGFloat {
            let screenWidth = NSScreen.main?.visibleFrame.width ?? 1600
            return screenWidth * 0.7
        }
        static let bottomInset: CGFloat = 80
        static let cornerRadius: CGFloat = 28
        static let leadingInset: CGFloat = 16
        static let trailingInset: CGFloat = 20
        static let indicatorWidth: CGFloat = 44
        static let indicatorHeight: CGFloat = 32
        static let interItemSpacing: CGFloat = 12
    }

    private let visualEffectView = NSVisualEffectView()
    private let waveformView = WaveformBarsView()
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private let rootView = NSView()
    private let appState: AppState

    private(set) var stage: OverlayStage = .hidden
    private(set) var waveformHeights: [CGFloat] = Array(repeating: 0.12, count: 5)

    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(appState: AppState) {
        self.appState = appState

        let frame = OverlayPanel.defaultFrame(width: Metrics.minWidth)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        animationBehavior = .none

        setupContent()
        orderOut(nil)
    }

    func showListening(text: String = AppEnvironment.listeningPlaceholder) {
        stage = .listening
        spinner.isHidden = true
        waveformView.isHidden = false
        updateText(text)
        showIfNeeded()
    }

    func showRefining(text: String = AppEnvironment.refiningPlaceholder) {
        stage = .refining
        spinner.isHidden = false
        spinner.startAnimation(nil)
        waveformView.isHidden = true
        updateText(text)
        showIfNeeded()
    }

    func showError(text: String) {
        stage = .error
        spinner.isHidden = true
        waveformView.isHidden = true
        label.textColor = .systemRed
        updateText(text)
        showIfNeeded()
    }

    func updateText(_ text: String) {
        appState.currentText = text
        label.textColor = stage == .error ? .systemRed : .labelColor
        label.stringValue = text
        animateToWidth(desiredWidth(for: text))
        AutomationController.writeState(appState: appState, overlay: currentSnapshot())
    }

    func updateWaveform(levels: [CGFloat]) {
        waveformHeights = levels
        waveformView.update(levels: levels)
        AutomationController.writeState(appState: appState, overlay: currentSnapshot())
    }

    func hideOverlay(animated: Bool = true) {
        stage = .hidden
        spinner.stopAnimation(nil)
        appState.currentText = ""
        waveformView.reset()
        waveformHeights = Array(repeating: 0.12, count: 5)

        guard animated, isVisible else {
            alphaValue = 0
            orderOut(nil)
            AutomationController.writeState(appState: appState, overlay: currentSnapshot())
            return
        }

        if let layer = rootView.layer {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1
            scale.toValue = 0.94
            scale.duration = 0.22
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(scale, forKey: "scaleOut")
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.orderOut(nil)
            guard let self else { return }
            DispatchQueue.main.async {
                AutomationController.writeState(appState: self.appState, overlay: self.currentSnapshot())
            }
        }
    }

    func currentSnapshot() -> OverlaySnapshot {
        OverlaySnapshot(
            frame: frame,
            cornerRadius: visualEffectView.layer?.cornerRadius ?? Metrics.cornerRadius,
            labelText: label.stringValue,
            stage: stage.rawValue,
            waveformHeights: waveformHeights,
            screenFrame: screen?.frame ?? .zero,
            visibleFrame: screen?.visibleFrame ?? .zero,
            windowNumber: windowNumber,
            isVisible: isVisible
        )
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    private func setupContent() {
        contentView = rootView
        rootView.wantsLayer = true
        rootView.layer?.masksToBounds = false
        rootView.layer?.shadowColor = NSColor.black.cgColor
        rootView.layer?.shadowOpacity = 0.3
        rootView.layer?.shadowRadius = 20
        rootView.layer?.shadowOffset = CGSize(width: 0, height: 4)

        visualEffectView.frame = rootView.bounds
        visualEffectView.autoresizingMask = [.width, .height]
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = Metrics.cornerRadius
        visualEffectView.layer?.masksToBounds = true
        rootView.addSubview(visualEffectView)

        waveformView.frame = NSRect(
            x: Metrics.leadingInset,
            y: (Metrics.height - Metrics.indicatorHeight) / 2,
            width: Metrics.indicatorWidth,
            height: Metrics.indicatorHeight
        )
        visualEffectView.addSubview(waveformView)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.frame = waveformView.frame
        spinner.isHidden = true
        visualEffectView.addSubview(spinner)

        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.alignment = .left
        label.autoresizingMask = [.width]
        label.frame = NSRect(
            x: waveformView.frame.maxX + Metrics.interItemSpacing,
            y: 17,
            width: availableLabelWidth(for: Metrics.minWidth),
            height: 22
        )
        visualEffectView.addSubview(label)
    }

    private func showIfNeeded() {
        let targetFrame = OverlayPanel.defaultFrame(width: desiredWidth(for: label.stringValue))
        if !isVisible {
            setFrame(targetFrame, display: true)
            alphaValue = 0
            orderFrontRegardless()
            makeKey()

            if let layer = rootView.layer {
                layer.removeAllAnimations()
                let scale = CASpringAnimation(keyPath: "transform.scale")
                scale.fromValue = 0.92
                scale.toValue = 1
                scale.damping = 18
                scale.initialVelocity = 1.3
                scale.mass = 1
                scale.stiffness = 180
                scale.duration = 0.35
                layer.add(scale, forKey: "scaleIn")
            }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                animator().alphaValue = 1
            }
            AutomationController.writeState(appState: appState, overlay: currentSnapshot())
        } else {
            animateToFrame(targetFrame)
        }
    }

    private func desiredWidth(for text: String) -> CGFloat {
        let width = labelWidth(for: text)
            + Metrics.leadingInset
            + Metrics.indicatorWidth
            + Metrics.interItemSpacing
            + Metrics.trailingInset
        return min(max(width, Metrics.minWidth), Metrics.maxWidth)
    }

    private func labelWidth(for text: String) -> CGFloat {
        let size = (text.isEmpty ? " " : text as NSString).size(withAttributes: [.font: label.font as Any])
        return ceil(size.width)
    }

    private func animateToWidth(_ width: CGFloat) {
        animateToFrame(OverlayPanel.defaultFrame(width: width))
    }

    private func availableLabelWidth(for panelWidth: CGFloat) -> CGFloat {
        let labelX = waveformView.frame.maxX + Metrics.interItemSpacing
        return max(panelWidth - labelX - Metrics.trailingInset, 0)
    }

    private func updateLabelWidth(for panelWidth: CGFloat, animated: Bool = false) {
        var frame = label.frame
        frame.size.width = availableLabelWidth(for: panelWidth)
        if animated {
            label.animator().frame = frame
        } else {
            label.frame = frame
        }
    }

    private func animateToFrame(_ targetFrame: NSRect) {
        guard isVisible else {
            updateLabelWidth(for: targetFrame.width)
            setFrame(targetFrame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            updateLabelWidth(for: targetFrame.width, animated: true)
            animator().setFrame(targetFrame, display: true)
        }
        AutomationController.writeState(appState: appState, overlay: currentSnapshot())
    }

    private static func defaultFrame(width: CGFloat) -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1512, height: 982)
        let originX = visibleFrame.midX - width / 2
        let originY = visibleFrame.minY + Metrics.bottomInset
        return NSRect(x: originX, y: originY, width: width, height: Metrics.height)
    }
}

private final class WaveformBarsView: NSView {
    private let barLayers: [CALayer]

    override init(frame frameRect: NSRect) {
        barLayers = (0..<5).map { _ in CALayer() }
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        setupBars()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func update(levels: [CGFloat]) {
        let width: CGFloat = 6
        let spacing: CGFloat = 2.5
        let minHeight: CGFloat = 6
        let maxHeight = bounds.height

        for (index, layer) in barLayers.enumerated() {
            let level = index < levels.count ? levels[index] : 0.12
            let barHeight = minHeight + (maxHeight - minHeight) * level
            let originX = CGFloat(index) * (width + spacing)
            let originY = (bounds.height - barHeight) / 2
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.08)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            layer.frame = CGRect(x: originX, y: originY, width: width, height: barHeight)
            CATransaction.commit()
        }
    }

    func reset() {
        update(levels: Array(repeating: 0.12, count: 5))
    }

    private func setupBars() {
        let color = NSColor.white.withAlphaComponent(0.9).cgColor
        for layer in barLayers {
            layer.backgroundColor = color
            layer.cornerRadius = 3
            self.layer?.addSublayer(layer)
        }
        reset()
    }
}
