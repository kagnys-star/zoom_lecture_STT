# Qwen 시간대별 요약 구현 결과

작성일: 2026-09-10
대상: ZoomCaption

## 1. 구현 범위

- Apple Foundation Models 요약 경로 제거
- 추출식 자동 폴백 제거
- Qwen/Ollama를 현재 자동 요약 제공자로 고정
- Whisper 세그먼트만 요약 입력으로 사용
- `boundaryAfter` 기준 시간대 분리
- 과대한 시간대만 `paragraph` 우선으로 내부 청킹
- 구간별 요약, 핵심 주장과 설명, 핵심 용어 생성
- 하위 청크 병합과 전체 개요 생성
- 과제·공지 프롬프트, 스키마, 출력 제거
- 용어명 완전 동치 기준 중복 제거
- 중복 실행 및 오래된 결과 저장 방지
- 기존 LLM 전사 다듬기 기능 유지
- 설치 스크립트와 README의 Apple 폴백 안내 제거

## 2. 주요 코드 변경

### 요약 데이터와 모델 경계

- `SummaryModels.swift`: 입력 세그먼트, 강의 단위, 내부 청크, 요약 결과, 제공자 프로토콜 정의
- `SummaryChunker.swift`: 상위 시간대 생성과 24K 목표 내부 청킹
- `SummaryRenderer.swift`: 모델이 아닌 Swift에서 최종 Markdown 생성
- `OllamaQwenSummaryClient.swift`: Qwen 프롬프트, JSON Schema, 호출·병합·개요 생성
- `Summarizer.swift`: Qwen 시간대별 호출을 순차 조율하고 실패를 상위로 전달

### 앱과 서버

- 요약 시작 시 Whisper 세그먼트를 불변 값으로 복사
- 요약 중 두 번째 요청은 즉시 거부
- 요약 중 새 세션 열기·생성 및 녹음 시작 차단
- generation이 일치하는 결과만 저장
- 실패 시 기존 요약을 지우지 않고 오류 이벤트 전송
- 웹 UI에서 실패 메시지를 표시하고 기존 요약을 복원
- Markdown 제목 수준을 구분해 시간대와 하위 섹션을 다르게 표시

### 유지한 기능

다음 LLM 전사 다듬기 경로는 삭제하거나 재설계하지 않았다.

- `OllamaClient.suggestCorrections`
- `ZoomCaptionApp.suggestPolish`
- `POST /api/polish/suggest`
- `polishProgress`, `polishDone`
- 웹 UI의 다듬기 탭과 결과 표시

## 3. 최종 출력 구조

```markdown
# 전체 강의 요약

## 전체 개요

...

## 1강 · 00:00:00~00:54:20

**이 시간대의 중심 주제**

### 구간 요약

...

### 핵심

- **핵심 주장** 중요한 이유 또는 작동 원리

### 핵심 용어

- **용어** — 강의에서 설명한 뜻
```

핵심은 네 개로 고정하지 않는다. JSON Schema는 0~5개를 허용하며 실제 smoke test에서도 두 개가 출력됐다.

## 4. 검증 결과

### 정적·빌드 검증

- `swift build -c release`: 성공
- `bash -n setup.sh`: 성공
- `git diff --check`: 성공
- 앱 소스의 `FoundationModels`, `SystemLanguageModel`, `DynamicGenerationSchema`: 잔존 참조 없음
- 요약 소스의 `announcements`: 잔존 참조 없음
- 기존 LLM 다듬기 함수·라우트·이벤트·UI: 유지 확인

### 내장 회귀 검사

`.build/release/ZoomCaption --summary-check` 결과 11개 검사 모두 통과했다.

- `boundaryAfter` 상위 시간대 생성
- 마지막 꼬리 시간대 보존
- 전체 세그먼트 순서·포함 보존
- paragraph가 상위 시간대를 만들지 않음
- 과대 시간대 내부 청킹
- 내부 청크 번호 일관성
- 청킹 전후 입력 누락·중복 없음
- L1/L2 정규화 동시 보존
- 접두어 관계 용어 보존
- 코드 소유 시간 범위 렌더링
- 핵심 한 개를 네 개로 강제하지 않음 및 공지 섹션 미출력

현재 호스트는 전체 Xcode가 아닌 Command Line Tools 환경이라 `XCTest`와 Swift `Testing` 모듈이 없다. 이 때문에 같은 검사를 모델·UI와 독립적인 `--summary-check`로 구현했다.

### 실제 Qwen 통합 검사

설치된 `qwen3:8b`로 `Tests/Fixtures/summary-smoke.txt`를 처리했다.

- 시간대 요약: 21.3초
- 전체 개요: 4.2초
- 전체: 25.6초
- 시간대 프롬프트 실제 입력: 771토큰
- 시간대 출력: 389토큰
- 전체 개요 실제 입력: 240토큰
- 최종 구간 제목: `필터와 스트라이드`
- 최종 핵심 수: 2개
- 구조화 응답 파싱 및 Markdown 렌더링: 성공

## 5. 확인된 제한

- 실제 5시간 녹취 전체의 처리 시간과 후반부 회수율은 아직 측정하지 않았다.
- 여러 실제 `boundaryAfter`를 가진 장시간 세션의 Qwen 종단 통합 검사는 아직 하지 않았다. 경계·청킹 자체는 내장 회귀 검사로 확인했다.
- LLM 다듬기는 코드 보존과 빌드만 확인했으며 이번 작업에서 별도 모델 호출 품질 시험은 하지 않았다.
- 빌드에는 기존 `SelfTest.swift`, `Whisper.swift`, `AudioTap.swift`의 Swift 6 관련 경고가 남아 있다. 이번 요약 변경에서 새로 생긴 컴파일 오류는 없다.
- `.app` 번들은 덮어쓰지 않았다. 검증은 SwiftPM 릴리스 실행 파일로 수행했다.

## 6. 결론

계획한 Qwen 전용 시간대별 요약의 코드 경로는 구현됐고, 릴리스 빌드·규칙 회귀 검사·실제 Qwen 소규모 통합 호출을 통과했다. Apple 및 추출식 폴백은 제거됐으며 Qwen 실패는 명시적 오류가 된다. 기존 LLM 전사 다듬기는 유지된다.

실사용 확정 전 남은 핵심 검증은 실제 경계가 포함된 5시간 강의 한 편으로 시간대 커버리지, 처리 시간, 내부 병합 전후 회수율을 측정하는 것이다.
