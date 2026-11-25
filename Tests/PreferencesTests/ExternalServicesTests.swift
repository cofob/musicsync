import Foundation
import Preferences
import Testing

@Suite struct ExternalServicesTests {
    @Test func savesAnswers() throws {
        let defaults = try #require(UserDefaults(suiteName: "prefs-test-\(UUID().uuidString)"))
        var access = ExternalAccess.load(from: defaults)
        #expect(access[.lrclib] == nil)
        access[.lrclib] = true
        access[.radio] = false
        access.save(to: defaults)
        let loaded = ExternalAccess.load(from: defaults)
        #expect(loaded[.lrclib] == true && loaded[.radio] == false && loaded[.presetCache] == nil)
    }

    /// The Little Snitch policy names every host the app may ask for.
    @Test func policyListsEveryHost() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/InternetAccessPolicy.plist")
        let policy = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        #expect(policy["ApplicationDescription"] is String)
        let connections = try #require(policy["Connections"] as? [[String: Any]])
        #expect(connections.allSatisfy { $0["Host"] is String && $0["Purpose"] is String })
        let hosts = Set(connections.flatMap { ($0["Host"] as! String).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } })
        for service in ExternalService.allCases {
            for host in service.hosts { #expect(hosts.contains(host), "\(host) of \(service)") }
        }
    }
}
