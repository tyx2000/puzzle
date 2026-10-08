#include "historygraph.h"

#include "theme.h"

#include <d2d1_1helper.h>

HistoryGraph::HistoryGraph(const std::vector<Git::Commit>& commits,
                           const std::optional<std::string>& suppliedTrunkID) {
    struct PendingLane {
        std::string targetHash;
        int colorIndex = 0;
    };
    using Slot = std::optional<PendingLane>;

    // The default branch owns the long-lived left lane even when a newer
    // feature tip sorts above it.
    std::optional<std::string> inferredTrunkID;
    for (auto& commit : commits) {
        bool found = false;
        for (auto& raw : split(commit.refs, ',')) {
            std::string ref = trim(raw);
            if (endsWith(ref, "/HEAD") || contains(ref, "/HEAD -> ")) found = true;
        }
        if (found) {
            inferredTrunkID = commit.graphID();
            break;
        }
    }
    if (!inferredTrunkID) {
        for (auto& commit : commits) {
            bool found = false;
            for (auto& raw : split(commit.refs, ',')) {
                std::string ref = trim(raw);
                if (startsWith(ref, "tag: ")) continue;
                std::string name = startsWith(ref, "HEAD -> ") ? ref.substr(8) : ref;
                if (name == "main" || name == "master" || name == "trunk" || name == "develop") found = true;
            }
            if (found) {
                inferredTrunkID = commit.graphID();
                break;
            }
        }
    }
    std::optional<std::string> preferredTrunkID = suppliedTrunkID ? suppliedTrunkID : inferredTrunkID;
    bool waitingForTrunkTip = preferredTrunkID.has_value();

    std::vector<Slot> pending;
    if (preferredTrunkID) pending.push_back(std::nullopt);
    int nextColorIndex = preferredTrunkID ? 1 : 0;
    rows.reserve(commits.size());

    auto snapshot = [](const std::vector<Slot>& lanes) {
        std::vector<Lane> out;
        for (size_t i = 0; i < lanes.size(); ++i) {
            if (lanes[i]) out.push_back(Lane{(int)i, lanes[i]->colorIndex, lanes[i]->targetHash});
        }
        return out;
    };
    auto laneIndex = [](const std::string& target, const std::vector<Slot>& lanes) -> int {
        for (size_t i = 0; i < lanes.size(); ++i) {
            if (lanes[i] && lanes[i]->targetHash == target) return (int)i;
        }
        return -1;
    };
    auto firstFreeLane = [](int lane, const std::vector<Slot>& lanes) -> int {
        if (lane + 1 >= (int)lanes.size()) return (int)lanes.size();
        for (int i = lane + 1; i < (int)lanes.size(); ++i) {
            if (!lanes[i]) return i;
        }
        return (int)lanes.size();
    };

    for (auto& commit : commits) {
        const std::string& id = commit.graphID();
        std::vector<Slot> top = pending;
        int existingLane = laneIndex(id, top);
        bool isTrunkTip = preferredTrunkID && id == *preferredTrunkID;
        int reusableLane = -1;
        for (size_t i = 0; i < pending.size(); ++i) {
            if (!pending[i] && !(waitingForTrunkTip && i == 0)) {
                reusableLane = (int)i;
                break;
            }
        }
        int nodeLane = isTrunkTip ? 0
            : existingLane >= 0   ? existingLane
            : reusableLane >= 0   ? reusableLane
                                  : (int)pending.size();
        int nodeColor;
        if (isTrunkTip) {
            nodeColor = 0;
            if (existingLane >= 0) pending[existingLane] = std::nullopt;
            waitingForTrunkTip = false;
        } else if (existingLane >= 0) {
            nodeColor = top[existingLane]->colorIndex;
            pending[existingLane] = std::nullopt;
        } else {
            nodeColor = nextColorIndex++;
            if (nodeLane == (int)pending.size()) pending.push_back(std::nullopt);
        }

        std::set<std::string> seenParents;
        std::vector<std::string> parents;
        for (auto& parent : commit.parents) {
            if (parent.empty() || parent == id) continue;
            if (seenParents.insert(parent).second) parents.push_back(parent);
        }
        for (size_t parentIndex = 0; parentIndex < parents.size(); ++parentIndex) {
            const std::string& parent = parents[parentIndex];
            int pendingIndex = laneIndex(parent, pending);
            if (pendingIndex >= 0) {
                int topIndex = laneIndex(parent, top);
                if (parentIndex == 0 && topIndex >= 0 && topIndex > nodeLane) {
                    // The first-parent path owns the current branch's lane;
                    // the right-hand reservation converges into it.
                    pending[pendingIndex] = std::nullopt;
                    while ((int)pending.size() <= nodeLane) pending.push_back(std::nullopt);
                    pending[nodeLane] = PendingLane{parent, nodeColor};
                }
                continue;
            }
            int colorIndex = parentIndex == 0 ? nodeColor : nextColorIndex++;
            int parentLane = parentIndex == 0 ? nodeLane : firstFreeLane(nodeLane, pending);
            while ((int)pending.size() <= parentLane) pending.push_back(std::nullopt);
            pending[parentLane] = PendingLane{parent, colorIndex};
        }

        std::vector<Segment> segments;
        for (size_t index = 0; index < top.size(); ++index) {
            if (!top[index]) continue;
            const PendingLane& lane = *top[index];
            if ((int)index == existingLane) {
                segments.push_back(Segment{(int)index, nodeLane, 0, 0.5, lane.colorIndex});
            } else {
                int bottomIndex = laneIndex(lane.targetHash, pending);
                if (bottomIndex < 0) continue;
                if ((int)index == bottomIndex) {
                    segments.push_back(Segment{(int)index, (int)index, 0, 1, lane.colorIndex});
                } else {
                    // Only a real convergence moves an active path, bending
                    // below the node so it never cuts through it.
                    segments.push_back(Segment{(int)index, (int)index, 0, 0.5, lane.colorIndex});
                    segments.push_back(Segment{(int)index, bottomIndex, 0.5, 1, lane.colorIndex});
                }
            }
        }
        for (size_t parentIndex = 0; parentIndex < parents.size(); ++parentIndex) {
            int index = laneIndex(parents[parentIndex], pending);
            if (index < 0 || !pending[index]) continue;
            segments.push_back(Segment{nodeLane, index, 0.5, 1,
                                       parentIndex == 0 ? nodeColor : pending[index]->colorIndex});
        }

        while (!pending.empty() && !pending.back()) pending.pop_back();

        bool isHead = false;
        for (auto& raw : split(commit.refs, ',')) {
            std::string ref = trim(raw);
            if (ref == "HEAD" || startsWith(ref, "HEAD -> ")) isHead = true;
        }
        Row row;
        row.nodeLane = nodeLane;
        row.colorIndex = nodeColor;
        row.isMerge = parents.size() > 1;
        row.isHead = isHead;
        row.segments = std::move(segments);
        row.topLanes = snapshot(top);
        row.bottomLanes = snapshot(pending);
        rows.push_back(std::move(row));
        laneCount = std::max(laneCount, std::max(nodeLane + 1, (int)pending.size()));
    }
}

