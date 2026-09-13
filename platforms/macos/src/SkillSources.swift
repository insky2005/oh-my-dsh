//
//  SkillSources.swift — network / fetch / install / remove for the Skills panel.
//
//  Discovery and storage live in SkillsCore.swift; this file owns the outside
//  world: address parsing (mirrors the open skills CLI), registry catalogs
//  (well-known index, GitHub repo) and search, cloning/fetching a skill into a
//  temp dir, and copying it into a dsh root.
//
//  Every side effect goes through SkillTransport, so the whole layer runs
//  headless with injected fakes (tests/skills-panel).
//

import Foundation

// MARK: - Errors

/// Model-layer failures. The panel maps l10nKey to a localized string; the
/// model itself never carries user-facing prose.
enum SkillPanelError: Error, Equatable {
    case unsupportedAddress(String)
    case unsupportedTarget
    case insecureURL(String)
    case noSkillsFound
    case invalidName(String)
    case missingFrontmatter
    case targetExists(String)
    case builtinProtected
    case builtinReadOnly
    case sharedNotRemovable
    case gitUnavailable
    case unsafePath(String)
    case queryTooShort
    case noCatalog
    case network(String)
    case io(String)

    var l10nKey: String {
        switch self {
        case .unsupportedAddress: return "skills.err.unsupportedAddress"
        case .unsupportedTarget: return "skills.err.unsupportedTarget"
        case .insecureURL: return "skills.err.insecureURL"
        case .noSkillsFound: return "skills.err.noSkillsFound"
        case .invalidName: return "skills.err.invalidName"
        case .missingFrontmatter: return "skills.err.missingFrontmatter"
        case .targetExists: return "skills.err.targetExists"
        case .builtinProtected: return "skills.err.builtinProtected"
        case .builtinReadOnly: return "skills.err.builtinReadOnly"
        case .sharedNotRemovable: return "skills.err.sharedNotRemovable"
        case .gitUnavailable: return "skills.err.gitUnavailable"
        case .unsafePath: return "skills.err.unsafePath"
        case .queryTooShort: return "skills.err.queryTooShort"
        case .noCatalog: return "skills.err.noCatalog"
        case .network: return "skills.err.network"
        case .io: return "skills.err.io"
        }
    }

    /// Extra text appended to the localized message (name, URL, ...).
    var detail: String {
        switch self {
        case .unsupportedAddress(let s), .insecureURL(let s), .invalidName(let s),
             .targetExists(let s), .unsafePath(let s), .network(let s), .io(let s):
            return s
        default:
            return ""
        }
    }
}

// MARK: - Address parsing

enum SkillAddress: Equatable {
    /// GitHub shorthand/URL. The skill field selects one skill in the repo.
    case github(owner: String, repo: String, ref: String?, subpath: String?, skill: String?)
    /// Any other git remote.
    case git(url: String, ref: String?)
    /// A registry exposing /.well-known/skills/index.json.
    case wellKnown(baseURL: String)
    /// A local directory or SKILL.md file (manual import).
    case local(path: String)

    var sourceLabel: String {
        switch self {
        case .github(let o, let r, _, _, _): return o + "/" + r
        case .git(let url, _): return url
        case .wellKnown(let base): return base
        case .local(let path): return (path as NSString).lastPathComponent
        }
    }
}

enum SkillAddressParser {

