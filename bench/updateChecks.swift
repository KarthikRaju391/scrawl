// Check for Updates: version compare and reading GitHub's "latest release" response.
// Fixture shape: docs.github.com/rest/releases/releases#get-the-latest-release (trimmed to the fields used).
import Foundation

func updateChecks(_ check: (Bool, String) -> Void) {
    let cmp: [(String, String, Bool)] = [("v1.0.1", "1.0.0", true), ("1.10.0", "1.9.2", true), ("1.0", "1.0.0", false),
                                         ("v1.0.0", "1.0.0", false), ("0.9.9", "1.0.0", false), ("2", "1.99.99", true)]
    check(cmp.allSatisfy { UpdateChecker.isNewer($0.0, than: $0.1) == $0.2 }, "version compare: v-prefix, 1.10 > 1.9, 1.0 == 1.0.0")
    func release(_ tag: String, draft: Bool = false, pre: Bool = false) -> Data {
        try! JSONSerialization.data(withJSONObject: ["url": "https://api.github.com/repos/o/r/releases/1", "html_url": "https://github.com/o/r/releases/tag/\(tag)",
                                                     "id": 1, "tag_name": tag, "name": "Trackpad Draw \(tag)", "draft": draft, "prerelease": pre,
                                                     "published_at": "2026-11-01T10:00:00Z", "body": "notes", "assets": []])
    }
    check(UpdateChecker.parse(status: 200, data: release("v1.1.0"), current: "1.0.0") == .available(version: "1.1.0", page: "https://github.com/o/r/releases/tag/v1.1.0"),
          "newer release: offered, with its release page")
    check(UpdateChecker.parse(status: 200, data: release("v1.0.0"), current: "1.0.0") == .upToDate("1.0.0"), "same version: up to date")
    check(UpdateChecker.parse(status: 200, data: release("v2.0.0-beta", pre: true), current: "1.0.0") == .upToDate("1.0.0"), "prerelease: not offered")
    check(UpdateChecker.parse(status: 404, data: Data("{\"message\":\"Not Found\"}".utf8), current: "1.0.0") == .failed("No published release found."),
          "404 (private repo or no release yet): says so")
    check({ if case .failed = UpdateChecker.parse(status: 200, data: Data("<html>".utf8), current: "1.0.0") { return true }; return false }(),
          "unreadable answer: a clear failure, no crash")
}
