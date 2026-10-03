import ApplicationServices
import SwiftUI

struct TBDisplaySenderPermissionAssistant: View {
    @ObservedObject var service: TBDisplaySenderService

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(copy.title, systemImage: "checkmark.shield")
                .font(.title2.weight(.bold))

            Text(copy.intro)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            permissionRow(copy.screenRecording, granted: CGPreflightScreenCaptureAccess()) {
                service.requestScreenRecordingPermission()
            }
            permissionRow(copy.accessibility, granted: AXIsProcessTrusted()) {
                service.requestAccessibilityPermission()
            }
            permissionRow(copy.inputMonitoring, granted: CGPreflightListenEventAccess()) {
                service.requestInputMonitoringPermission()
            }

            HStack {
                Button(copy.openSettings) { service.openScreenRecordingSettings() }
                Button(copy.restart) { service.restartAfterPermissionChange() }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button(copy.done) { service.showingPermissionAssistant = false }
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { service.refreshPrivacyPermissions() }
    }

    private func permissionRow(_ title: String, granted: Bool, request: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .yellow)
            Text(title)
            Spacer()
            if granted {
                Text(copy.granted).foregroundStyle(.secondary)
            } else {
                Button(copy.allow, action: request).buttonStyle(.bordered)
            }
        }
    }

    private var copy: Copy {
        switch service.language {
        case .italian: return .init(title: "Permessi di TargetBridge", intro: "macOS richiede la tua conferma una sola volta per ogni app installata. Puoi autorizzare qui oppure aprire direttamente le Impostazioni.", screenRecording: "Registrazione schermo", accessibility: "Accessibilità", inputMonitoring: "Monitoraggio input", granted: "Attivo", allow: "Consenti", openSettings: "Apri Impostazioni", restart: "Riavvia TargetBridge", done: "Fine")
        case .english: return .init(title: "TargetBridge Permissions", intro: "macOS requires your confirmation once for each installed app. Approve here or open the matching System Settings page.", screenRecording: "Screen Recording", accessibility: "Accessibility", inputMonitoring: "Input Monitoring", granted: "Granted", allow: "Allow", openSettings: "Open Settings", restart: "Restart TargetBridge", done: "Done")
        case .german: return .init(title: "TargetBridge-Berechtigungen", intro: "macOS benötigt deine Bestätigung einmal für jede installierte App. Du kannst hier zustimmen oder die passende Systemeinstellung öffnen.", screenRecording: "Bildschirmaufnahme", accessibility: "Bedienungshilfen", inputMonitoring: "Eingabeüberwachung", granted: "Aktiv", allow: "Erlauben", openSettings: "Einstellungen öffnen", restart: "TargetBridge neu starten", done: "Fertig")
        case .french: return .init(title: "Autorisations TargetBridge", intro: "macOS demande votre confirmation une fois pour chaque app installée. Autorisez ici ou ouvrez directement les Réglages correspondants.", screenRecording: "Enregistrement de l’écran", accessibility: "Accessibilité", inputMonitoring: "Surveillance des entrées", granted: "Autorisé", allow: "Autoriser", openSettings: "Ouvrir les réglages", restart: "Redémarrer TargetBridge", done: "Terminé")
        case .chinese: return .init(title: "TargetBridge 权限", intro: "macOS 需要你为每个已安装的应用确认一次权限。可在此授权，或直接打开相应的系统设置页面。", screenRecording: "屏幕录制", accessibility: "辅助功能", inputMonitoring: "输入监控", granted: "已授权", allow: "允许", openSettings: "打开设置", restart: "重新启动 TargetBridge", done: "完成")
        }
    }

    private struct Copy {
        let title: String
        let intro: String
        let screenRecording: String
        let accessibility: String
        let inputMonitoring: String
        let granted: String
        let allow: String
        let openSettings: String
        let restart: String
        let done: String
    }
}
