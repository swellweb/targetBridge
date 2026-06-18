import AppKit
import SwiftUI

/// Per-session editor for shortcut bindings (trigger on master → action on slave).
struct TBInputBindingsView: View {
    @ObservedObject var session: TBDisplaySenderSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Shortcut bindings")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    session.inputBindings.append(
                        TBInputBinding(
                            trigger: TBInputShortcut(keyCode: 123, modifiers: TBInputShortcut.control | TBInputShortcut.option),
                            action: TBInputShortcut(keyCode: 123, modifiers: TBInputShortcut.control)
                        )
                    )
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if session.inputBindings.isEmpty {
                Text("No bindings. Add one to map a trigger you press on the master to a shortcut injected on the slave.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach($session.inputBindings) { $binding in
                    HStack(spacing: 8) {
                        Toggle("", isOn: $binding.enabled)
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                        TBShortcutRecorderButton(shortcut: $binding.trigger)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TBShortcutRecorderButton(shortcut: $binding.action)
                        Spacer()
                        Button(role: .destructive) {
                            session.inputBindings.removeAll { $0.id == binding.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Text("Trigger is pressed on the master; Action is injected on the slave (direction follows the input role). A trigger can't be a combo macOS reserves (e.g. ⌃← for Spaces) — the OS grabs it first; use something like ⌃⌥←. The Action may be any combo, including reserved ones, since it fires the slave's own shortcut (e.g. ⌃← to switch the slave's Space). Bindings apply while the session is connected.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A button that records a single key combo when clicked (press the shortcut).
struct TBShortcutRecorderButton: View {
    @Binding var shortcut: TBInputShortcut
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            toggleRecording()
        } label: {
            Text(recording ? "Press…" : shortcut.displayString)
                .font(.system(.body, design: .rounded).monospacedDigit())
                .frame(minWidth: 64)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(recording ? .accentColor : nil)
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        if recording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Ignore standalone modifier presses; require a real key.
            if TBInputBindingEngine.isModifierKeyCode(event.keyCode) {
                return nil
            }
            shortcut = TBInputShortcut(
                keyCode: event.keyCode,
                modifiers: TBInputShortcut.modifiers(from: event.modifierFlags)
            )
            stopRecording()
            return nil // swallow so the captured key doesn't act
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        recording = false
    }
}