    static func parse(_ raw: String) -> SkillAddress? {
        var input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        if input.hasPrefix("github:") { input = String(input.dropFirst("github:".count)) }
        else if input.hasPrefix("gitlab:") { input = "https://gitlab.com/" + String(input.dropFirst("gitlab:".count)) }

        if isLocalPath(input) {
            return .local(path: SkillRoots.expand(input))
        }
        if let m = firstMatch(input, "^.*github\\.com/([^/]+)/([^/]+)/tree/([^/]+)/(.+)$") {
            return .github(owner: m[0], repo: stripGit(m[1]), ref: opt(m[2]), subpath: opt(m[3]), skill: nil)
        }
        if let m = firstMatch(input, "^.*github\\.com/([^/]+)/([^/]+)/tree/([^/]+)$") {
            return .github(owner: m[0], repo: stripGit(m[1]), ref: opt(m[2]), subpath: nil, skill: nil)
        }
        if let m = firstMatch(input, "^.*github\\.com/([^/]+)/([^/]+?)(?:\\.git)?/?$") {
            return .github(owner: m[0], repo: stripGit(m[1]), ref: nil, subpath: nil, skill: nil)
        }
        if !input.contains(":"), !input.hasPrefix("/"), !input.hasPrefix("."),
           let m = firstMatch(input, "^([^/]+)/([^/@]+)@(.+)$") {
            return .github(owner: m[0], repo: stripGit(m[1]), ref: nil, subpath: nil, skill: opt(m[2]))
        }
        if !input.contains(":"), !input.hasPrefix("/"), !input.hasPrefix("."),
           let m = firstMatch(input, "^([^/]+)/([^/]+)(?:/(.+))?$") {
            let sub = m.count > 2 ? opt(m[2]) : nil
            return .github(owner: m[0], repo: stripGit(m[1]), ref: nil, subpath: sub, skill: nil)
        }
        if input.hasPrefix("http://") || input.hasPrefix("https://") {
            if input.hasSuffix(".git") { return .git(url: input, ref: nil) }
            if let m = firstMatch(input, "^(.+?)://([^/]+)/(.+)$"), m[1].contains("gitlab") {
                return .git(url: input, ref: nil)
            }
            if input.lowercased().hasSuffix("/skill.md") {
                return .wellKnown(baseURL: String(input.dropLast("/SKILL.md".count)))
            }
            return .wellKnown(baseURL: trimSlash(input))
        }
        if input.hasSuffix(".git") { return .git(url: input, ref: nil) }
        return nil
    }

    static func isLocalPath(_ input: String) -> Bool {
        if input.hasPrefix("/") || input.hasPrefix("./") || input.hasPrefix("../")
            || input == "." || input == ".." || input.hasPrefix("~") { return true }
        return firstMatch(input, "^[a-zA-Z]:[/\\\\]") != nil
    }

    /// A non-participating capture group comes back as "" — normalise to nil.
    static func opt(_ s: String) -> String? { s.isEmpty ? nil : s }

    static func stripGit(_ repo: String) -> String {
        repo.hasSuffix(".git") ? String(repo.dropLast(4)) : repo
    }

    static func trimSlash(_ s: String) -> String {
        var v = s
        while v.hasSuffix("/") { v = String(v.dropLast()) }
        return v
    }

    /// Minimal regex helper: first match, capture groups 1..n.
    static func firstMatch(_ input: String, _ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        guard let m = re.firstMatch(in: input, range: range) else { return nil }
        var out: [String] = []
        for i in 1..<m.numberOfRanges {
            guard let r = Range(m.range(at: i), in: input) else { out.append(""); continue }
            out.append(String(input[r]))
        }
        return out
    }
}

// MARK: - Transport (injectable)

enum SkillTransport {

    /// Synchronous HTTP seam.
    static var fetch: (URLRequest) -> (status: Int, body: Data?) = { request in
        let timeout = request.timeoutInterval > 0 ? request.timeoutInterval : 20
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpAdditionalHeaders = ["User-Agent": "oh-my-dsh-skills"]
        let session = URLSession(configuration: config)
        let sem = DispatchSemaphore(value: 0)
        var status = -1
        var body: Data?
        let task = session.dataTask(with: request) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? -1
            body = data
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + timeout + 2)
        session.finishTasksAndInvalidate()
        return (status, body)
    }

    /// Process seam (git / tar). Credential prompts are disabled: the app has
    /// no tty, so a private repo must fail fast instead of hanging.
    static var run: (String, [String], String?) -> (status: Int32, output: String) = { launch, args, cwd in
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launch)
        proc.arguments = args
        if let cwd = cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ASKPASS"] = "/usr/bin/true"
        env["SSH_ASKPASS"] = "/usr/bin/true"
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch { return (-1, "spawn failed: " + launch) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static let gitPath = "/usr/bin/git"
    static let tarPath = "/usr/bin/tar"
}

// MARK: - Candidates

struct SkillCandidate {
    var name: String
    var description: String
    var sourceLabel: String
    var installs: Int?
    var address: SkillAddress
}

// MARK: - Registry client

enum SkillRegistryClient {

    static let indexPath = ".well-known/skills/index.json"

    // MARK: search

