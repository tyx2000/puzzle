import Foundation

/// A top-to-bottom layout for a topologically ordered Git log. Keeping pending
/// parents at the bottom of each row makes the result independent of the number
/// of commits loaded, including parents beyond the current history page.
struct GitHistoryGraph: Equatable {
    struct Lane: Equatable {
        let lane: Int
        let colorIndex: Int
        let targetHash: String
    }

    struct Segment: Equatable {
        let fromLane: Int
        let toLane: Int
        /// Normalized row coordinates: top = 0, commit = 0.5, bottom = 1.
        let fromY: Double
        let toY: Double
        let colorIndex: Int
    }

    struct Row: Equatable {
        let nodeLane: Int
        let colorIndex: Int
        let isMerge: Bool
        let isHead: Bool
        let segments: [Segment]
        let topLanes: [Lane]
        /// Continue these lanes vertically through any expanded file rows.
        let bottomLanes: [Lane]
    }

    let rows: [Row]
    let laneCount: Int

    init(commits: [GitService.Commit], preferredTrunkID suppliedTrunkID: String? = nil) {
        struct PendingLane {
            let targetHash: String
            let colorIndex: Int
        }

        // The default branch owns the long-lived left lane even when a newer
        // feature tip sorts above it. Git does not record which branch a
        // commit was originally made on, but the remote HEAD (or the usual
        // local trunk names) gives us a stable owner for shared ancestry.
        let inferredTrunkID = commits.first(where: { commit in
            commit.refs.split(separator: ",").contains { raw in
                let ref = raw.trimmingCharacters(in: .whitespaces)
                return ref.hasSuffix("/HEAD") || ref.contains("/HEAD -> ")
            }
        })?.graphID ?? commits.first(where: { commit in
            commit.refs.split(separator: ",").contains { raw in
                let ref = raw.trimmingCharacters(in: .whitespaces)
                guard !ref.hasPrefix("tag: ") else { return false }
                let name = ref.hasPrefix("HEAD -> ") ? String(ref.dropFirst(8)) : ref
                return ["main", "master", "trunk", "develop"].contains(name)
            }
        })?.graphID
        let preferredTrunkID = suppliedTrunkID ?? inferredTrunkID
        var waitingForTrunkTip = preferredTrunkID != nil

        // Slots are stable while their ancestry is still active. Keeping holes
        // avoids sliding a surviving branch into the column of a sibling that
        // just ended, which made commits from two split branches appear on one
        // line. Holes are reused only for a newly introduced path.
        var pending: [PendingLane?] = preferredTrunkID == nil ? [] : [nil]
        var nextColorIndex = preferredTrunkID == nil ? 0 : 1
        var rows: [Row] = []
        rows.reserveCapacity(commits.count)
        var laneCount = 0

        func snapshot(_ lanes: [PendingLane?]) -> [Lane] {
            lanes.enumerated().compactMap { index, lane in
                lane.map {
                    Lane(lane: index, colorIndex: $0.colorIndex,
                         targetHash: $0.targetHash)
                }
            }
        }

        func laneIndex(of target: String, in lanes: [PendingLane?]) -> Int? {
            lanes.firstIndex { $0?.targetHash == target }
        }

        func firstFreeLane(after lane: Int, in lanes: [PendingLane?]) -> Int {
            guard lane + 1 < lanes.count else { return lanes.count }
            return ((lane + 1)..<lanes.count).first { lanes[$0] == nil } ?? lanes.count
        }

        func trimUnusedTrailingLanes() {
            while let last = pending.last, last == nil { pending.removeLast() }
        }

        for commit in commits {
            let top = pending
            let existingLane = laneIndex(of: commit.graphID, in: top)
            let isTrunkTip = commit.graphID == preferredTrunkID
            let reusableLane = pending.indices.first { index in
                pending[index] == nil && !(waitingForTrunkTip && index == 0)
            }
            let nodeLane = isTrunkTip ? 0 : (existingLane ?? reusableLane ?? pending.count)
            let nodeColor: Int
            if isTrunkTip {
                nodeColor = 0
                if let existingLane { pending[existingLane] = nil }
                waitingForTrunkTip = false
            } else if let existingLane {
                nodeColor = top[existingLane]!.colorIndex
                pending[existingLane] = nil
            } else {
                nodeColor = nextColorIndex
                nextColorIndex += 1
                if nodeLane == pending.count { pending.append(nil) }
            }

            // First parents continue the current branch. When a secondary
            // branch reached the same ancestor earlier on the right, fold it
            // into this track instead of moving the mainline right and giving
            // it the secondary branch's color. Targets to the left keep their
            // existing track, so a side branch still rejoins the mainline.
            var seenParents: Set<String> = []
            let parents = commit.parents.filter {
                !$0.isEmpty && $0 != commit.graphID && seenParents.insert($0).inserted
            }
            for (parentIndex, parent) in parents.enumerated() {
                if let pendingIndex = laneIndex(of: parent, in: pending) {
                    if parentIndex == 0,
                       let topIndex = laneIndex(of: parent, in: top),
                       topIndex > nodeLane {
                        // The first-parent path owns the current branch's lane;
                        // the right-hand reservation converges into it.
                        pending[pendingIndex] = nil
                        pending[nodeLane] = PendingLane(targetHash: parent,
                                                        colorIndex: nodeColor)
                    }
                    continue
                }
                let colorIndex: Int
                if parentIndex == 0 {
                    colorIndex = nodeColor
                } else {
                    colorIndex = nextColorIndex
                    nextColorIndex += 1
                }
                let parentLane = parentIndex == 0
                    ? nodeLane
                    : firstFreeLane(after: nodeLane, in: pending)
                if parentLane == pending.count { pending.append(nil) }
                pending[parentLane] = PendingLane(targetHash: parent,
                                                  colorIndex: colorIndex)
            }

            var segments: [Segment] = []
            segments.reserveCapacity(top.count * 2 + parents.count)
            for (index, lane) in top.enumerated() {
                guard let lane else { continue }
                if index == existingLane {
                    segments.append(Segment(fromLane: index, toLane: nodeLane,
                                            fromY: 0, toY: 0.5,
                                            colorIndex: lane.colorIndex))
                } else if let bottomIndex = laneIndex(of: lane.targetHash, in: pending) {
                    if index == bottomIndex {
                        segments.append(Segment(fromLane: index, toLane: index,
                                                fromY: 0, toY: 1,
                                                colorIndex: lane.colorIndex))
                    } else {
                        // Only a real convergence moves an active path. Keep
                        // the bend below the node so it never cuts through it.
                        segments.append(Segment(fromLane: index, toLane: index,
                                                fromY: 0, toY: 0.5,
                                                colorIndex: lane.colorIndex))
                        segments.append(Segment(fromLane: index, toLane: bottomIndex,
                                                fromY: 0.5, toY: 1,
                                                colorIndex: lane.colorIndex))
                    }
                }
            }

            for (parentIndex, parent) in parents.enumerated() {
                guard let index = laneIndex(of: parent, in: pending),
                      let parentLane = pending[index] else {
                    continue
                }
                segments.append(Segment(fromLane: nodeLane, toLane: index,
                                        fromY: 0.5, toY: 1,
                                        colorIndex: parentIndex == 0
                                            ? nodeColor : parentLane.colorIndex))
            }

            trimUnusedTrailingLanes()

            let isHead = commit.refs.split(separator: ",").contains {
                let ref = $0.trimmingCharacters(in: .whitespaces)
                return ref == "HEAD" || ref.hasPrefix("HEAD -> ")
            }
            rows.append(Row(nodeLane: nodeLane, colorIndex: nodeColor,
                            isMerge: parents.count > 1, isHead: isHead,
                            segments: segments, topLanes: snapshot(top),
                            bottomLanes: snapshot(pending)))
            laneCount = max(laneCount, max(nodeLane + 1, pending.count))
        }

        self.rows = rows
        self.laneCount = laneCount
    }
}
