import Foundation

/// Which branch the one checked out was started from.
///
/// Git keeps no record of the branch a commit was made on: a branch names a
/// commit, and its history is everything behind it — the commits of the
/// branch it was started on included. So the base is worked out, the way
/// branch tools do when nothing was written down:
///
/// 1. The branch's own creation record, when it names one. `git checkout -b
///    a b` writes "Created from b"; `git checkout -b a` alone writes
///    "Created from HEAD", which names nothing.
/// 2. Otherwise the nearest other branch, local or remote: the one the branch
///    is fewest commits ahead of. These do not count:
///    - the branch itself, and its namesakes on the remotes;
///    - one created after the branch was — it was started from the branch,
///      not the other way round;
///    - one already holding all of the branch, unless its creation record
///      says it is the older one: a branch with no commits of its own yet;
///    - one that meets the branch off the branch's own line of first parents
///      — it was merged in, not started from.
///    At the same distance a local branch goes before its copy on a remote,
///    the default branch before the rest, and an older branch before a
///    younger one: siblings started from one commit share a distance, and
///    the branch they were all started from is the oldest of them.
///
/// The default branch is the trunk, not started from anything: it has none.
extension GitService {
    struct BranchBase: Equatable {
        /// As the reader knows it: `b`, or `origin/b` for a remote one.
        let name: String
        /// Full IDs of the branch's own commits — the ones the base does not
        /// reach. Every other commit in its history came with the base.
        let ownCommits: Set<String>
    }

    /// A branch further than this ahead of the nearest other one is not off
    /// it in any sense worth drawing, and listing its own commits would be
    /// unbounded.
    static var branchBaseMaximumDistance = 5000
    /// Each candidate past the creation records costs a `merge-base`; a
    /// repository full of merged branches must not cost one per branch.
    private static let branchBaseMaximumChecks = 10

    private struct BaseCandidate {
        let ref: String
        let name: String
        let isRemote: Bool
        /// The branch's commits this one does not reach.
        let behind: Int
    }

    static func branchBase(in directory: URL) -> BranchBase? {
        // Where the reflogs are, and the branch checked out; nothing for a
        // detached HEAD or a branch with no commits.
        let head = run(["rev-parse", "--git-common-dir", "--symbolic-full-name", "HEAD"],
                       in: directory)
        guard head.code == 0 else { return nil }
        let lines = head.out.split(separator: "\n").map(String.init)
        guard lines.count == 2, lines[1].hasPrefix("refs/heads/") else { return nil }
        let commonDirectory = URL(fileURLWithPath: lines[0], relativeTo: directory)
            .standardizedFileURL
        let currentRef = lines[1]
        let current = String(currentRef.dropFirst("refs/heads/".count))

        let refs = branchRefs(in: directory)
        // The remote's own HEAD names the default branch; failing that, the
        // usual names for one.
        let remoteHeads = refs.filter { $0.symref.hasPrefix("refs/remotes/") }
        let remoteDefault = (remoteHeads.first { $0.ref == "refs/remotes/origin/HEAD" }
                             ?? remoteHeads.first).map { remoteBranchName($0.symref) }
        let defaultName = remoteDefault ?? ["main", "master", "trunk"].first { name in
            refs.contains { $0.ref == "refs/heads/\(name)" }
        }
        guard current != defaultName else { return nil }

        var candidates: [BaseCandidate] = []
        for entry in refs where entry.symref.isEmpty && entry.ref != currentRef {
            guard let behind = entry.behind else { continue }
            if entry.ref.hasPrefix("refs/remotes/") {
                // The branch's own copy on a remote is the branch, not a base.
                guard remoteBranchName(entry.ref) != current else { continue }
                candidates.append(BaseCandidate(ref: entry.ref,
                                                name: String(entry.ref.dropFirst(13)),
                                                isRemote: true, behind: behind))
            } else if entry.ref.hasPrefix("refs/heads/") {
                candidates.append(BaseCandidate(ref: entry.ref,
                                                name: String(entry.ref.dropFirst(11)),
                                                isRemote: false, behind: behind))
            }
        }
        // Creation records exist for local branches only — a remote one is
        // made by a fetch — and each is the first line of a small file.
        var creations: [String: (time: Int, from: String)] = [:]
        for candidate in candidates where !candidate.isRemote {
            creations[candidate.ref] = creationRecord(of: candidate.ref, in: commonDirectory)
        }
        candidates.sort { left, right in
            if left.behind != right.behind { return left.behind < right.behind }
            if left.isRemote != right.isRemote { return !left.isRemote }
            let leftDefault = left.name == defaultName, rightDefault = right.name == defaultName
            if leftDefault != rightDefault { return leftDefault }
            let leftTime = creations[left.ref]?.time ?? .max
            let rightTime = creations[right.ref]?.time ?? .max
            if leftTime != rightTime { return leftTime < rightTime }
            return left.name < right.name
        }

        let currentCreation = creationRecord(of: currentRef, in: commonDirectory)
        // The creation record's start, as the branch the reader knows.
        let named: BaseCandidate? = currentCreation.flatMap { record in
            var from = record.from
            for prefix in ["refs/heads/", "refs/remotes/"] where from.hasPrefix(prefix) {
                from = String(from.dropFirst(prefix.count))
            }
            return candidates.first { $0.name == from }
        }

        /// The branch's first parents, read as deep as a check has needed.
        var line: Set<String> = []
        var lineDepth = 0
        func onLine(_ commit: String, within depth: Int) -> Bool {
            if depth + 1 > lineDepth {
                lineDepth = depth + 1
                let read = run(["rev-list", "--first-parent", "-n", "\(lineDepth)", "HEAD"],
                               in: directory)
                guard read.code == 0 else { return false }
                line = Set(read.out.split(separator: "\n").map(String.init))
            }
            return line.contains(commit)
        }
        func ownCommits(against candidate: BaseCandidate) -> BranchBase? {
            let own = run(["rev-list", "HEAD", "--not", candidate.ref], in: directory)
            guard own.code == 0 else { return nil }
            return BranchBase(name: candidate.name,
                              ownCommits: Set(own.out.split(separator: "\n").map(String.init)))
        }

        if let named, named.behind <= branchBaseMaximumDistance,
           run(["merge-base", "HEAD", named.ref], in: directory).code == 0 {
            return ownCommits(against: named)
        }
        var checks = 0
        for candidate in candidates where candidate.ref != named?.ref {
            // Sorted nearest first: the rest are further still.
            guard candidate.behind <= branchBaseMaximumDistance,
                  checks < branchBaseMaximumChecks else { break }
            let theirs = creations[candidate.ref]
            if let mine = currentCreation, let theirs, theirs.time > mine.time { continue }
            if candidate.behind == 0 {
                guard let mine = currentCreation, let theirs, theirs.time < mine.time else {
                    continue
                }
            }
            checks += 1
            let meeting = run(["merge-base", "HEAD", candidate.ref], in: directory)
            guard meeting.code == 0 else { continue }
            let commit = meeting.out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard onLine(commit, within: candidate.behind) else { continue }
            return ownCommits(against: candidate)
        }
        return nil
    }