    /// Render the registry's search template and parse the skills.sh response.
    static func search(_ registry: SkillRegistryRecord, query: String, limit: Int = 30) throws -> [SkillCandidate] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { throw SkillPanelError.queryTooShort }
        guard let template = registry.searchURL, !template.isEmpty else { throw SkillPanelError.noCatalog }
        let url = try renderSearchURL(template, query: q, limit: limit)
        guard let requestURL = URL(string: url) else { throw SkillPanelError.network(url) }
        if !isSecure(url) { throw SkillPanelError.insecureURL(url) }
        let res = SkillTransport.fetch(URLRequest(url: requestURL, timeoutInterval: 30))
        guard res.status == 200, let body = res.body else {
            throw SkillPanelError.network("HTTP " + String(res.status))
        }
        return try parseSearchResponse(body)
    }

    static func renderSearchURL(_ template: String, query: String, limit: Int) throws -> String {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        var url = template.replacingOccurrences(of: "{q}", with: encoded)
        url = url.replacingOccurrences(of: "{limit}", with: String(limit))
        if !template.contains("{q}") {
            url += (url.contains("?") ? "&" : "?") + "q=" + encoded
        }
        return url
    }

    /// skills.sh responds with {skills:[{id, skillId, name, installs, source}]}.
    static func parseSearchResponse(_ body: Data) throws -> [SkillCandidate] {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let items = json["skills"] as? [[String: Any]] else {
            throw SkillPanelError.network("unexpected search response")
        }
        var out: [SkillCandidate] = []
        for item in items {
            guard let name = item["name"] as? String, !name.isEmpty else { continue }
            let source = (item["source"] as? String) ?? ""
            guard let parsed = SkillAddressParser.parse(source) else { continue }
            out.append(SkillCandidate(name: name,
                                      description: "",
                                      sourceLabel: source,
                                      installs: item["installs"] as? Int,
                                      address: withSkill(parsed, name)))
        }
        return out
    }

    static func withSkill(_ address: SkillAddress, _ skill: String) -> SkillAddress {
        if case .github(let o, let r, let ref, let sub, _) = address {
            return .github(owner: o, repo: r, ref: ref, subpath: sub, skill: skill)
        }
        return address
    }

    // MARK: catalog

    /// The registry's enumerable list, when it has one.
    static func catalog(_ registry: SkillRegistryRecord, temp: String? = nil) throws -> [SkillCandidate] {
        switch registry.catalog {
        case .none:
            throw SkillPanelError.noCatalog
        case .wellKnown:
            return try listWellKnown(base: registry.catalogURL)
        case .githubRepo:
            guard let parsed = SkillAddressParser.parse(registry.catalogURL) else {
                throw SkillPanelError.unsupportedAddress(registry.catalogURL)
            }
            let ownTemp = temp == nil
            let dir = temp ?? SkillFetcher.makeTempDir()
            defer { if ownTemp { try? FileManager.default.removeItem(atPath: dir) } }
            let skills = try SkillFetcher.fetch(parsed, temp: dir)
            return skills.map { fetched in
                SkillCandidate(name: fetched.name,
                               description: fetched.description,
                               sourceLabel: registry.catalogURL,
                               installs: nil,
                               address: skillAddress(for: fetched, base: parsed))
            }
        }
    }

    static func skillAddress(for fetched: FetchedSkill, base: SkillAddress) -> SkillAddress {
        if case .github(let o, let r, let ref, let sub, _) = base {
            return .github(owner: o, repo: r, ref: ref, subpath: sub, skill: fetched.name)
        }
        return base
    }

    /// GET <base>/.well-known/skills/index.json
    static func listWellKnown(base: String) throws -> [SkillCandidate] {
        var root = SkillAddressParser.trimSlash(base)
        if root.hasSuffix("/SKILL.md") { root = String(root.dropLast("/SKILL.md".count)) }
        let indexURL = root + "/" + indexPath
        if !isSecure(indexURL) { throw SkillPanelError.insecureURL(indexURL) }
        guard let url = URL(string: indexURL) else { throw SkillPanelError.network(indexURL) }
        let res = SkillTransport.fetch(URLRequest(url: url, timeoutInterval: 30))
        guard res.status == 200, let body = res.body else {
            throw SkillPanelError.network("HTTP " + String(res.status) + " " + indexURL)
        }
        let entries = try parseWellKnownIndex(body)
        return entries.map { entry in
            SkillCandidate(name: entry.name,
                           description: entry.description,
                           sourceLabel: URL(string: root)?.host ?? root,
                           installs: nil,
                           address: .wellKnown(baseURL: root + "/.well-known/skills/" + entry.name))
        }
    }

    struct IndexEntry {
        var name: String
        var description: String
        var files: [String]
    }

    /// {skills:[{name, description, files:[...]}]} with the CLI's validation:
    /// name/description non-empty, relative files (no absolute, no ..) and at
    /// least one SKILL.md.
    static func parseWellKnownIndex(_ body: Data) throws -> [IndexEntry] {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let items = json["skills"] as? [[String: Any]] else {
            throw SkillPanelError.network("unexpected index.json")
        }
        var out: [IndexEntry] = []
        for item in items {
            guard let name = item["name"] as? String, !name.isEmpty else { continue }
            guard let description = item["description"] as? String, !description.isEmpty else { continue }
            guard let files = item["files"] as? [String], !files.isEmpty else { continue }
            var safe = true
            for f in files where f.hasPrefix("/") || f.hasPrefix("\\") || f.contains("..") {
                safe = false
            }
            guard safe else { continue }
            guard files.contains(where: { $0.lowercased() == "skill.md" }) else { continue }
            out.append(IndexEntry(name: name, description: description, files: files))
        }
        if out.isEmpty { throw SkillPanelError.noSkillsFound }
        return out
    }

    // MARK: probe

    /// Turn a user-entered address into a registry entry (add-registry form).
    static func probe(_ input: String, probeNetwork: Bool = true) -> SkillRegistryRecord? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("github.com/") || firstMatchShorthand(trimmed) {
            guard let parsed = SkillAddressParser.parse(trimmed),
                  case .github(let o, let r, _, _, _) = parsed else { return nil }
            return SkillRegistryRecord(id: "gh-" + o + "-" + r,
                                       label: o + "/" + r,
                                       enabled: true,
                                       searchURL: nil,
                                       catalog: .githubRepo,
                                       catalogURL: o + "/" + r)
        }
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return nil }
        if trimmed.hasSuffix(indexPath) {
            let root = SkillAddressParser.trimSlash(String(trimmed.dropLast(indexPath.count)))
            return SkillRegistryRecord(id: "wk-" + root, label: URL(string: root)?.host ?? root,
                                       enabled: true, searchURL: nil,
                                       catalog: .wellKnown, catalogURL: root)
        }
        let root = SkillAddressParser.trimSlash(trimmed)
        if probeNetwork, (try? listWellKnown(base: root)) != nil {
            return SkillRegistryRecord(id: "wk-" + root, label: URL(string: root)?.host ?? root,
                                       enabled: true, searchURL: nil,
                                       catalog: .wellKnown, catalogURL: root)
        }
        return SkillRegistryRecord(id: "search-" + root, label: URL(string: root)?.host ?? root,
                                   enabled: true,
                                   searchURL: root + "/api/search?q={q}&limit={limit}",
                                   catalog: .none, catalogURL: "")
    }

    static func firstMatchShorthand(_ input: String) -> Bool {
        guard !input.contains(":"), !input.hasPrefix("/"), !input.hasPrefix(".") else { return false }
        return SkillAddressParser.firstMatch(input, "^([^/]+)/([^/]+)$") != nil
    }

    static func isSecure(_ url: String) -> Bool {
        if url.hasPrefix("https://") { return true }
        if url.hasPrefix("http://127.0.0.1") || url.hasPrefix("http://localhost") { return true }
        return false
    }
}

