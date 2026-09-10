import Foundation
import CoreAudio

/// 웹 UI 가 보내오는 요청 본문들.
///
/// 전부 `Decodable` 이고 필드가 죄다 Optional 이다 — 브라우저가 빠뜨린 값이 있어도
/// 디코딩이 통째로 실패하지 않게 하려는 것이다. 필수 여부는 각 라우트에서 확인한다.
/// (`GoldSample.schema` 를 비Optional 로 뒀다가 옛 파일이 통째로 안 읽혀 표본을 날린 적이 있다.)

struct StartRequest: Decodable {
  var title: String?
  var terms: [String]?
  /// 세션 폴더 이름. 이어 적기 중이면 무시된다.
  var folder: String?
  /// 세션 폴더를 만들 상위 위치. 비우면 기본 저장 위치.
  var baseDir: String?
  /// 소리도 WAV 로 남길지. 나중에 재전사하려면 필요하다.
  var keepAudio: Bool?
}
struct TitleRequest: Decodable { var title: String? }
struct OpenRequest: Decodable { var path: String? }
/// `list` 가 "whisper" 면 Whisper 기록을, 아니면 실시간 기록을 고친다.
struct EditRequest: Decodable { var id: Int?; var text: String?; var list: String? }
struct DeleteRequest: Decodable { var ids: [Int]?; var from: Double?; var to: Double?; var list: String? }
struct SummarizeRequest: Decodable { var from: Double? }
struct SaveSummaryRequest: Decodable { var dir: String?; var filename: String? }
struct ApplyCorrectionsRequest: Decodable {
  struct Item: Decodable { var segID: Int; var rangeStart: Int; var rangeEnd: Int
                           var before: String; var after: String }
  var items: [Item]?
}
struct GoldRequest: Decodable {
  var start: Double?; var end: Double?; var kind: String?
  var live: String?; var whisper: String?
  var truth: String?; var verdict: String?
  var key: String?          // 삭제할 때만
}

struct QuietCleanRequest: Decodable { var ids: [Int]? }

struct AdminFeedRequest: Decodable {
  var path: String?
  var speed: Double?
  var title: String?
}

/// 관리자 A/B probe가 측정할 한 Core Audio 후보다. `deviceUID`와 `streamIndex`를
/// 모두 비우면 프로세스 전체, 둘 다 보내면 해당 장치의 해당 출력 스트림만 측정한다.
/// 한쪽만 보내는 요청은 서버에서 거절해 서로 다른 경로를 시험했다고 착각하지 않게 한다.
struct AdministratorAudioProbeStartRequest: Decodable {
  var processObjectID: AudioObjectID?
  var deviceUID: String?
  var streamIndex: UInt?
}

/// 본문에서 갈린 자리를 바로 고칠 때 오는 요청.
///
/// 고치는 행위 하나가 두 가지 일을 한다 — 기록을 바로잡고, **정답지 표본을 남긴다.**
/// 그래서 표본을 모으려고 따로 시간을 낼 필요가 없다.
struct FixRequest: Decodable {
  var segID: Int
  var rangeStart: Int
  var rangeEnd: Int
  var before: String        // 지금 본문에 있는 글자 (원문 그대로)
  var after: String         // 바꿔 넣을 글자
  var verdict: String       // live | whisper | both — whisper 는 "원안이 맞다"
  var start: Double?
  var end: Double?
  var kind: String?
  var live: String?         // 실시간 쪽 원문 (표본에 남긴다)
}
