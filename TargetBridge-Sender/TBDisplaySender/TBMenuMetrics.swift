import AppKit

/// Geometry shared by the menu-bar panel's custom rows.
///
/// A menu takes the width of its widest item, so with only text items ours came
/// out around 240 pt — narrow enough to read as cramped beside the system's own
/// panels. Control Center's modules are ~340 pt, measured from the Sound and
/// Display panels on macOS 15.
///
/// The content view is set below that, because a menu draws its own chrome
/// around the item — a 340 pt view produced a visibly wider panel than Apple's.
/// This is the width of the row, not of the panel the user sees; the value was
/// settled by comparing the two panels on screen rather than by calculation.
///
/// Apple publishes no metrics for those panels — they are system UI, not a
/// component we can adopt — so this is deliberate imitation rather than a
/// documented standard. Two differences cannot be closed: menu items reserve a
/// leading column for checkmarks, so text rows sit further right than Control
/// Center's labels, and Control Center is a floating panel that draws its own
/// rounded background where a menu draws its own chrome.
enum TBMenuMetrics {
    static let width: CGFloat = 300
    static let inset: CGFloat = 14
}
