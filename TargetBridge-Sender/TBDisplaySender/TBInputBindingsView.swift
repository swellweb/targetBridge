import AppKit
import SwiftUI

/// Per-session editor for receiver-master shortcut bindings.
struct TBInputBindingsView: View {
    @ObservedObject var session: TBDisplaySenderSession
    let language: TBDisplaySenderLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(TBDisplaySenderL10n.text("sender.input_bindings.title", language))
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
                    Label(TBDisplaySenderL10n.text("sender.input_bindings.add", language), systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if session.inputBindings.isEmpty {
                Text(TBDisplaySenderL10n.text("sender.input_bindings.empty", language))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach($session.inputBindings) { $binding in
                    HStack(spacing: 8) {
                        Toggle("", isOn: $binding.enabled)
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                        TBShortcutRecorderButton(shortcut: $binding.trigger, language: language)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TBShortcutRecorderButton(shortcut: $binding.action, language: language)
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

            Text(TBDisplaySenderL10n.text("sender.input_bindings.details", language))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A button that records a single key combo when clicked (press the shortcut).
struct TBShortcutRecorderButton: View {
    @Binding var shortcut: TBInputShortcut
    let language: TBDisplaySenderLanguage
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            toggleRecording()
        } label: {
            Text(recording ? TBDisplaySenderL10n.text("sender.input_bindings.record", language) : shortcut.displayString)
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