// MARK: - Fetcher

struct FetchedSkill {
    var name: String
    var description: String
    /// relative path -> bytes (SKILL.md included).
    var files: [String: Data]
    var sourceLabel: String
    var sourceType: String
    var sourceUrl: String
    var ref: String?
    /// Path of SKILL.md inside the source ("" for a flat single file).
    var path: String
}

enum SkillFetcher {

    static let skipDirs: Set<String> = ["node_modules", ".git", "dist", "build", "__pycache__"]
    static let maxFileBytes = 2 * 1024 * 1024
    static let maxFiles = 400

    static func makeTempDir() -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ohmy-dsh-skills-" + UUID().uuidString)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Fetch every skill a source address yields.
    static func fetch(_ address: SkillAddress, temp: String) throws -> [FetchedSkill] {
        switch address {
        case .local(let path):
            guard let skill = readLocalSkill(path) else { throw SkillPanelError.noSkillsFound }
            return [skill]
        case .wellKnown(let base):
            return [try fetchWellKnownSkill(base: base)]
        case .github(let owner, let repo, let ref, let subpath, let skill):
            let root = try cloneOrDownload(owner: owner, repo: repo, ref: ref,
                                           url: "https://github.com/" + owner + "/" + repo + ".git",
                                           temp: temp)
            let searchRoot = subpath.map { SkillRoots.join(root, $0) } ?? root
            let found = discover(searchRoot, label: owner + "/" + repo,
                                 sourceType: "github",
                                 sourceUrl: "https://github.com/" + owner + "/" + repo,
                                 ref: ref)
            return filter(found, skill: skill)
        case .git(let url, let ref):
            let root = try cloneOrDownload(owner: nil, repo: nil, ref: ref, url: url, temp: temp)
            let found = discover(root, label: url, sourceType: "git", sourceUrl: url, ref: ref)
            return filter(found, skill: nil)
        }
    }

