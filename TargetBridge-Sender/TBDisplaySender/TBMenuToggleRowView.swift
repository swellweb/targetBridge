import AppKit

/// One circular toggle in the row.
struct TBMenuToggleSpec {
    let symbol: String
    let title: String
    /// Shown under the title, e.g. "On" / "Off" — mirrors Control Center.
    let stateText: String
    let isOn: Bool
    let onToggle: (Bool) -> Void
}

/// A row of circular on/off buttons laid out like Control Center's display
/// panel: filled accent circle when on, muted circle when off, with the name and
/// current state stacked underneath.
///
/// Built as a custom menu-item view rather than checkable NSMenuItems because
/// these are display *modes* the user flips repeatedly while looking at the
/// screen, and the Apple layout shows state at a glance without opening a
/// submenu. Menus don't lay out subviews for us, so all geometry is explicit.
final class TBMenuToggleRowView: NSView {

    private var buttons: [NSButton] = []
    private var stateFields: [NSTextField] = []
    private var specs: [TBMenuToggleSpec] = []

    private enum Metrics {
        static let circle: CGFloat = 38
        static let gap: CGFloat = 4          // circle -> title
        static let titleHeight: CGFloat = 14
        static let stateHeight: CGFloat = 13
        static let topPadding: CGFloat = 6
        static let bottomPadding: CGFloat = 8
        static var height: CGFloat {
            topPadding + circle + gap + titleHeight + stateHeight + bottomPadding
        }
    }

    static var preferredHeight: CGFloat { Metrics.height }

    init(specs: [TBMenuToggleSpec], width: CGFloat, leadingInset: CGFloat) {
        self.specs = specs
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Metrics.height))
        build(width: width, leadingInset: leadingInset)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build(width: CGFloat, leadingInset: CGFloat) {
        guard !specs.isEmpty else { return }

        let usable = width - leadingInset * 2
        let cellWidth = usable / CGFloat(specs.count)

        for (index, spec) in specs.enumerated() {
            let cellX = leadingInset + cellWidth * CGFloat(index)
            let centerX = cellX + cellWidth / 2

            // Buttons are laid out from the top down; AppKit's origin is bottom
            // left, so each y is measured back from the view's height.
            let circleY = Metrics.height - Metrics.topPadding - Metrics.circle

            let button = NSButton(frame: NSRect(x: centerX - Metrics.circle / 2,
                                               y: circleY,
                                               width: Metrics.circle,
                                               height: Metrics.circle))
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.title = ""
            button.wantsLayer = true
            button.layer?.cornerRadius = Metrics.circle / 2
            button.imagePosition = .imageOnly
            button.setButtonType(.momentaryChange)

            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            button.image = NSImage(systemSymbolName: spec.symbol,
                                   accessibilityDescription: spec.title)?
                .withSymbolConfiguration(config)
            // A toggle, not a plain button: the checkbox role is what makes
            // VoiceOver announce the on/off state, which is otherwise only
            // conveyed by the caption underneath.
            button.setAccessibilityLabel(spec.title)
            button.setAccessibilityRole(.checkBox)
            button.setAccessibilityValue(NSNumber(value: spec.isOn))

            button.tag = index
            button.target = self
            button.action = #selector(tapped(_:))
            applyStyle(to: button, isOn: spec.isOn)
            addSubview(button)
            buttons.append(button)

            let titleY = circleY - Metrics.gap - Metrics.titleHeight
            // The captions repeat what the button already announces, so keep
            // them out of the accessibility tree rather than reading twice.
            addSubview(label(spec.title,
                             frame: NSRect(x: cellX, y: titleY, width: cellWidth, height: Metrics.titleHeight),
                             font: .systemFont(ofSize: 11, weight: .medium),
                             color: .labelColor))

            let stateField = label(spec.stateText,
                                   frame: NSRect(x: cellX, y: titleY - Metrics.stateHeight,
                                                 width: cellWidth, height: Metrics.stateHeight),
                                   font: .systemFont(ofSize: 10, weight: .regular),
                                   color: .secondaryLabelColor)
            addSubview(stateField)
            stateFields.append(stateField)
        }
    }

    private func label(_ text: String, frame: NSRect, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.setAccessibilityElement(false)
        field.frame = frame
        field.font = font
        field.textColor = color
        field.alignment = .center
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func applyStyle(to button: NSButton, isOn: Bool) {
        // Accent fill + white glyph when on; muted fill + normal glyph when off,
        // matching Control Center rather than inventing a colour scheme.
        button.layer?.backgroundColor = isOn
            ? NSColor.controlAccentColor.cgColor
            : NSColor.quaternaryLabelColor.withAlphaComponent(0.22).cgColor
        button.contentTintColor = isOn ? .white : .labelColor
    }

    @objc private func tapped(_ sender: NSButton) {
        let index = sender.tag
        guard specs.indices.contains(index) else { return }

        let newState = !isOn(index)
        states[index] = newState
        applyStyle(to: sender, isOn: newState)
        sender.setAccessibilityValue(NSNumber(value: newState))
        // Reflect the change immediately; the menu usually closes on click, but
        // if it stays open the row should not show a stale state.
        if let field = stateField(at: index) {
            field.stringValue = newState ? onWord : offWord
        }
        specs[index].onToggle(newState)
    }

    // MARK: - Live state

    private lazy var states: [Int: Bool] = {
        var map: [Int: Bool] = [:]
        for (i, s) in specs.enumerated() { map[i] = s.isOn }
        return map
    }()

    private func isOn(_ index: Int) -> Bool {
        states[index] ?? specs[index].isOn
    }

    /// Words used when a tap updates the state line. Set by the owner so the
    /// row stays localised without knowing about the localisation layer.
    var onWord = "On"
    var offWord = "Off"

    private func stateField(at index: Int) -> NSTextField? {
        stateFields.indices.contains(index) ? stateFields[index] : nil
    }
}
