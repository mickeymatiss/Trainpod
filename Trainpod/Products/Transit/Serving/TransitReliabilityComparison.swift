import Foundation

struct TransitReliabilityComparison {
    let requestId: UUID
    let systemId: TransitSystemID
    let stationIds: [String]
    let comparedAt: Date
    let rows: [ArrivalComparisonRow]
    let summary: ArrivalComparisonSummary
    let cloudSourceAgeSeconds: Int?
    let cloudError: String?
    let legacyError: String?
    let legacyCompletedAt: Date?
    let cloudCompletedAt: Date?
    let fallbackUsed: Bool
}