    static func filter(_ skills: [FetchedSkill], skill: String?) -> [FetchedSkill] {
        guard let wanted = skill, !wanted.isEmpty else { return skills }
        let matched = skills.filter { $0.name == wanted }
        return matched.isEmpty ? skills : matched
    }

    // MARK: git / tarball

    static func cloneOrDownload(owner: String?, repo: String?, ref: String?, url: String, temp: String) throws -> String {
        let dest = SkillRoots.join(temp, "clone")
        var args = ["clone", "--depth", "1", "--quiet"]
        if let ref = ref, !ref.isEmpty { args += ["--branch", ref] }
        args += [url, dest]
        let res = SkillTransport.run(SkillTransport.gitPath, args, temp)
        if res.status == 0, FileManager.default.fileExists(atPath: dest) { return dest }
        if let owner = owner, let repo = repo {
            return try downloadTarball(owner: owner, repo: repo, ref: ref, temp: temp)
        }
        throw SkillPanelError.network("git clone failed: " + lastLines(res.output))
    }

    static func downloadTarball(owner: String, repo: String, ref: String?, temp: String) throws -> String {
        let branches = ref.map { [$0] } ?? ["main", "master"]
        let archive = SkillRoots.join(temp, "src.tar.gz")
        for branch in branches {
            let url = "https://codeload.github.com/" + owner + "/" + repo + "/tar.gz/refs/heads/" + branch
            guard let u = URL(string: url) else { continue }
            let res = SkillTransport.fetch(URLRequest(url: u, timeoutInterval: 60))
            guard res.status == 200, let body = res.body, !body.isEmpty else { continue }
            guard (try? body.write(to: URL(fileURLWithPath: archive))) != nil else { continue }
            let dest = SkillRoots.join(temp, "clone")
            try? FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
            let untar = SkillTransport.run(SkillTransport.tarPath, ["-xzf", archive, "-C", dest], temp)
            guard untar.status == 0 else { continue }
            // The tarball unpacks into <repo>-<branch>/ — descend into it.
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: dest)) ?? []
            if entries.count == 1, let only = entries.first {
                var isDir: ObjCBool = false
                let inner = SkillRoots.join(dest, only)
                if FileManager.default.fileExists(atPath: inner, isDirectory: &isDir), isDir.boolValue {
                    return inner
                }
            }
            return dest
        }
        throw SkillPanelError.network("download failed: " + owner + "/" + repo)
    }

    // MARK: well-known

    static func fetchWellKnownSkill(base: String) throws -> FetchedSkill {
        var root = SkillAddressParser.trimSlash(base)
        if root.hasSuffix("/SKILL.md") { root = String(root.dropLast("/SKILL.md".count)) }
        let marker = "/.well-known/skills/"
        var indexRoot = root
        var skillDirName = ""
        if let r = root.range(of: marker) {
            indexRoot = String(root[root.startIndex..<r.lowerBound])
            skillDirName = String(root[r.upperBound...])
        }
        let indexBody = try get(indexRoot + "/" + SkillRegistryClient.indexPath)
        let entries = try SkillRegistryClient.parseWellKnownIndex(indexBody)
        let entry: SkillRegistryClient.IndexEntry?
        if skillDirName.isEmpty {
            entry = entries.count == 1 ? entries.first : nil
        } else {
            entry = entries.first { $0.name == skillDirName }
        }
        guard let chosen = entry else { throw SkillPanelError.noSkillsFound }
        var files: [String: Data] = [:]
        for f in chosen.files {
            if f.hasPrefix("/") || f.contains("..") { throw SkillPanelError.unsafePath(f) }
            files[f] = try get(indexRoot + "/" + SkillRegistryClient.indexPath
                               .replacingOccurrences(of: "/index.json", with: "")
                               + "/" + chosen.name + "/" + f)
        }
        guard let skillMd = files.first(where: { $0.key.lowercased() == "skill.md" })?.value,
              let text = String(data: skillMd, encoding: .utf8),
              let parsed = SkillFrontmatterIO.parse(text) else {
            throw SkillPanelError.missingFrontmatter
        }
        return FetchedSkill(name: parsed.name,
                            description: parsed.description,
                            files: files,
                            sourceLabel: URL(string: indexRoot)?.host ?? indexRoot,
                            sourceType: "well-known",
                            sourceUrl: indexRoot,
                            ref: nil,
                            path: chosen.name + "/SKILL.md")
    }

    static func get(_ urlString: String) throws -> Data {
        guard SkillRegistryClient.isSecure(urlString) else { throw SkillPanelError.insecureURL(urlString) }
        guard let url = URL(string: urlString) else { throw SkillPanelError.network(urlString) }
        let res = SkillTransport.fetch(URLRequest(url: url, timeoutInterval: 30))
        guard res.status == 200, let body = res.body else {
            throw SkillPanelError.network("HTTP " + String(res.status) + " " + urlString)
        }
        return body
    }

    // MARK: local

    /// A local directory bundle or a single SKILL.md file.
    static func readLocalSkill(_ path: String) -> FetchedSkill? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue {
            guard path.hasSuffix(".md"),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let text = String(data: data, encoding: .utf8),
                  let parsed = SkillFrontmatterIO.parse(text) else { return nil }
            return FetchedSkill(name: parsed.name, description: parsed.description,
                                files: ["SKILL.md": data],
                                sourceLabel: path, sourceType: "local", sourceUrl: path,
                                ref: nil, path: "")
        }
        let skillFile = SkillRoots.join(path, "SKILL.md")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: skillFile)),
              let text = String(data: data, encoding: .utf8),
              let parsed = SkillFrontmatterIO.parse(text) else { return nil }
        let files = readTree(path)
        return FetchedSkill(name: parsed.name, description: parsed.description,
                            files: files.isEmpty ? ["SKILL.md": data] : files,
                            sourceLabel: path, sourceType: "local", sourceUrl: path,
                            ref: nil, path: "SKILL.md")
    }

    // MARK: discovery

    /// Skills inside a fetched tree: root SKILL.md, then the usual skill dirs,
    /// then a bounded recursive scan (same shape the open skills CLI uses).
    static func discover(_ root: String, label: String, sourceType: String,
                         sourceUrl: String, ref: String?) -> [FetchedSkill] {
        var out: [FetchedSkill] = []
        var seen = Set<String>()
        let fm = FileManager.default
        func add(_ dir: String, rel: String) {
            let file = SkillRoots.join(dir, "SKILL.md")
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)),
                  let text = String(data: data, encoding: .utf8),
                  let parsed = SkillFrontmatterIO.parse(text) else { return }
            guard !seen.contains(parsed.name) else { return }
            seen.insert(parsed.name)
            let tree = readTree(dir)
            out.append(FetchedSkill(name: parsed.name,
                                    description: parsed.description,
                                    files: tree.isEmpty ? ["SKILL.md": data] : tree,
                                    sourceLabel: label,
                                    sourceType: sourceType,
                                    sourceUrl: sourceUrl,
                                    ref: ref,
                                    path: rel + "SKILL.md"))
        }
        if fm.fileExists(atPath: SkillRoots.join(root, "SKILL.md")) {
            add(root, rel: "")
            return out
        }
        let priority = ["skills", ".dsh/skills", ".agents/skills", "skill",
                        ".claude/skills", ".codex/skills", ".opencode/skills"]
        for sub in priority {
            let dir = SkillRoots.join(root, sub)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            for entry in (try? fm.contentsOfDirectory(atPath: dir))?.sorted() ?? [] {
                let skillDir = SkillRoots.join(dir, entry)
                var eIsDir: ObjCBool = false
                guard fm.fileExists(atPath: skillDir, isDirectory: &eIsDir), eIsDir.boolValue else { continue }
                add(skillDir, rel: sub + "/" + entry + "/")
            }
        }
        if out.isEmpty {
            for dir in walkForSkillDirs(root, depth: 0) { add(dir, rel: relative(dir, root)) }
        }
        return out
    }

    static func walkForSkillDirs(_ dir: String, depth: Int) -> [String] {
        guard depth <= 5 else { return [] }
        let fm = FileManager.default
        var out: [String] = []
        if fm.fileExists(atPath: SkillRoots.join(dir, "SKILL.md")) { out.append(dir) }
        for entry in (try? fm.contentsOfDirectory(atPath: dir))?.sorted() ?? [] {
            if skipDirs.contains(entry) || entry.hasPrefix(".") { continue }
            let full = SkillRoots.join(dir, entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }
            out += walkForSkillDirs(full, depth: depth + 1)
        }
        return out
    }

    static func relative(_ path: String, _ root: String) -> String {
        guard path.hasPrefix(root) else { return "" }
        var rel = String(path.dropFirst(root.count))
        if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
        return rel.isEmpty ? "" : rel + "/"
    }

    /// Read a skill directory into memory (hidden files skipped, bounded).
    static func readTree(_ dir: String) -> [String: Data] {
        var files: [String: Data] = [:]
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: dir) else { return files }
        for case let rel as String in en {
            if files.count >= maxFiles { break }
            if (rel as NSString).lastPathComponent.hasPrefix(".") { continue }
            if rel.split(separator: "/").contains(where: { skipDirs.contains(String($0)) }) { continue }
            let full = SkillRoots.join(dir, rel)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
            guard let attrs = try? fm.attributesOfItem(atPath: full),
                  let size = attrs[.size] as? Int, size <= maxFileBytes else { continue }
            if let data = try? Data(contentsOf: URL(fileURLWithPath: full)) {
                files[rel] = data
            }
        }
        return files
    }

    static func lastLines(_ text: String, count: Int = 2) -> String {
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return lines.suffix(count).joined(separator: " ")
    }
}

