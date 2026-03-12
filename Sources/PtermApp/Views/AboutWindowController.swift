import AppKit

final class AboutWindowController: NSWindowController, NSWindowDelegate {
    private let rootContentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
    private let hostedContentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
    private var backgroundGlassView: NSView?

    init(bundle: Bundle = .main) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "About pterm"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()

        super.init(window: window)

        rootContentView.autoresizingMask = [.width, .height]
        rootContentView.wantsLayer = true
        hostedContentView.autoresizingMask = [.width, .height]
        hostedContentView.wantsLayer = true
        rootContentView.addSubview(hostedContentView)
        window.contentView = rootContentView
        window.delegate = self

        installGlassBackgroundIfNeeded()
        buildContent(in: hostedContentView, bundle: bundle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func showAboutWindow() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.orderOut(nil)
    }

    private func installGlassBackgroundIfNeeded() {
        guard let window else { return }
        if #available(macOS 26.0, *) {
            let glassView: NSGlassEffectView
            if let existing = backgroundGlassView as? NSGlassEffectView {
                glassView = existing
            } else {
                glassView = NSGlassEffectView(frame: rootContentView.bounds)
                glassView.autoresizingMask = [.width, .height]
                glassView.style = .regular
                glassView.cornerRadius = 0
                backgroundGlassView = glassView
            }
            if glassView.superview !== rootContentView {
                rootContentView.addSubview(glassView, positioned: .below, relativeTo: hostedContentView)
            }
            glassView.frame = rootContentView.bounds
            glassView.isHidden = false
            glassView.tintColor = nil
            window.isOpaque = false
            window.backgroundColor = .clear
            rootContentView.layer?.backgroundColor = NSColor.clear.cgColor
            hostedContentView.layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            window.isOpaque = true
            window.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1.0)
            rootContentView.layer?.backgroundColor = window.backgroundColor?.cgColor
            hostedContentView.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    private func buildContent(in container: NSView, bundle: Bundle) {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView(frame: .zero)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        if let iconURL = bundle.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            iconView.image = icon
        }
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 72),
            iconView.heightAnchor.constraint(equalToConstant: 72)
        ])

        let appName = NSTextField(labelWithString: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "pterm")
        appName.font = NSFont.systemFont(ofSize: 26, weight: .semibold)
        appName.textColor = .white

        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let versionLabelText: String
        switch (shortVersion, buildVersion) {
        case let (.some(short), .some(build)) where !short.isEmpty && !build.isEmpty && short != build:
            versionLabelText = "Version \(short) (\(build))"
        case let (.some(short), _ ) where !short.isEmpty:
            versionLabelText = "Version \(short)"
        case let (_, .some(build)) where !build.isEmpty:
            versionLabelText = "Version \(build)"
        default:
            versionLabelText = "Version"
        }
        let versionLabel = NSTextField(labelWithString: versionLabelText)
        versionLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        versionLabel.textColor = NSColor(calibratedWhite: 0.82, alpha: 1.0)

        let subtitleLabel = NSTextField(labelWithString: "A secure, memory-efficient terminal for macOS")
        subtitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textColor = NSColor(calibratedWhite: 0.72, alpha: 1.0)

        for view in [iconView, appName, versionLabel, subtitleLabel] {
            content.addArrangedSubview(view)
        }

        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24)
        ])
    }
}
