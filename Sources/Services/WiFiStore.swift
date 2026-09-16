import Foundation

/// Extracts known/joined Wi-Fi networks from the various com.apple.wifi*.plist files.
enum WiFiStore {
    private struct Net { var ssid: String; var bssid: String?; var lastJoined: Date?; var known: Bool }

    static func networks(from urls: [URL]) -> [DataRecord] {
        var merged: [String: Net] = [:]   // keyed by SSID (case-insensitive)

        func add(_ n: Net) {
            guard !n.ssid.isEmpty else { return }
            let key = n.ssid.lowercased()
            if var existing = merged[key] {
                if let d = n.lastJoined, (existing.lastJoined ?? .distantPast) < d { existing.lastJoined = d }
                if existing.bssid == nil { existing.bssid = n.bssid }
                existing.known = existing.known || n.known
                merged[key] = existing
            } else { merged[key] = n }
        }

        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { continue }

            // Format A: arrays of network dicts.
            for arrKey in ["List of known networks", "List of scanned networks with private mac", "List of scanned networks"] {
                if let arr = obj[arrKey] as? [[String: Any]] {
                    let known = arrKey.contains("known")
                    for d in arr {
                        add(Net(ssid: (d["SSID_STR"] as? String) ?? "",
                                bssid: d["BSSID"] as? String,
                                lastJoined: d["lastJoined"] as? Date,
                                known: known || (d["PresentInKnownNetworks"] as? Bool ?? false)))
                    }
                }
            }

            // Format B (iOS 16+): top-level keys "wifi.network.ssid._<SSID>".
            for (k, v) in obj where k.hasPrefix("wifi.network.ssid._") {
                let ssid = String(k.dropFirst("wifi.network.ssid._".count))
                let d = v as? [String: Any] ?? [:]
                let last = (d["lastJoined"] as? Date) ?? (d["AddedAt"] as? Date) ?? (d["addedAt"] as? Date)
                var bssid: String? = d["BSSID"] as? String
                if bssid == nil, let list = d["BEACON_PROBE_INFO_PER_BSSID_LIST"] as? [[String: Any]] { bssid = list.first?["BSSID"] as? String }
                add(Net(ssid: ssid, bssid: bssid, lastJoined: last, known: true))
            }
        }

        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        return merged.values
            .sorted { ($0.lastJoined ?? .distantPast) > ($1.lastJoined ?? .distantPast) }
            .map { n in
                var fields: [DataRecord.Field] = []
                if let b = n.bssid { fields.append(.init(label: "Router (BSSID)", value: b)) }
                if let d = n.lastJoined { fields.append(.init(label: "Last joined", value: df.string(from: d))) }
                fields.append(.init(label: "Status", value: n.known ? "Known network" : "Seen"))
                return DataRecord(id: "wifi-\(n.ssid)", title: n.ssid,
                                  subtitle: n.lastJoined.map { "Last joined \(df.string(from: $0))" } ?? (n.known ? "Known network" : "Seen"),
                                  date: n.lastJoined, fields: fields)
            }
    }
}