    /// Every branch, local and remote, with how many of HEAD's commits it does
    /// not reach — nil where that could not be counted.
    private static func branchRefs(in directory: URL)
        -> [(ref: String, symref: String, behind: Int?)] {
        // One pass for every branch where Git can count them all at once
        // (2.41 and later).
        let counted = run(["for-each-ref",
                           "--format=%(refname)%00%(symref)%00%(ahead-behind:HEAD)",
                           "refs/heads", "refs/remotes"], in: directory)
        if counted.code == 0 {
            return counted.out.split(separator: "\n").compactMap { line in
                let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
                guard fields.count == 3 else { return nil }
                let counts = fields[2].split(separator: " ")
                return (String(fields[0]), String(fields[1]),
                        counts.count == 2 ? Int(counts[1]) : nil)
            }
        }
        // An older Git counts one branch at a time, so only as many as a
        // repository's working branches come to — local ones first.
        let listed = run(["for-each-ref", "--format=%(refname)%00%(symref)",
                          "refs/heads", "refs/remotes"], in: directory)
        guard listed.code == 0 else { return [] }
        var countedSoFar = 0
        return listed.out.split(separator: "\n").compactMap { line -> (String, String)? in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard fields.count == 2 else { return nil }
            return (String(fields[0]), String(fields[1]))
        }
        .sorted { $0.0.hasPrefix("refs/heads/") && !$1.0.hasPrefix("refs/heads/") }
        .map { ref, symref -> (ref: String, symref: String, behind: Int?) in
            guard symref.isEmpty, countedSoFar < 64 else { return (ref, symref, nil) }
            countedSoFar += 1
            let count = run(["rev-list", "--count", "HEAD", "--not", ref], in: directory)
            let behind = count.code == 0
                ? Int(count.out.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
            return (ref, symref, behind)
        }
    }

    /// `refs/remotes/origin/feature/x` → `feature/x`.
    private static func remoteBranchName(_ ref: String) -> String {
        let path = ref.dropFirst("refs/remotes/".count)
        guard let slash = path.firstIndex(of: "/") else { return String(path) }
        return String(path[path.index(after: slash)...])
    }

    /// When a branch was created and what from, from the first line of its
    /// reflog — nil when that line is not the creation (the reflog was
    /// pruned, or the ref came from a clone or a fetch).
    private static func creationRecord(of ref: String,
                                       in commonDirectory: URL) -> (time: Int, from: String)? {
        let url = commonDirectory.appendingPathComponent("logs")
            .appendingPathComponent(ref)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096),
              let first = String(decoding: data, as: UTF8.self)
                .split(separator: "\n", maxSplits: 1).first,
              let tab = first.firstIndex(of: "\t") else { return nil }
        let message = first[first.index(after: tab)...]
        let prefix = "branch: Created from "
        guard message.hasPrefix(prefix) else { return nil }
        // "<old> <new> <name> <email> <seconds> <zone>"
        let fields = first[..<tab].split(separator: " ")
        guard fields.count >= 2, let time = Int(fields[fields.count - 2]) else { return nil }
        return (time, String(message.dropFirst(prefix.count)))
    }
}
