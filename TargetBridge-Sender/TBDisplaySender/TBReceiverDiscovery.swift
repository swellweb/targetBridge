import Foundation

struct TBDiscoveredReceiver: Identifiable, Equatable {
    let serviceName: String
    let receiverName: String
    let preferredIP: String
    let thunderboltIP: String
    let networkIP: String
    let panelSummary: String
    let version: String

    var id: String { "\(serviceName)|\(preferredIP)" }

    func ip(for transportKind: TBTransportKind) -> String {
        switch transportKind {
        case .thunderboltBridge:
            return !thunderboltIP.isEmpty ? thunderboltIP : preferredIP
        case .networkLink:
            return !networkIP.isEmpty ? networkIP : preferredIP
        }
    }

    var displayText: String {
        let addressSummary: String
        switch (thunderboltIP.isEmpty, networkIP.isEmpty) {
        case (false, false):
            addressSummary = "TB \(thunderboltIP) · NET \(networkIP)"
        case (false, true):
            addressSummary = thunderboltIP
        case (true, false):
            addressSummary = networkIP
        case (true, true):
            addressSummary = preferredIP
        }

        if panelSummary.isEmpty {
            return "\(receiverName) · \(addressSummary)"
        }
        return "\(receiverName) · \(addressSummary) · \(panelSummary)"
    }
}

final class TBReceiverDiscovery: NSObject, ObservableObject {
    @Published private(set) var receivers: [TBDiscoveredReceiver] = []

    private let browser = NetServiceBrowser()
    private var services: [String: NetService] = [:]

    override init() {
        super.init()
        browser.delegate = self
        start()
    }

    func refresh() {
        stop()
        start()
    }

    private func runOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    private func start() {
        browser.searchForServices(ofType: "_targetbridge._tcp.", inDomain: "local.")
    }

    private func stop() {
        browser.stop()
        services.values.forEach { service in
            service.stop()
            service.delegate = nil
        }
        services.removeAll()
        receivers = []
    }

    private func upsertReceiver(from service: NetService) {
        guard let txtData = service.txtRecordData() else { return }
        let txt = NetService.dictionary(fromTXTRecord: txtData)

        func stringValue(_ key: String) -> String {
            guard let data = txt[key], !data.isEmpty else { return "" }
            return String(decoding: data, as: UTF8.self)
        }

        let receiverName = stringValue("name").isEmpty ? service.name : stringValue("name")
        let receiverIP = stringValue("ip")
        let thunderboltIP = stringValue("tbIP")
        let networkIP = stringValue("netIP")
        let preferredIP = !receiverIP.isEmpty ? receiverIP : (!thunderboltIP.isEmpty ? thunderboltIP : networkIP)
        guard !preferredIP.isEmpty else { return }

        let panelName = stringValue("panel")
        let panelWidth = stringValue("panelWidth")
        let panelHeight = stringValue("panelHeight")
        let version = stringValue("version")

        let panelSummary: String
        if !panelWidth.isEmpty, !panelHeight.isEmpty, !panelName.isEmpty {
            panelSummary = "\(panelName) (\(panelWidth)x\(panelHeight))"
        } else if !panelName.isEmpty {
            panelSummary = panelName
        } else if !panelWidth.isEmpty, !panelHeight.isEmpty {
            panelSummary = "\(panelWidth)x\(panelHeight)"
        } else {
            panelSummary = ""
        }

        let receiver = TBDiscoveredReceiver(
            serviceName: service.name,
            receiverName: receiverName,
            preferredIP: preferredIP,
            thunderboltIP: thunderboltIP,
            networkIP: networkIP,
            panelSummary: panelSummary,
            version: version
        )

        if let index = receivers.firstIndex(where: { $0.id == receiver.id }) {
            receivers[index] = receiver
        } else {
            receivers.append(receiver)
        }
        receivers.sort { lhs, rhs in
            if lhs.receiverName == rhs.receiverName {
                return lhs.preferredIP < rhs.preferredIP
            }
            return lhs.receiverName.localizedCaseInsensitiveCompare(rhs.receiverName) == .orderedAscending
        }
    }

    private func removeService(_ service: NetService) {
        services.removeValue(forKey: service.name)
        receivers.removeAll { $0.serviceName == service.name }
    }
}

extension TBReceiverDiscovery: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        runOnMain { [weak self] in
            guard let self else { return }
            service.delegate = self
            services[service.name] = service
            service.resolve(withTimeout: 5)
            if !moreComing {
                objectWillChange.send()
            }
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        runOnMain { [weak self] in
            guard let self else { return }
            removeService(service)
            if !moreComing {
                objectWillChange.send()
            }
        }
    }
}

extension TBReceiverDiscovery: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        runOnMain { [weak self] in
            self?.upsertReceiver(from: sender)
        }
    }

    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        runOnMain { [weak self] in
            self?.upsertReceiver(from: sender)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        runOnMain { [weak self] in
            guard sender.txtRecordData() != nil else { return }
            self?.upsertReceiver(from: sender)
        }
    }
}
