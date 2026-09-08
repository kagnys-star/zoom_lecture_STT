import Foundation

/// 실사용(비관리자) 세션이 저장되는 위치. 설정 탭에서 고르면 바로 여기 영구 저장된다.
enum StorageLocation {
  private static let key = "storageLocation"

  static var current: URL {
    get {
      if let saved = UserDefaults.standard.string(forKey: key) { return URL(fileURLWithPath: saved) }
      // 마이그레이션: 처음 읽을 때 예전 기본 경로를 그대로 시드값으로 영구 저장한다 —
      // 그래야 이미 쌓인 강의 아카이브가 목록에서 사라지지 않는다.
      let legacy = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/ZoomCaption", isDirectory: true)
      UserDefaults.standard.set(legacy.path, forKey: key)
      return legacy
    }
    set { UserDefaults.standard.set(newValue.path, forKey: key) }
  }
}
