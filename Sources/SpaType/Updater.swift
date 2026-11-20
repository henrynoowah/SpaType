import AppKit
import Security

/// Checks GitHub Releases for a newer version and installs it on request.
/// Public repo, unauthenticated API (60 requests/hour per IP) — no token needed.
final class Updater {
    struct Release {
        let version: String
        let zipURL: URL
        let pageURL: URL
    }

    struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static let latestURL = URL(string: "https://api.github.com/repos/henrynoowah/SpaType/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/henrynoowah/SpaType/releases/latest")!

    private(set) var available: Release?
    private(set) var isInstalling = false

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Calls back on the main queue with the newer release, or nil (none, or the check failed).
    func check(completion: ((Release?) -> Void)? = nil) {
        struct Payload: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
            let tag_name: String
            let html_url: URL
            let assets: [Asset]
        }
        var request = URLRequest(url: Self.latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            var release: Release?
            if let self, let data, let payload = try? JSONDecoder().decode(Payload.self, from: data),
               let zip = payload.assets.first(where: { $0.name.hasSuffix(".zip") }) {
                let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
                if version.compare(self.currentVersion, options: .numeric) == .orderedDescending {
                    release = Release(version: version, zipURL: zip.browser_download_url, pageURL: payload.html_url)
                }
            }
            DispatchQueue.main.async {
                self?.available = release
                completion?(release)
            }
        }.resume()
    }

    /// Downloads, verifies and swaps in `release`, then relaunches. Calls back (main queue) only on failure.
    func install(_ release: Release, failure: @escaping (Error) -> Void) {
        guard !isInstalling else { return }
        let bundleURL = Bundle.main.bundleURL
        // Opened straight from Downloads, macOS runs a read-only copy from a random path: nothing to replace.
        guard !bundleURL.path.contains("/AppTranslocation/") else {
            failure(UpdateError("SpaType을 응용 프로그램 폴더로 옮긴 뒤 다시 실행하고 설치해 주세요."))
            return
        }
        isInstalling = true
        URLSession.shared.downloadTask(with: release.zipURL) { [weak self] zip, _, error in
            do {
                guard let zip else { throw error ?? UpdateError("다운로드에 실패했어요.") }
                // Same volume as the app, so the final swap is a rename.
                let work = try FileManager.default.url(
                    for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundleURL, create: true
                )
                defer { try? FileManager.default.removeItem(at: work) }
                try Self.run("/usr/bin/ditto", "-x", "-k", zip.path, work.path)
                let newApp = work.appendingPathComponent("SpaType.app")
                try Self.verifySameSigner(newApp)
                _ = try FileManager.default.replaceItemAt(bundleURL, withItemAt: newApp)
                DispatchQueue.main.async { Self.relaunch(bundleURL) }
            } catch {
                DispatchQueue.main.async {
                    self?.isInstalling = false
                    failure(error)
                }
            }
        }.resume()
    }

    /// Trust boundary: the download must satisfy this running app's own designated requirement,
    /// i.e. be signed with the same certificate. An ad-hoc–signed copy (cdhash-only requirement) never passes.
    private static func verifySameSigner(_ app: URL) throws {
        var me: SecCode?
        var meStatic: SecStaticCode?
        var requirement: SecRequirement?
        var candidate: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &meStatic) == errSecSuccess, let meStatic,
              SecCodeCopyDesignatedRequirement(meStatic, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate
        else { throw UpdateError("서명 정보를 읽지 못했어요.") }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(candidate, flags, requirement) == errSecSuccess else {
            throw UpdateError("새 버전의 서명이 현재 앱과 달라서 설치하지 않았어요.")
        }
    }

    private static func run(_ tool: String, _ args: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError("압축을 풀지 못했어요.") }
    }

    private static func relaunch(_ bundleURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}
