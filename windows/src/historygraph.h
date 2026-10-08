// A top-to-bottom lane layout for a topologically ordered Git log, and how a
// row of it is painted (GitHistoryGraph + GitHistoryGraphDrawing).
#pragma once

#include "gitservice.h"
#include "render.h"

struct HistoryGraph {
    struct Lane {
        int lane = 0;
        int colorIndex = 0;
        std::string targetHash;
    };
    struct Segment {
        int fromLane = 0;
        int toLane = 0;
        /// Normalised row coordinates: top = 0, commit = 0.5, bottom = 1.
        double fromY = 0;
        double toY = 0;
        int colorIndex = 0;
    };
    struct Row {
        int nodeLane = 0;
        int colorIndex = 0;
        bool isMerge = false;
        bool isHead = false;
        std::vector<Segment> segments;
        std::vector<Lane> topLanes;
        /// Lanes continued through any expanded file rows.
        std::vector<Lane> bottomLanes;
    };

    std::vector<Row> rows;
    int laneCount = 0;

    HistoryGraph(const std::vector<Git::Commit>& commits,
                 const std::optional<std::string>& preferredTrunkID = std::nullopt);
};

namespace HistoryGraphDrawing {
constexpr float laneSpacing = 16;
constexpr float trailingGap = 15;
inline float columnWidth(int laneCount) {
    return laneCount > 0 ? laneCount * laneSpacing + trailingGap : 0;
}
void draw(Graphics& g, const HistoryGraph::Row& row, const Rect& rect);
/// File rows extend the tracks leaving their commit.
void drawContinuation(Graphics& g, const std::vector<HistoryGraph::Lane>& lanes, const Rect& rect);
}  // namespace HistoryGraphDrawing

/// Compact ref pills drawn inline in a history row.
namespace RefLabelsDrawing {
constexpr float gap = 4;
constexpr float horizontalPadding = 5;
constexpr float height = 16;
/// What a pill says. The checked-out branch's copy on a remote says only the
/// remote — `origin`, not `origin/feature/x` — since which branch it copies
/// goes without saying.
std::wstring text(const Git::RefLabel& ref, const std::string& currentBranch);
float width(const std::vector<Git::RefLabel>& refs, const std::string& currentBranch = "");
/// Returns the rectangles actually painted.
std::vector<Rect> draw(Graphics& g, const std::vector<Git::RefLabel>& refs, const Rect& rect,
                       const Color& currentColor, const std::string& currentBranch = "");
}  // namespace RefLabelsDrawing
