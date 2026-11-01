/// Reciprocal rank fusion (Cormack et al., 2009).
///
/// Each input list is ordered best first. A document's fused score is the sum over
/// lists of 1 / (k + rank), with rank starting at 1. k = 60 is the standard constant;
/// it damps the advantage of the very top ranks so one retriever cannot dominate.
/// Ties keep the order in which documents were first seen.
public func reciprocalRankFusion<ID: Hashable>(_ rankings: [[ID]], k: Double = 60) -> [(id: ID, score: Double)] {
    var scores: [ID: Double] = [:]
    var firstSeen: [ID: Int] = [:]
    var order = 0
    for ranking in rankings {
        var seenInList = Set<ID>()
        for (offset, id) in ranking.enumerated() where seenInList.insert(id).inserted {
            scores[id, default: 0] += 1 / (k + Double(offset + 1))
            if firstSeen[id] == nil {
                firstSeen[id] = order
                order += 1
            }
        }
    }
    return scores
        .map { (id: $0.key, score: $0.value) }
        .sorted { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : firstSeen[lhs.id]! < firstSeen[rhs.id]!
        }
}