// MARK: - Install / remove

enum SkillInstallService {

    /// Levels a skill may be installed into (shared is external-tool owned).
    static func isInstallTarget(_ root: SkillRoot) -> Bool {
        root.level == .user || root.level == .project
    }

    static func install(_ skill: FetchedSkill,
                        into root: SkillRoot,
                        store: SkillStore,
                        overwrite: Bool = false) throws -> InstalledSkill {
        guard isInstallTarget(root) else { throw SkillPanelError.unsupportedTarget }
        guard SkillNameRule.isValid(skill.name) else { throw SkillPanelError.invalidName(skill.name) }
        let fm = FileManager.default
        let dest = SkillRoots.join(root.path, skill.name)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dest, isDirectory: &isDir) {
            if SkillScanner.isBuiltinDirectory(name: skill.name, dir: dest, root: root, fm: fm) {
                throw SkillPanelError.builtinProtected
            }
            guard overwrite else { throw SkillPanelError.targetExists(dest) }
            try? fm.removeItem(atPath: dest)
        }
        for (rel, data) in skill.files {
            if rel.hasPrefix("/") || rel.contains("..") { throw SkillPanelError.unsafePath(rel) }
            let full = SkillRoots.join(dest, rel)
            try fm.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: full), options: .atomic)
        }
        let skillFile = SkillRoots.join(dest, "SKILL.md")
        guard let text = try? String(contentsOfFile: skillFile, encoding: .utf8),
              let parsed = SkillFrontmatterIO.parse(text) else {
            throw SkillPanelError.missingFrontmatter
        }
        let existing = store.installRecord(skill.name)
        let record = SkillInstallRecord(source: skill.sourceLabel,
                                        sourceType: skill.sourceType,
                                        sourceUrl: skill.sourceUrl,
                                        ref: skill.ref,
                                        path: skill.path,
                                        level: root.level.rawValue,
                                        baseUserInvocable: parsed.userInvocable,
                                        baseDisableModelInvocation: parsed.disableModelInvocation,
                                        contentHash: SkillStore.contentHash(text),
                                        installedAt: existing?.installedAt ?? SkillStore.now(),
                                        updatedAt: SkillStore.now())
        store.setInstallRecord(record, name: skill.name)
        // Replay the user's flag choice if they had set one before.
        if let inv = store.invocationRecord(skill.name) {
            _ = try? applyInvocationFile(skillFile: skillFile,
                                         baseline: (inv.baselineUserInvocable, inv.baselineDisableModelInvocation),
                                         userInvocable: inv.userInvocable,
                                         disableModelInvocation: inv.disableModelInvocation)
        }
        store.save()
        if let scanned = rescanned(name: skill.name, root: root) { return scanned }
        return InstalledSkill(name: skill.name, description: parsed.description,
                              skillFile: skillFile, dir: dest, root: root, level: root.level,
                              userInvocable: parsed.effectiveUserInvocable,
                              modelInvocable: parsed.effectiveModelInvocable,
                              rawUserInvocable: parsed.userInvocable,
                              rawDisableModelInvocation: parsed.disableModelInvocation,
                              shadowedBy: nil, extraFiles: max(0, skill.files.count - 1))
    }

    /// Manual import: a local directory bundle or a single SKILL.md.
    static func importLocal(path: String, into root: SkillRoot, store: SkillStore,
                            overwrite: Bool = false) throws -> InstalledSkill {
        guard let fetched = SkillFetcher.readLocalSkill(path) else {
            throw SkillPanelError.noSkillsFound
        }
        return try install(fetched, into: root, store: store, overwrite: overwrite)
    }

    static func remove(_ skill: InstalledSkill, store: SkillStore) throws {
        switch skill.level {
        case .builtin: throw SkillPanelError.builtinReadOnly
        case .shared: throw SkillPanelError.sharedNotRemovable
        case .user, .project: break
        }
        do {
            try FileManager.default.removeItem(atPath: skill.dir)
        } catch {
            throw SkillPanelError.io(error.localizedDescription)
        }
        store.clearRecords(skill.name)
        store.save()
    }

    /// Set the two invocation flags. Values equal to the file's baseline remove
    /// the key again, so toggling back restores the original bytes.
    @discardableResult
    static func applyInvocation(_ skill: InstalledSkill,
                                userInvocable: Bool,
                                disableModelInvocation: Bool,
                                store: SkillStore) throws -> InstalledSkill {
        guard skill.canEditInvocation else { throw SkillPanelError.builtinReadOnly }
        // NOTE: optional chaining flattens SkillInvocationRecord?`s nested
        // optionals, so a record whose baseline is nil would silently fall back
        // to the file's CURRENT value. Branch explicitly instead.
        let baseline: (Bool?, Bool?)
        if let existing = store.invocationRecord(skill.name) {
            baseline = (existing.baselineUserInvocable, existing.baselineDisableModelInvocation)
        } else {
            baseline = (skill.rawUserInvocable, skill.rawDisableModelInvocation)
        }
        _ = try applyInvocationFile(skillFile: skill.skillFile,
                                    baseline: baseline,
                                    userInvocable: userInvocable,
                                    disableModelInvocation: disableModelInvocation)
        store.setInvocationRecord(SkillInvocationRecord(baselineUserInvocable: baseline.0,
                                                        baselineDisableModelInvocation: baseline.1,
                                                        userInvocable: userInvocable,
                                                        disableModelInvocation: disableModelInvocation,
                                                        updatedAt: SkillStore.now()),
                                  name: skill.name)
        store.save()
        return rescanned(name: skill.name, root: skill.root) ?? skill
    }

    /// Returns true when the file content changed.
    @discardableResult
    static func applyInvocationFile(skillFile: String,
                                    baseline: (Bool?, Bool?),
                                    userInvocable: Bool,
                                    disableModelInvocation: Bool) throws -> Bool {
        guard let text = try? String(contentsOfFile: skillFile, encoding: .utf8) else {
            throw SkillPanelError.io(skillFile)
        }
        guard SkillFrontmatterIO.parse(text) != nil else { throw SkillPanelError.missingFrontmatter }
        let uiKey: Bool? = (userInvocable == (baseline.0 ?? true)) ? nil : userInvocable
        let dmiKey: Bool? = (disableModelInvocation == (baseline.1 ?? false)) ? nil : disableModelInvocation
        let updated = try SkillFrontmatterIO.settingInvocation(text,
                                                              userInvocable: uiKey,
                                                              disableModelInvocation: dmiKey)
        guard updated != text else { return false }
        try updated.write(toFile: skillFile, atomically: true, encoding: .utf8)
        return true
    }

    static func rescanned(name: String, root: SkillRoot) -> InstalledSkill? {
        SkillScanner.scan([root]).first { $0.name == name }
    }
}
