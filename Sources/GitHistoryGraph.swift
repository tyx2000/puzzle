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

    init(commits: [GitService.Commit]) {
        struct PendingLane {
            let targetHash: String
            let colorIndex: Int
        }

        var pending: [PendingLane] = []
        var nextColorIndex = 0
        var rows: [Row] = []
        rows.reserveCapacity(commits.count)
        var laneCount = 0

        func snapshot(_ lanes: [PendingLane]) -> [Lane] {
            lanes.enumerated().map { index, lane in
                Lane(lane: index, colorIndex: lane.colorIndex, targetHash: lane.targetHash)
            }
        }

        for commit in commits {
            let top = pending
            let existingLane = top.firstIndex { $0.targetHash == commit.graphID }
            let nodeLane = existingLane ?? top.count
            let nodeColor: Int
            if let existingLane {
                nodeColor = top[existingLane].colorIndex
                pending.remove(at: existingLane)
            } else {
                nodeColor = nextColorIndex
                nextColorIndex += 1
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
            var insertionIndex = min(nodeLane, pending.count)
            for (parentIndex, parent) in parents.enumerated() {
                if let pendingIndex = pending.firstIndex(where: { $0.targetHash == parent }) {
                    if parentIndex == 0,
                       let topIndex = top.firstIndex(where: { $0.targetHash == parent }),
                       topIndex > nodeLane {
                        pending.remove(at: pendingIndex)
                        let continuationIndex = min(nodeLane, pending.count)
                        pending.insert(PendingLane(targetHash: parent, colorIndex: nodeColor),
                                       at: continuationIndex)
                        insertionIndex = continuationIndex + 1
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
                pending.insert(PendingLane(targetHash: parent, colorIndex: colorIndex),
                               at: insertionIndex)
                insertionIndex += 1
            }

            var segments: [Segment] = []
            segments.reserveCapacity(top.count * 2 + parents.count)
            for (index, lane) in top.enumerated() {
                if index == existingLane {
                    segments.append(Segment(fromLane: index, toLane: nodeLane,
                                            fromY: 0, toY: 0.5, colorIndex: nodeColor))
                } else if let bottomIndex = pending.firstIndex(where: {
                    $0.targetHash == lane.targetHash
                }) {
                    if index == bottomIndex {
                        segments.append(Segment(fromLane: index, toLane: index,
                                                fromY: 0, toY: 1,
                                                colorIndex: lane.colorIndex))
                    } else {
                        // Delay compaction until below the commit node, so a
                        // passing branch never cuts through that node.
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
                guard let index = pending.firstIndex(where: { $0.targetHash == parent }) else {
                    continue
                }
                segments.append(Segment(fromLane: nodeLane, toLane: index,
                                        fromY: 0.5, toY: 1,
                                        colorIndex: parentIndex == 0
                                            ? nodeColor : pending[index].colorIndex))
            }

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
