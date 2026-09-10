import Foundation

/// 요약이 시작되는 순간 고정하는 Whisper 세그먼트의 불변 복사본.
struct SummaryInputSegment: Sendable, Equatable {
  let id: Int
  let start: Double
  let end: Double
  let text: String
  let paragraph: Int?
  let boundaryAfter: TranscriptBoundary?
}

/// 사용자에게 하나의 강의 시간대로 보이는 상위 단위.
struct LectureUnit: Sendable, Equatable {
  let id: Int
  let start: Double
  let end: Double
  let segments: [SummaryInputSegment]
}

/// 컨텍스트 예산 때문에 하나의 강의 단위를 내부적으로 나눈 조각.
/// part는 사용자 출력에 노출하지 않는다.
struct LectureUnitChunk: Sendable, Equatable {
  let unitId: Int
  let partIndex: Int
  let partCount: Int
  let start: Double
  let end: Double
  let transcript: String
}

struct SummaryInsight: Sendable, Codable, Equatable {
  var point: String
  var explanation: String
}

struct SummaryTerm: Sendable, Codable, Equatable {
  var term: String
  var meaning: String
}

struct UnitSummary: Sendable, Codable, Equatable {
  var unitId: Int
  var title: String
  var summary: String
  var keyInsights: [SummaryInsight]
  var terms: [SummaryTerm]
}

struct LectureSummaryDocument: Sendable, Equatable {
  struct Entry: Sendable, Equatable {
    let unit: LectureUnit
    let summary: UnitSummary
  }

  let overview: String
  let units: [Entry]
}

struct UnitSummaryRequest: Sendable {
  let lectureTitle: String
  let unitId: Int
  let unitCount: Int
  let partIndex: Int
  let partCount: Int
  let start: Double
  let end: Double
  let transcript: String
  let glossary: String
}

struct UnitMergeRequest: Sendable {
  let lectureTitle: String
  let unitId: Int
  let parts: [UnitSummary]
}

struct OverviewRequest: Sendable {
  let lectureTitle: String
  let units: [UnitSummary]
}

protocol SummaryModelClient: Sendable {
  var modelName: String { get }
  var contextLimit: Int { get }

  func summarizeUnit(_ request: UnitSummaryRequest) async throws -> UnitSummary
  func mergeUnitParts(_ request: UnitMergeRequest) async throws -> UnitSummary
  func summarizeOverview(_ request: OverviewRequest) async throws -> String
  func unload() async
}