// ── Drawing ────────────────────────────────────────────────────────────────

namespace HistoryGraphDrawing {

namespace {
const Color& color(int index) { return Theme::gitGraphColors[((index % 6) + 6) % 6]; }
float laneX(int lane, const Rect& rect) { return rect.x + laneSpacing / 2 + lane * laneSpacing; }
}  // namespace

void draw(Graphics& g, const HistoryGraph::Row& row, const Rect& rect) {
    if (rect.isEmpty()) return;
    g.pushClip(rect);
    Point center(laneX(row.nodeLane, rect), rect.midY());
    // The node's interior stays clear so stripes and hover show through merge
    // dots and the HEAD ring.
    float hole = row.isHead ? 6 : 4.5f;
    Com<ID2D1RectangleGeometry> area;
    Com<ID2D1EllipseGeometry> node;
    Render::d2d()->CreateRectangleGeometry(D2D1::RectF(rect.x, rect.y, rect.maxX(), rect.maxY()),
                                           area.put());
    Render::d2d()->CreateEllipseGeometry(
        D2D1::Ellipse(D2D1::Point2F(center.x, center.y), hole, hole), node.put());
    ID2D1Geometry* parts[2] = {area.get(), node.get()};
    Com<ID2D1GeometryGroup> mask;
    Render::d2d()->CreateGeometryGroup(D2D1_FILL_MODE_ALTERNATE, parts, 2, mask.put());
    bool layered = false;
    if (mask) {
        D2D1_LAYER_PARAMETERS1 params = D2D1::LayerParameters1(
            D2D1::InfiniteRect(), mask.get(), D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
        g.context()->PushLayer(params, nullptr);
        layered = true;
    }
    for (auto& segment : row.segments) {
        Point start(laneX(segment.fromLane, rect), rect.y + (float)segment.fromY * rect.h);
        Point end(laneX(segment.toLane, rect), rect.y + (float)segment.toY * rect.h);
        if (segment.fromLane == segment.toLane) {
            g.line(start, end, color(segment.colorIndex), 2, true);
        } else {
            // Vertical tangents meet the adjoining rows without a kink.
            float middleY = (start.y + end.y) / 2;
            g.bezier(start, Point(start.x, middleY), Point(end.x, middleY), end,
                     color(segment.colorIndex), 2, true);
        }
    }
    if (layered) g.context()->PopLayer();
    const Color& nodeColor = color(row.colorIndex);
    auto circle = [&](float radius) {
        return Rect(center.x - radius, center.y - radius, radius * 2, radius * 2);
    };
    if (row.isHead) g.strokeEllipse(circle(5), nodeColor, 1.5f);
    if (row.isMerge) g.strokeEllipse(circle(3.2f), nodeColor, 1.8f);
    else g.fillEllipse(circle(3), nodeColor);
    g.popClip();
}

void drawContinuation(Graphics& g, const std::vector<HistoryGraph::Lane>& lanes, const Rect& rect) {
    if (rect.isEmpty()) return;
    g.pushClip(rect);
    for (auto& lane : lanes) {
        float x = laneX(lane.lane, rect);
        g.line(Point(x, rect.y), Point(x, rect.maxY()), color(lane.colorIndex), 2);
    }
    g.popClip();
}

}  // namespace HistoryGraphDrawing

namespace RefLabelsDrawing {

namespace {
Font labelFont() { return Theme::uiFont(9); }
}  // namespace

float width(const std::vector<Git::RefLabel>& refs) {
    float total = 0;
    for (size_t i = 0; i < refs.size(); ++i) {
        total += std::ceil(Text::width(W(refs[i].name), labelFont())) + horizontalPadding * 2;
        if (i) total += gap;
    }
    return total;
}

std::vector<Rect> draw(Graphics& g, const std::vector<Git::RefLabel>& refs, const Rect& rect,
                       const Color& currentColor) {
    std::vector<Rect> drawn;
    if (refs.empty() || rect.w <= 0) return drawn;
    float x = rect.x;
    for (auto& ref : refs) {
        if (x >= rect.maxX()) break;
        std::wstring name = W(ref.name);
        float natural = std::ceil(Text::width(name, labelFont())) + horizontalPadding * 2;
        float w = std::min(natural, rect.maxX() - x);
        if (w < horizontalPadding * 2 + 4) break;
        Rect pill(x, std::floor(rect.midY() - height / 2), w, height);
        Color tone;
        switch (ref.kind) {
        case Git::RefLabel::Kind::LocalBranch: tone = ref.isCurrent ? currentColor : Theme::blue; break;
        case Git::RefLabel::Kind::RemoteBranch: tone = Theme::purple; break;
        case Git::RefLabel::Kind::Tag: tone = Theme::yellow; break;
        case Git::RefLabel::Kind::DetachedHead: tone = Theme::orange; break;
        }
        g.fillRoundedRect(pill, 4, tone.withAlpha(0.14f));
        g.strokeRoundedRect(pill.inset(0.5f, 0.5f), 4, tone.withAlpha(0.7f), 1);
        g.text(name, labelFont(), tone, pill.inset(horizontalPadding, 0), LineBreak::TruncatingMiddle);
        drawn.push_back(pill);
        x = pill.maxX() + gap;
    }
    return drawn;
}

}  // namespace RefLabelsDrawing
