import Foundation

extension WebUI {
  /// 화면 스타일 (CSS). `WebUI.page` 의 `<style>` 안에 들어간다.
  ///
  /// **색은 반드시 `:root` 변수로만 쓴다.** 값을 직접 적으면 다크 모드에서 깨진다 —
  /// `prefers-color-scheme` 로 변수만 덮어쓰는 구조라, 직접 쓴 색은 안 바뀐다.
  ///
  /// 자막 글자 크기는 `--cap` 하나로 조절한다. 사용자가 슬라이더를 움직이면
  /// JS 가 이 변수만 바꾼다.
  ///
  /// 눈에 띄는 규칙 몇 가지:
  /// - `.dv`(갈린 자리)는 **점선 밑줄만** 긋는다. 색을 칠하면 글이 안 읽힌다.
  /// - 위 칸(Whisper)이 주가 되고 아래 칸(실시간)은 `max-height: 42%` 로 눌러 둔다.
  static let style = #"""
  :root {
    color-scheme: light dark;
    --bg: #f4f6f8;      --panel: #ffffff;   --panel-raised: #ffffff;
    --ink: #172033;     --muted: #657083;   --muted-strong: #475569;
    --line: #dfe4ea;    --line-strong: #c8d0da;
    --accent: #315efb;  --accent-hover: #244bd3; --accent-soft: #eaf0ff;
    --me: #087f5b;      --me-soft: #e7f7f1; --warn: #9a5b0a;    --warn-soft: #fff4d8;
    --danger: #c9362d;  --danger-soft: #feeeec; --on-accent: #ffffff;
    --shadow-sm: 0 1px 2px color-mix(in srgb, var(--ink) 8%, transparent);
    --shadow-md: 0 12px 32px color-mix(in srgb, var(--ink) 10%, transparent);
    --radius-sm: 9px; --radius-md: 13px; --radius-lg: 18px;
    --cap: 16px; --caption-line-height: 1.55; --caption-row-padding: 7px;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #0d1118;    --panel: #151a23;   --panel-raised: #1a202b;
      --ink: #edf1f7;   --muted: #a0a9b7;  --muted-strong: #c2c9d3;
      --line: #29313e;  --line-strong: #3b4656;
      --accent: #84a4ff; --accent-hover: #a2b9ff; --accent-soft: #202d4f;
      --me: #55d6aa;    --me-soft: #15372d; --warn: #f4c05e;    --warn-soft: #3a2b10;
      --danger: #ff8278; --danger-soft: #3f201e; --on-accent: #0b1535;
    }
  }
  * { box-sizing: border-box; }
  html, body { height: 100%; }
  html { background: var(--bg); scroll-behavior: smooth; }
  ::selection { background: color-mix(in srgb, var(--accent) 24%, transparent); }
  .srOnly {
    position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px;
    overflow: hidden; clip: rect(0, 0, 0, 0); white-space: nowrap; border: 0;
  }
  .skipLink {
    position: fixed; top: 10px; left: 12px; z-index: 1000; padding: 9px 13px;
    border-radius: var(--radius-sm); background: var(--ink); color: var(--bg);
    font-weight: 700; text-decoration: none; transform: translateY(-160%);
    transition: transform .16s ease;
  }
  .skipLink:focus { transform: translateY(0); }
  /* 관리자 요소는 일반 화면에서 단순히 흐리게 두지 않고 레이아웃과 접근성 트리에서
     함께 제외한다. 서버 라우트도 별도로 거부하므로 이 규칙은 보안 경계가 아니라
     일반 사용자에게 실험 도구를 노출하지 않기 위한 표현 계층이다. */
  body:not(.administrator-mode) .administratorOnly { display: none !important; }
  body {
    margin: 0; background: var(--bg); color: var(--ink);
    font-family: -apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", "Pretendard", sans-serif;
    font-size: 15px; line-height: 1.55; display: flex; flex-direction: column;
    -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility;
  }

  header {
    position: relative; z-index: 10; display: flex; align-items: center; gap: 16px; flex-wrap: wrap;
    min-height: 72px; padding: 12px clamp(14px, 2vw, 24px); background: color-mix(in srgb, var(--panel) 96%, transparent);
    border-bottom: 1px solid var(--line); box-shadow: var(--shadow-sm);
  }
  .headerIdentity {
    display: flex; align-items: center; gap: 10px; flex: 1 1 300px; min-width: 220px;
  }
  .brand {
    display: inline-flex; align-items: center; gap: 8px; flex: 0 0 auto;
    font-weight: 760; letter-spacing: -.035em; font-size: 17px;
  }
  .brandMark {
    display: inline-flex; align-items: center; justify-content: center; width: 32px; height: 32px;
    border-radius: 10px; background: var(--accent); color: var(--on-accent);
    box-shadow: 0 6px 16px color-mix(in srgb, var(--accent) 24%, transparent);
  }
  .brandMark svg { width: 21px; height: 21px; fill: none; stroke: currentColor; stroke-width: 2.2; stroke-linecap: round; }
  .administratorBadge {
    display: inline-flex; align-items: center; min-height: 26px; padding: 4px 9px;
    border-radius: 999px; background: var(--warn-soft); color: var(--warn);
    border: 1px solid color-mix(in srgb, var(--warn) 38%, var(--line));
    font-size: 12px; font-weight: 750; white-space: nowrap;
  }
  #title {
    font: inherit; font-weight: 600; color: var(--ink); background: transparent;
    border: 1px solid transparent; border-radius: var(--radius-sm); padding: 8px 10px;
    width: clamp(140px, 17vw, 250px); min-width: 0;
  }
  #title:hover { border-color: var(--line); background: var(--bg); }
  #title:focus { outline: none; border-color: var(--accent); background: var(--bg);
                 box-shadow: 0 0 0 3px var(--accent-soft); }

  .pill {
    display: inline-flex; align-items: center; gap: 7px; padding: 5px 12px;
    border-radius: 999px; background: var(--bg); border: 1px solid var(--line);
    font-size: 13px; font-weight: 600; font-variant-numeric: tabular-nums;
  }
  .pill.sub { font-weight: 500; color: var(--muted); max-width: 260px;
              overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--muted); }
  .pill.live .dot { background: var(--danger); animation: pulse 1.6s ease-in-out infinite; }
  .pill.live { color: var(--danger); background: var(--danger-soft); border-color: color-mix(in srgb, var(--danger) 35%, var(--line)); }
  @keyframes pulse { 0%,100% { opacity: 1 } 50% { opacity: .25 } }
  /* 서버와의 연결 상태. 끊기면 화면이 굳는데, 그 사실이 보여야 한다. */
  .conn { width: 6px; height: 6px; border-radius: 50%; background: var(--me); margin-left: 2px; }
  .conn.off { background: var(--danger); animation: pulse 1s steps(1) infinite; }
  .spacer { flex: 1 }
  .recordingStatus {
    display: flex; align-items: center; gap: 7px; flex: 0 0 auto;
    padding-left: 14px; border-left: 1px solid var(--line);
  }
  .statusCaption {
    margin-right: 2px; color: var(--muted); font-size: 12px; font-weight: 650; white-space: nowrap;
  }
  .clockPill { min-width: 86px; justify-content: center; color: var(--muted); }
  .headerActions {
    display: flex; align-items: center; gap: 8px; flex: 0 0 auto;
    padding-left: 14px; border-left: 1px solid var(--line);
  }

  button {
    font: inherit; font-weight: 600; font-size: 14px; cursor: pointer;
    border: 1px solid var(--line); background: var(--panel); color: var(--ink);
    min-height: 38px; padding: 7px 13px; border-radius: var(--radius-sm);
    box-shadow: var(--shadow-sm); touch-action: manipulation;
    transition: background .16s ease, border-color .16s ease, color .16s ease, box-shadow .16s ease, transform .16s ease;
  }
  button:hover:not(:disabled) { background: var(--bg); border-color: var(--line-strong); }
  button:active:not(:disabled) { transform: translateY(1px); box-shadow: none; }
  button:disabled { opacity: .46; cursor: not-allowed; box-shadow: none; }
  button.primary { background: var(--accent); border-color: var(--accent); color: var(--on-accent); }
  button.primary:hover:not(:disabled) { background: var(--accent-hover); border-color: var(--accent-hover); }
  button.stop { background: var(--danger); border-color: var(--danger); color: var(--on-accent); }
  button.stop:hover:not(:disabled) { filter: brightness(1.08); background: var(--danger); }
  button.danger { color: var(--danger); border-color: color-mix(in srgb, var(--danger) 30%, var(--line)); }
  button.danger:hover:not(:disabled) { background: var(--danger-soft); }
  button.sm { min-height: 34px; font-size: 13px; padding: 5px 10px; }
  button:focus-visible, a:focus-visible, input:focus-visible, select:focus-visible,
  textarea:focus-visible, summary:focus-visible, [tabindex]:focus-visible {
    outline: 2px solid var(--accent); outline-offset: 2px;
  }
  .recordAction {
    display: inline-flex; align-items: center; justify-content: center; gap: 8px;
    min-width: 118px; min-height: 42px; padding: 8px 16px; border-radius: 12px;
    font-size: 14px; font-weight: 750; letter-spacing: -.01em;
    box-shadow: 0 5px 14px color-mix(in srgb, var(--accent) 24%, transparent);
    transition: transform .14s ease, box-shadow .14s ease, filter .14s ease;
  }
  .recordGlyph { width: 9px; height: 9px; border-radius: 50%; background: currentColor; }
  .stopGlyph { width: 9px; height: 9px; border-radius: 2px; background: currentColor; }
  .powerGlyph {
    position: relative; display: inline-block; width: 16px; height: 16px;
    border: 1.8px solid currentColor; border-top-color: transparent; border-radius: 50%;
  }
  .powerGlyph::before {
    content: ""; position: absolute; left: 50%; top: -3px; width: 2px; height: 9px;
    border-radius: 2px; background: currentColor; transform: translateX(-50%);
  }
  .recordAction:hover:not(:disabled) { transform: translateY(-1px); box-shadow: 0 7px 18px color-mix(in srgb, var(--accent) 30%, transparent); }
  .recordAction.stop { box-shadow: 0 5px 14px color-mix(in srgb, var(--danger) 24%, transparent); }
  .recordAction.stop:hover:not(:disabled) { box-shadow: 0 7px 18px color-mix(in srgb, var(--danger) 30%, transparent); }
  .quitAction {
    display: inline-flex; align-items: center; justify-content: center;
    width: 42px; height: 42px; padding: 0; border-radius: 12px; font-size: 17px;
  }

  main { flex: 1; display: grid; grid-template-columns: minmax(0,1fr) 24px 400px; min-height: 0; }
  #primaryWorkspace { display: flex; flex-direction: column; min-width: 0; min-height: 0; }
  .workspaceView { flex: 1; min-width: 0; min-height: 0; }
  .workspaceView[hidden] { display: none !important; }

  /* 두 메인 화면은 제목 바로 뒤에서 고르는 큰 세그먼트 버튼으로 둔다.
     활성 화면은 떠 있는 카드처럼 보여 탭 자체가 클릭 가능한 영역임을 드러낸다. */
  .workspaceTabs {
    display: inline-flex; gap: 3px; flex: 0 0 auto; padding: 4px;
    background: var(--bg); border: 1px solid var(--line); border-radius: var(--radius-md);
    box-shadow: inset 0 1px 2px color-mix(in srgb, var(--ink) 5%, transparent);
  }
  .workspaceTab {
    display: inline-flex; align-items: center; justify-content: center; gap: 8px;
    min-width: 100px; min-height: 38px; padding: 6px 14px; border: none; border-radius: var(--radius-sm);
    background: transparent; color: var(--muted); font-size: 14px; font-weight: 700;
    transition: color .14s ease, background .14s ease, box-shadow .14s ease, transform .14s ease;
  }
  .workspaceTab:hover:not(:disabled) { background: var(--panel); border-color: transparent; color: var(--ink); }
  .workspaceTab:active:not(:disabled) { transform: scale(.98); }
  .workspaceTab.on {
    color: var(--accent); background: var(--panel);
    box-shadow: var(--shadow-sm);
  }
  .workspaceTab.on:hover:not(:disabled) { background: var(--panel); }
  .workspaceTab:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }
  .tabIcon { position: relative; display: inline-flex; width: 16px; height: 16px; flex: 0 0 auto; }
  .waveformIcon { align-items: center; justify-content: center; gap: 2px; }
  .waveformIcon i { display: block; width: 2px; border-radius: 2px; background: currentColor; }
  .waveformIcon i:nth-child(1), .waveformIcon i:nth-child(4) { height: 6px; }
  .waveformIcon i:nth-child(2) { height: 13px; }
  .waveformIcon i:nth-child(3) { height: 9px; }
  .summaryIcon { border: 1.5px solid currentColor; border-radius: 4px; }
  .summaryIcon::before, .summaryIcon::after {
    content: ""; position: absolute; left: 3px; right: 3px; height: 1.5px;
    border-radius: 2px; background: currentColor;
  }
  .summaryIcon::before { top: 4px; }
  .summaryIcon::after { top: 9px; right: 6px; }

  @media (max-width: 1180px) {
    .statusCaption { display: none; }
    .recordingStatus, .headerActions { padding-left: 10px; }
    .workspaceTab { min-width: 88px; padding-inline: 11px; }
  }

  @media (max-width: 940px) {
    header { align-items: stretch; }
    .headerIdentity { flex-basis: 100%; }
    .workspaceTabs { flex: 1 1 auto; }
    .workspaceTab { flex: 1; }
    .recordingStatus { border-left: none; padding-left: 0; }
    main { grid-template-columns: 1fr; overflow-y: auto; }
    #primaryWorkspace { min-height: 70vh; }
    aside { border-left: none !important; border-top: 1px solid var(--line); min-height: 55vh; }
    #sideToggle { width: 100%; min-height: 32px; border: 0; border-top: 1px solid var(--line); border-bottom: 1px solid var(--line); }
  }

  /* 사이드 접기. #sideToggle 은 <aside> 앞에 오는 별도 DOM 요소라 grid 세 번째
     칸이 아니라 가운데 칸(항상 22px)에 자동으로 앉는다 — 접어도 손잡이는 그대로
     보여야 다시 펼 수 있다. 상태는 localStorage 에 남겨 새로고침해도 유지한다. */
  body.side-collapsed main { grid-template-columns: minmax(0,1fr) 22px; }
  body.side-collapsed aside { display: none; }
  /* 요약은 읽기 화면이므로 보조 사이드바를 숨기고 작업공간 전체 폭을 사용한다.
     side-collapsed 설정 자체는 건드리지 않아 Whisper로 돌아오면 이전 상태가 복원된다. */
  body.summary-view main { grid-template-columns: minmax(0,1fr); overflow: hidden; }
  body.summary-view #primaryWorkspace { min-height: 0; }
  body.summary-view #sideToggle, body.summary-view aside { display: none; }
  #sideToggle {
    display: flex; align-items: center; justify-content: center;
    background: var(--panel); border: none;
    border-left: 1px solid var(--line); border-right: 1px solid var(--line); border-radius: 0;
    color: var(--muted); font-size: 13px; padding: 0; cursor: pointer; box-shadow: none;
  }
  #sideToggle:hover { background: var(--bg); color: var(--ink); }
  /* 세로 레일은 일반 버튼처럼 눌릴 때 이동하면 가장자리 포인터가 버튼 밖으로
     벗어나 click이 취소될 수 있다. 레일은 위치를 고정해 눌림과 토글을 분리한다. */
  #sideToggle:active:not(:disabled) { transform: none; }

  /* ── 자막 ── */
  section.captions { display: flex; flex-direction: column; min-height: 0; min-width: 0; }
  .toolbar {
    display: flex; gap: 9px; align-items: center; padding: 11px clamp(14px, 2vw, 24px);
    border-bottom: 1px solid var(--line); background: var(--panel); flex-wrap: wrap;
  }
  #search {
    flex: 1; min-width: 160px; min-height: 38px; font: inherit; padding: 8px 12px;
    border: 1px solid var(--line); border-radius: var(--radius-sm); background: var(--bg); color: var(--ink);
    transition: border-color .16s ease, box-shadow .16s ease, background .16s ease;
  }
  #search:focus { outline: none; border-color: var(--accent); background: var(--panel); box-shadow: 0 0 0 3px var(--accent-soft); }
  .toggle { display: inline-flex; align-items: center; gap: 6px; font-size: 13px; color: var(--muted); cursor: pointer; user-select: none; }
  .size-ctl { display: inline-flex; align-items: center; gap: 6px; font-size: 13px; color: var(--muted); }
  .captionSizeControl {
    display: inline-flex; align-items: center; gap: 2px; margin: 0; padding: 3px;
    border: 1px solid var(--line); border-radius: 11px; background: var(--bg);
  }
  .captionSizeControl legend {
    position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px;
    overflow: hidden; clip: rect(0, 0, 0, 0); white-space: nowrap; border: 0;
  }
  .captionSizeControl button {
    min-height: 32px; padding: 5px 9px; border: 0; border-radius: 7px; box-shadow: none;
    background: transparent; color: var(--muted); font-size: 12.5px;
  }
  .captionSizeControl button[aria-pressed="true"] {
    background: var(--accent-soft); color: var(--accent);
    box-shadow: inset 0 -2px 0 var(--accent);
  }
  .captionSizeControl button:hover:not(:disabled) { border-color: transparent; }

  .editbar {
    display: none; gap: 9px; align-items: center; padding: 9px 18px;
    background: var(--accent-soft); border-bottom: 1px solid var(--line); font-size: 13.5px;
  }
  body.editing .editbar { display: flex; }
  .editbar .grow { flex: 1; color: var(--accent); font-weight: 600; }

  /* 확정된 자막만 여기 쌓인다. 아래 #live 와 영역이 겹치지 않게 스크롤을 따로 가진다. */
  #stream { flex: 1; overflow-y: auto; padding: 16px clamp(8px, 1.3vw, 18px) 22px; min-height: 0; }
  .line {
    display: grid; grid-template-columns: 18px 52px minmax(0,1fr) 26px 26px; gap: 6px;
    width: min(1440px, 100%); margin-inline: auto; padding: var(--caption-row-padding) 6px;
    border-radius: 12px; align-items: baseline;
  }
  .line:hover { background: var(--panel); box-shadow: inset 0 0 0 1px var(--line); }
  .line.hit { background: var(--accent-soft); }
  .line.picked { background: var(--danger-soft); }
  .line.fresh { animation: slidein .28s ease-out; }
  @keyframes slidein { from { opacity: 0; transform: translateY(6px) } to { opacity: 1; transform: none } }
  /* 문단 시작 줄만 위에 여백을 더 준다 — Whisper 세그먼트(3~10초 단위)를 문단으로
     묶어 보여줄 때(Paragraph.swift), 어디서 화제가 바뀌는지 한눈에 보이게. */
  .line.parastart { margin-top: 14px; }
  /* 같은 문단이 이어지는 줄은 타임스탬프를 지운다 — 세그먼트 경계가 문장 중간에서
     끊기면 그 자리에 시각이 끼어 보여서 오히려 읽기 어려워진다(markParaBoundary 참고).
     grid 열은 그대로 남겨 텍스트 시작 위치는 흔들리지 않는다. */
  .line.paracont .ts { visibility: hidden; }

  .line .pick, .line .del, .line .bnd { visibility: hidden; }
  body.editing .line .pick, body.editing .line .del, body.editing .line .bnd { visibility: visible; }
  .pick { accent-color: var(--danger); margin: 0; align-self: center; }
  .del {
    border: none; background: transparent; color: var(--muted); font-size: 15px;
    min-height: 30px; padding: 2px 6px; border-radius: 6px; line-height: 1; box-shadow: none;
  }
  .del:hover { background: var(--danger-soft); color: var(--danger); }

  /* 강의 종료 토글. 이미 붙어 있는 줄은 눌린 상태로 보여야 무엇을 지우는 버튼인지 안다. */
  .bnd {
    border: none; background: transparent; color: var(--muted); font-size: 13px;
    min-height: 30px; padding: 2px 6px; border-radius: 6px; line-height: 1; box-shadow: none;
  }
  .bnd:hover { background: var(--accent-soft); color: var(--accent); }
  .bnd[aria-pressed="true"] { color: var(--accent); }
  .bnd:disabled { opacity: .5; }

  .ts { font-size: 12px; color: var(--muted); font-variant-numeric: tabular-nums; padding-top: 4px;
        cursor: pointer; border-radius: 5px; }
  .ts:hover { color: var(--accent); background: var(--accent-soft); }
  .txt { font-size: var(--cap); line-height: var(--caption-line-height); word-break: keep-all; overflow-wrap: anywhere;
         border-radius: 7px; padding: 2px 5px; margin: -2px -5px; }
  body.editing .txt { cursor: text; }
  body.editing .txt:hover { background: var(--bg); box-shadow: inset 0 0 0 1px var(--line); }
  .txt[contenteditable="true"]:focus { outline: none; background: var(--panel); box-shadow: inset 0 0 0 2px var(--accent); }
  .txt mark { background: color-mix(in srgb, var(--accent) 30%, transparent); border-radius: 3px; padding: 0 2px; }
  .line.wasEdited .ts::after { content: "✎"; margin-left: 4px; color: var(--accent); }

  /* 실제 발화 텍스트와 섞지 않는 구조화된 강의 종료 표식. line 안의 마지막 grid
     행으로 두면 문단 탐색(previousElementSibling)은 자막 줄끼리만 비교할 수 있고,
     편집·검색·요약 대상인 .txt에도 이 문구가 들어가지 않는다. */
  .lectureEndMarker {
    grid-column: 2 / -1; display: flex; align-items: center; gap: 9px;
    margin: 8px 0 2px; color: var(--muted); font-size: 12px; font-weight: 700;
    letter-spacing: .04em;
  }
  .lectureEndMarker::before, .lectureEndMarker::after {
    content: ""; height: 1px; background: var(--line);
  }
  .lectureEndMarker::before { width: 18px; }
  .lectureEndMarker::after { flex: 1; }

  /* 갈린 자리 — 색을 칠하면 글이 안 읽힌다. 점선만 긋는다. */
  .dv { background: none; border-bottom: 2px dotted var(--warn); cursor: pointer;
        border-radius: 2px; }
  .dv:hover { background: var(--warn-soft); }
  .dv.open { background: var(--warn-soft); }
  .dv.done { border-bottom-color: var(--me); background: var(--me-soft); cursor: default; }
  /* 고른 뒤에도 "원안 유지" 는 표시를 남긴다 — 이미 본 자리라는 뜻 */
  .dv.kept { border-bottom-style: solid; border-bottom-color: var(--line); }

  .fixBox { margin: 9px 0 4px 0; padding: 11px 13px; border: 1px solid var(--line);
            border-radius: 11px; background: var(--bg); font-size: 14px; }
  .fixBox .fbRow { display: flex; align-items: center; gap: 9px; flex-wrap: wrap; }
  .fixBox .fbWho { flex: 0 0 auto; font-size: 11.5px; color: var(--muted); }
  .fixBox .fbVal { font-weight: 600; word-break: break-all; }
  .fixBox .fbBtns { display: flex; gap: 7px; margin-top: 10px; flex-wrap: wrap; }
  .fixBox button { font-size: 13px; padding: 7px 11px; }
  .fixBox kbd { font-size: 10.5px; opacity: .75; margin-right: 4px; }
  .fixBox input[type=text] { flex: 1; min-width: 160px; }
  .fixBox .fbNote { font-size: 11.5px; color: var(--muted); margin-top: 8px; }
  #divBar { display: none; padding: 7px 18px; font-size: 12.5px; color: var(--muted);
            border-bottom: 1px solid var(--line); background: var(--panel); }
  #divBar b { color: var(--ink); }

  #toast { position: fixed; left: 50%; bottom: 26px; transform: translateX(-50%) translateY(14px);
           background: var(--ink); color: var(--bg); padding: 10px 17px; border-radius: 999px;
           font-size: 13.5px; font-weight: 600; opacity: 0; pointer-events: none;
           transition: opacity .18s ease, transform .18s ease; z-index: 90; }
  #toast.on { opacity: .94; transform: translateX(-50%) translateY(0); }

  /* 아래 칸 — 실시간 전사기. 위(Whisper)와 높이를 나눠 갖는다. */
  #fastPane { flex: 0 0 auto; display: flex; flex-direction: column;
              border-top: 1px solid var(--line-strong); background: var(--panel); max-height: 42%; }
  .paneBar { display: flex; align-items: center; gap: 8px; padding: 6px 18px;
             min-height: 38px; border-bottom: 1px solid var(--line); }
  .paneNote { font-size: 11.5px; color: var(--muted); }
  .paneTag { flex: 0 0 auto; font-size: 11px; font-weight: 700; letter-spacing: .02em;
             padding: 2px 8px; border-radius: 999px; }
  .paneTag.main { background: var(--accent-soft); color: var(--accent); }
  .paneTag.fast { background: var(--me-soft); color: var(--me); }
  #fastStream { flex: 1 1 auto; overflow-y: auto; padding: 8px clamp(8px, 1.3vw, 18px) 10px; min-height: 0; }
  #fastStream .fline { display: grid; grid-template-columns: 52px minmax(0,1fr); gap: 6px;
                       width: min(1440px, 100%); margin-inline: auto; padding: 4px 0;
                       font-size: var(--cap); line-height: var(--caption-line-height); color: var(--muted); }
  #fastStream .fline .t { font-size: 11.5px; font-variant-numeric: tabular-nums; padding-top: 3px; }
  #fastStream .fline:last-child { color: var(--ink); }
  /* Whisper 문장이 하나도 없을 때는 실시간 확정 기록이 정식 기록이므로, 같은 표식을
     아래 칸에도 표시한다. 두 열 전체를 차지해 앞 문장의 일부처럼 보이지 않게 한다. */
  #fastStream .fline .lectureEndMarker { grid-column: 1 / -1; }
  #fastStream:empty::before { content: "시작하면 여기에 실시간 자막이 흐릅니다.";
                              font-size: 12.5px; color: var(--muted); }

  /* 아직 확정되지 않은 "받아쓰는 중" 텍스트. 확정 자막과 섞이지 않도록 별도 칸으로 뺐다. */
  /* 높이를 고정한다. 글이 늘고 줄 때마다 높이가 바뀌면 위쪽 자막 전체가 다시 배치되어
     받아쓰는 내내 화면이 덜컹거린다. 넘치는 글은 이 칸 안에서 스크롤시킨다. */
  #live {
    flex: 0 0 auto; display: flex; gap: 10px; align-items: flex-start;
    padding: 12px clamp(8px, 1.3vw, 18px) 14px; border-top: 1px solid var(--line); background: var(--panel-raised);
    font-size: var(--cap); line-height: var(--caption-line-height); height: calc(var(--caption-line-height) * 3em + 24px); overflow-y: auto;
  }
  #live[hidden] { display: none; }
  #live .liveTag {
    flex: 0 0 auto; margin-top: 3px; font-size: 11.5px; font-weight: 700; letter-spacing: .02em;
    padding: 2px 8px; border-radius: 999px; background: var(--warn-soft); color: var(--warn);
  }
  #liveText { line-height: var(--caption-line-height); color: var(--muted);
              font-style: italic; word-break: keep-all; overflow-wrap: anywhere; }
  #liveText:empty::before { content: "듣는 중…"; opacity: .5; }
  /* 커서는 글 끝에 붙어야 한다. 별도 요소로 두면 flex 가 오른쪽 끝으로 밀어낸다. */
  #liveText::after {
    content: ""; display: inline-block; width: 2px; height: 1em; background: var(--accent);
    vertical-align: -2px; margin-left: 3px; animation: pulse 1.1s steps(1) infinite;
  }

  /* 완전 종료 확인 */
  #quitVeil {
    position: fixed; inset: 0; z-index: 50; display: flex; align-items: center; justify-content: center;
    background: color-mix(in srgb, var(--ink) 48%, transparent); padding: 20px;
    backdrop-filter: blur(4px);
  }
  #quitVeil[hidden] { display: none; }
  .quitCard {
    background: var(--panel-raised); border: 1px solid var(--line-strong); border-radius: var(--radius-lg);
    padding: 24px 26px; max-width: 460px; width: 100%; box-shadow: var(--shadow-md);
  }
  .quitCard h3 { margin: 0 0 10px; font-size: 17px; }
  .quitCard p { margin: 0; font-size: 14px; line-height: 1.65; color: var(--muted); word-break: keep-all; }
  .quitCard p b { color: var(--ink); }
  .quitCard code {
    display: block; margin-top: 9px; padding: 8px 10px; border-radius: 8px;
    background: var(--bg); border: 1px solid var(--line); color: var(--ink);
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12.5px;
    user-select: all; word-break: break-all;
  }
  .quitBtns { display: flex; justify-content: flex-end; gap: 9px; margin-top: 18px; }
  .quitBtns[hidden] { display: none; }

  /* 정지 → 마무리 대기 */
  #stopVeil {
    position: fixed; inset: 0; z-index: 50; display: flex; align-items: center; justify-content: center;
    background: color-mix(in srgb, var(--ink) 48%, transparent); padding: 20px;
    backdrop-filter: blur(4px);
  }
  #stopVeil[hidden] { display: none; }
  .stopCard {
    background: var(--panel-raised); border: 1px solid var(--line-strong); border-radius: var(--radius-lg);
    padding: 24px 26px; max-width: 380px; width: 100%; box-shadow: var(--shadow-md);
  }
  .stopCard h3 { margin: 0 0 6px; font-size: 17px; }
  .stopHint { margin: 0 0 16px; font-size: 13px; color: var(--muted); line-height: 1.6; word-break: keep-all; }
  /* 단계 한 줄. pending(아직 대기) → active(도는 중, 테두리가 돈다) → done(체크) 순서로 바뀐다. */
  .stopStep { display: flex; align-items: center; gap: 10px; padding: 7px 0; font-size: 14px; }
  .stopStep .stopIcon {
    width: 16px; height: 16px; flex: 0 0 auto; border-radius: 50%; border: 2px solid var(--line);
    display: flex; align-items: center; justify-content: center; font-size: 10px; color: var(--panel);
  }
  .stopStep.active .stopIcon { border-color: var(--accent); border-top-color: transparent; animation: spin .8s linear infinite; }
  .stopStep.done .stopIcon { border-color: var(--accent); background: var(--accent); }
  .stopStep.done .stopIcon::after { content: "\2713"; }
  .stopStep.pending .stopLabel { color: var(--muted); }
  .stopStep .stopLabel { flex: 1; }
  .stopStep .stopDetail { font-size: 12px; color: var(--muted); }
  @keyframes spin { to { transform: rotate(360deg); } }

  /* 창을 다시 열었을 때 "이미 돌고 있던 녹음" 임을 분명히 알린다 */
  #resumeBar { display: none; align-items: center; gap: 10px; padding: 10px 18px;
               background: var(--warn-soft); color: var(--warn); font-size: 13.5px;
               border-bottom: 1px solid var(--line); }
  #resumeBar.on { display: flex; }
  #resumeBar .grow { flex: 1; line-height: 1.5; }

  /* 소리가 안 들어오는 건 자막 화면에서 바로 보여야 한다. 설정 탭 구석에 두면 못 본다. */
  #silentBar { display: none; align-items: center; gap: 10px; padding: 10px 18px;
               background: var(--danger-soft); color: var(--danger); font-size: 13.5px;
               border-bottom: 1px solid var(--line); }
  #silentBar.on { display: flex; }
  #silentBar .grow { flex: 1; line-height: 1.55; }

  /* ── 넓은 요약 읽기 화면 ── */
  .summaryView { background: var(--bg); }
  .summaryScroll { height: 100%; overflow-y: auto; overscroll-behavior: contain; }
  .summaryShell { width: min(1080px, 100%); margin: 0 auto; padding: 36px 38px 80px; }
  .summaryHead {
    display: flex; align-items: flex-start; justify-content: space-between; gap: 20px;
    margin-bottom: 18px;
  }
  .summaryHead h1 { margin: 0 0 6px; font-size: clamp(26px, 3vw, 32px); line-height: 1.2; letter-spacing: -.04em; }
  .summaryMeta { display: flex; gap: 9px; flex-wrap: wrap; color: var(--muted); font-size: 13px; }
  .summaryMeta span + span::before { content: "·"; margin-right: 9px; color: var(--line); }
  .summaryMeta span:empty + span::before { content: none; }
  .summaryMeta button {
    border: none; background: transparent; color: var(--accent); padding: 0; font-size: 13px;
  }
  .summaryMeta button:hover:not(:disabled) { background: transparent; border-color: transparent; text-decoration: underline; }
  .summaryHeadActions { display: flex; align-items: center; gap: 8px; }
  .summaryOnline {
    display: flex; align-items: flex-end; gap: 12px; flex-wrap: wrap; margin-bottom: 12px;
  }
  .onlineActions { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
  /* 드롭다운은 접힌 상태에서 어떤 선택지가 있는지 보이지 않아, 어느 서비스로 보내는지가
     한눈에 드러나야 하는 이 흐름에 맞지 않는다. 세 대상을 항상 펼쳐 두고 고른 것만
     강조한다. 라디오는 화면에서 숨기되 제거하지 않아 키보드·보조기술 접근을 유지한다. */
  .onlineTargets { border: 0; margin: 0; padding: 0; min-width: 0; }
  .onlineTargets > legend {
    padding: 0; margin-bottom: 6px; font-size: 14px; font-weight: 650; color: var(--ink);
  }
  .onlineTargetOption {
    display: inline-flex; align-items: center; min-height: 40px; padding: 7px 14px;
    font-size: 14px; font-weight: 600; color: var(--muted); cursor: pointer;
    border: 1px solid var(--line); background: var(--panel);
  }
  .onlineTargetOption:first-of-type { border-radius: 9px 0 0 9px; }
  .onlineTargetOption:last-of-type { border-radius: 0 9px 9px 0; }
  .onlineTargetOption + .onlineTargetOption { margin-left: -1px; }
  .onlineTargetOption input {
    position: absolute; width: 1px; height: 1px; opacity: 0; pointer-events: none;
  }
  .onlineTargetOption:hover { color: var(--ink); }
  .onlineTargetOption:has(input:checked) {
    z-index: 1; color: var(--on-accent); background: var(--accent); border-color: var(--accent);
  }
  /* 라디오 자체가 안 보이므로 초점 표시를 감싼 라벨이 대신 받아야 키보드 사용자가
     지금 어디에 있는지 알 수 있다. */
  .onlineTargetOption:has(input:focus-visible) {
    z-index: 2; outline: none; box-shadow: 0 0 0 3px var(--accent-soft);
  }
  .onlineTargets:disabled > legend, .onlineTargets:disabled .onlineTargetOption {
    opacity: .5; cursor: not-allowed;
  }
  .onlineStep {
    margin-bottom: 14px; padding: 15px 17px; background: var(--accent-soft);
    border: 1px solid color-mix(in srgb, var(--accent) 28%, var(--line)); border-radius: 13px;
    color: var(--ink); font-size: 13.5px; line-height: 1.6;
  }
  .onlineStepRow { display: grid; grid-template-columns: 27px 1fr; gap: 10px; align-items: start; }
  .onlineStepRow + .onlineStepRow { margin-top: 11px; }
  .onlineStepNumber {
    display: inline-flex; align-items: center; justify-content: center; width: 25px; height: 25px;
    border-radius: 50%; background: var(--accent); color: var(--on-accent); font-weight: 750;
  }
  .onlineStep strong { display: block; margin-bottom: 1px; }
  .onlineStep textarea {
    width: 100%; min-height: 130px; margin-top: 9px; padding: 10px 11px; resize: vertical;
    border: 1px solid var(--line); border-radius: 9px; background: var(--panel); color: var(--ink);
    font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
  }
  .onlineStep textarea:focus { outline: none; border-color: var(--accent); box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent) 14%, transparent); }
  /* 다운로드한 마크다운을 놓는 순간에만 전체 요약 면을 강조해, PDF 드롭 존과
     대상이 다르다는 점을 보이면서 평소 읽기 화면에는 시각 잡음을 남기지 않는다. */
  .summaryDropActive .summaryShell { position: relative; }
  .summaryDropActive .summaryShell::after {
    content: "요약 마크다운을 놓아 적용"; position: absolute; inset: 18px; z-index: 20;
    display: flex; align-items: center; justify-content: center; pointer-events: none;
    border: 3px dashed var(--accent); border-radius: 16px;
    background: color-mix(in srgb, var(--accent-soft) 92%, transparent);
    color: var(--accent); font-size: 18px; font-weight: 750;
  }
  .summaryControls {
    display: grid; grid-template-columns: minmax(260px, .9fr) minmax(360px, 1.1fr); gap: 18px;
    align-items: start; padding: 18px 20px; margin-bottom: 16px;
    background: var(--panel); border: 1px solid var(--line); border-radius: var(--radius-md);
    box-shadow: var(--shadow-sm);
  }
  .summaryRange > label, .summarySave > label {
    display: block; margin-bottom: 6px; font-size: 14px; font-weight: 650;
  }
  /* 시작/끝은 같은 서버 구간 id를 고르는 한 쌍이라 한 줄에 묶는다. 너비가 좁아도
     select가 버튼을 밀어내지 않도록 min-width:0과 유연한 비율을 함께 둔다. */
  .summaryRangeRow { display: flex; align-items: center; gap: 8px; }
  .summaryRangeRow select {
    flex: 1 1 0; min-width: 0; min-height: 40px; font: inherit; font-size: 14px; padding: 8px 10px;
    border: 1px solid var(--line); border-radius: 9px; background: var(--bg); color: var(--ink);
  }
  .summaryRangeRow select:focus { outline: none; border-color: var(--accent); }
  .summaryRangeRow > span { color: var(--muted); }
  .summarySaveDestination { margin-top: 8px; }
  .summaryView input[type=text] {
    width: 100%; min-width: 0; min-height: 40px; font: inherit; font-size: 14px; padding: 8px 10px;
    border: 1px solid var(--line); border-radius: 9px; background: var(--bg); color: var(--ink);
  }
  .summaryView input[type=text]:focus { outline: none; border-color: var(--accent); }
  .summaryProgress {
    grid-column: 1 / -1; min-height: 21px; color: var(--accent); font-size: 13.5px; font-weight: 600;
  }
  .summaryProgress.busy::before {
    content: ""; display: inline-block; width: 12px; height: 12px; margin-right: 7px;
    vertical-align: -1px; border: 2px solid var(--line); border-top-color: var(--accent);
    border-radius: 50%; animation: spin .8s linear infinite;
  }
  #summary {
    min-height: 260px; padding: 38px clamp(24px, 5vw, 56px) 48px; margin-top: 16px;
    background: var(--panel); border: 1px solid var(--line); border-radius: var(--radius-lg);
    box-shadow: var(--shadow-sm); font-size: 16.5px; line-height: 1.78;
  }
  .summaryUtilities { display: grid; grid-template-columns: 1fr; gap: 12px; margin-top: 14px; }
  .summaryUtility { background: var(--panel); border: 1px solid var(--line); border-radius: 12px; }
  .summaryUtility > summary {
    padding: 12px 14px; cursor: pointer; font-size: 14px; font-weight: 650; user-select: none;
  }
  .summaryUtility[open] > summary { border-bottom: 1px solid var(--line); }
  .summaryUtilityBody { padding: 14px; }
  .summaryUtilityBody .card:last-child { margin-bottom: 0; }

  .empty { color: var(--muted); text-align: center; padding: 56px 20px; line-height: 1.9; word-break: keep-all; }
  .empty kbd { background: var(--panel); border: 1px solid var(--line); border-bottom-width: 2px;
               border-radius: 6px; padding: 2px 7px; font-size: 13px; font-family: inherit; }

  /* ── 사이드 ── */
  aside { border-left: 1px solid var(--line); background: var(--panel); display: flex; flex-direction: column; min-height: 0; }
  .tabs { display: flex; min-height: 48px; border-bottom: 1px solid var(--line); background: var(--panel); }
  .tab { flex: 1; padding: 11px 4px; text-align: center; font-size: 13.5px; font-weight: 600;
         color: var(--muted); cursor: pointer; border: 0; border-radius: 0;
         background: transparent; border-bottom: 2px solid transparent; }
  .tab:hover:not(:disabled) { background: var(--bg); border-color: transparent; color: var(--ink); }
  .tab.on { color: var(--accent); border-bottom-color: var(--accent); }
  .tab.on:hover:not(:disabled) { border-bottom-color: var(--accent); }
  .panel { flex: 1; overflow-y: auto; padding: 22px 20px 36px; display: none; }
  .panel.on { display: block; }

  .field { margin-bottom: 22px; }
  .field > label { display: block; font-size: 13px; font-weight: 700; margin-bottom: 7px; color: var(--muted-strong); }
  .hint { font-size: 12.5px; color: var(--muted); line-height: 1.55; margin-top: 5px; }
  /* 체크박스·라디오 안의 설명은 제목 아래로 내려야 읽힌다 */
  .check .hint { display: block; margin-top: 2px; font-weight: 400; }
  .field textarea, .field input[type=text], .field select {
    width: 100%; min-height: 40px; font: inherit; font-size: 14px; padding: 8px 10px;
    border: 1px solid var(--line); border-radius: 9px; background: var(--bg); color: var(--ink);
    transition: border-color .16s ease, box-shadow .16s ease, background .16s ease;
  }
  .field textarea:focus, .field input[type=text]:focus, .field select:focus {
    outline: none; border-color: var(--accent); background: var(--panel); box-shadow: 0 0 0 3px var(--accent-soft);
  }
  .field textarea { min-height: 68px; resize: vertical; }
  .check { display: flex; align-items: flex-start; gap: 9px; margin-bottom: 9px; font-size: 14px; cursor: pointer; }
  .check input { margin-top: 3px; accent-color: var(--accent); }

  .notice { padding: 10px 12px; border-radius: 10px; font-size: 13px; line-height: 1.6; margin-bottom: 13px; }
  .notice.warn { background: var(--warn-soft); color: var(--warn); border: 1px solid color-mix(in srgb, var(--warn) 20%, transparent); }
  .notice.info { background: var(--accent-soft); color: var(--accent); border: 1px solid color-mix(in srgb, var(--accent) 18%, transparent); }

  .row { display: flex; gap: 8px; }
  .row > * { flex: 1; }
  #logView {
    display: none; margin-top: 10px; max-height: 260px; overflow: auto;
    background: var(--bg); border: 1px solid var(--line); border-radius: 9px;
    padding: 10px; font-size: 11.5px; line-height: 1.5; white-space: pre-wrap;
    word-break: break-all; font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  }
  #logView.on { display: block; }
  #logView .err { color: var(--danger); }
  #logView .warn { color: var(--warn); }
  .cmpLegend { display: flex; gap: 12px; margin-bottom: 9px; }
  .sw { width: 10px; height: 10px; border-radius: 3px; display: inline-block; margin-right: 4px; }
  .sw.script { background: color-mix(in srgb, var(--accent) 45%, transparent); }
  .sw.missing { background: color-mix(in srgb, var(--warn) 55%, transparent); }
  .sw.differ { background: color-mix(in srgb, var(--danger) 45%, transparent); }
  .cmpRow { display: grid; grid-template-columns: 52px 1fr; gap: 8px; padding: 7px 0;
            border-top: 1px solid var(--line); font-size: 13px; line-height: 1.55; }
  .cmpRow .t { color: var(--muted); font-size: 11.5px; font-variant-numeric: tabular-nums; padding-top: 2px; }
  .cmpRow .side { display: block; word-break: break-all; }
  .cmpRow .side b { font-weight: 600; padding: 1px 3px; border-radius: 3px; }
  .cmpRow.script .side b { background: color-mix(in srgb, var(--accent) 22%, transparent); }
  .cmpRow.missing .side b { background: color-mix(in srgb, var(--warn) 25%, transparent); }
  .cmpRow.differ .side b { background: color-mix(in srgb, var(--danger) 20%, transparent); }
  .cmpRow .tag { font-size: 10.5px; color: var(--muted); }
  .wsTrack { height: 6px; border-radius: 999px; background: var(--bg);
             border: 1px solid var(--line); overflow: hidden; }
  .wsFill { height: 100%; width: 0; background: var(--accent); transition: width .25s ease; }
  .corrRow { display: grid; grid-template-columns: 20px 50px 1fr; gap: 8px; padding: 7px 0;
             border-top: 1px solid var(--line); font-size: 13px; line-height: 1.5; }
  .corrRow .t { color: var(--muted); font-size: 11.5px; font-variant-numeric: tabular-nums; padding-top: 2px; }
  .corrRow del { color: var(--danger); text-decoration: line-through; }
  .corrRow ins { color: var(--me); text-decoration: none; font-weight: 600; }
  .corrRow .src { font-size: 10.5px; color: var(--muted); margin-left: 5px; }
  .scoreGrid { display: flex; gap: 8px; margin-top: 11px; }
  .scoreGrid > div { flex: 1; border: 1px solid var(--line); border-radius: 11px; padding: 10px 11px; }
  .scoreGrid .win { border-color: var(--me); background: var(--me-soft); }
  .scoreGrid .k { font-size: 11.5px; color: var(--muted); }
  .scoreGrid .v { font-size: 20px; font-weight: 700; margin-top: 3px; font-variant-numeric: tabular-nums; }
  .muted-note { font-size: 12.5px; color: var(--muted); margin-top: 10px; line-height: 1.6; }

  /* 표본 모으기 — 손이 아니라 귀로 하는 작업이라, 한 화면에 한 지점만 크게 띄운다 */
  .goldCard { border: 1px solid var(--line); border-radius: 13px; padding: 15px;
              margin-top: 11px; background: var(--panel); }
  .goldHead { display: flex; justify-content: space-between; align-items: center;
              font-size: 12px; color: var(--muted); margin-bottom: 11px; }
  .goldHead b { color: var(--ink); font-variant-numeric: tabular-nums; }
  .goldPlay { width: 100%; padding: 13px; font-size: 15px; font-weight: 600; margin-bottom: 12px; }
  .goldPlay.on { background: var(--accent-soft); border-color: var(--accent); color: var(--accent); }
  .goldOpt { display: flex; align-items: flex-start; gap: 10px; width: 100%;
             text-align: left; padding: 11px 13px; margin-bottom: 7px; font-size: 14px;
             line-height: 1.5; white-space: normal; }
  .goldOpt kbd { flex: 0 0 auto; min-width: 19px; text-align: center; font-size: 11px;
                 font-family: inherit; color: var(--muted); border: 1px solid var(--line);
                 border-radius: 5px; padding: 1px 4px; margin-top: 2px; }
  .goldOpt .who { flex: 0 0 58px; font-size: 11.5px; color: var(--muted); margin-top: 2px; }
  .goldOpt .val { flex: 1; font-weight: 600; word-break: break-all; }
  .goldOpt:hover:not(:disabled) { border-color: var(--accent); }
  .goldTrack { height: 4px; border-radius: 999px; background: var(--bg);
               border: 1px solid var(--line); overflow: hidden; margin-bottom: 12px; }
  .goldTrack > div { height: 100%; background: var(--accent); transition: width .2s ease; }
  .goldKeys { font-size: 11.5px; color: var(--muted); margin-top: 9px; text-align: center; }

  .card {
    border: 1px solid var(--line); border-radius: 12px; padding: 13px 14px; margin-bottom: 9px;
    display: flex; align-items: center; gap: 10px;
  }
  .card .meta { flex: 1; min-width: 0; }
  .card .name { font-weight: 600; font-size: 14px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .card .sub { font-size: 12px; color: var(--muted); margin-top: 2px; }
  .card.current { border-color: var(--accent); background: var(--accent-soft); }

  .chips { display: flex; flex-wrap: wrap; gap: 5px; margin-top: 9px; }
  .chip { font-size: 12px; padding: 3px 9px; border-radius: 999px;
          background: var(--bg); border: 1px solid var(--line); color: var(--muted); }

  .drop {
    border: 1.5px dashed var(--line-strong); border-radius: 13px; padding: 28px 16px; text-align: center;
    color: var(--muted); background: var(--bg); font-size: 13.5px; cursor: pointer; line-height: 1.7;
    transition: border-color .16s ease, color .16s ease, background .16s ease;
  }
  .drop:hover, .drop.over { border-color: var(--accent); color: var(--accent); background: var(--accent-soft); }

  #summary h2 { font-size: 24px; margin: 30px 0 13px; padding-bottom: 9px; border-bottom: 1px solid var(--line); line-height: 1.35; }
  #summary h2:first-child { margin-top: 0; }
  #summary h3 { font-size: 20px; margin: 28px 0 11px; color: var(--ink); line-height: 1.4; }
  #summary h4 { font-size: 16px; margin: 22px 0 8px; color: var(--muted); }
  #summary ul, #summary ol { padding-left: 23px; margin: 10px 0 16px; }
  #summary li { margin: 7px 0; line-height: 1.75; word-break: keep-all; }
  /* 온라인 요약 안내의 순서 목록은 번호 자체가 진행 단계를 뜻하므로, 렌더된 요약
     본문보다 한 톤 옅은 muted-note 안에서도 번호 색은 그대로 눈에 띄게 둔다. */
  #summary .onlineHelp li::marker { color: var(--accent); font-weight: 650; }
  #summary .onlineHelp kbd {
    padding: 1px 6px; border: 1px solid var(--line); border-bottom-width: 2px;
    border-radius: 5px; background: var(--panel); font-size: 12px;
  }
  #summary p { margin: 9px 0 16px; line-height: 1.75; word-break: keep-all; }
  #summary .muted-note { font-size: 15px; }
  #summary hr { border: none; border-top: 1px solid var(--line); margin: 24px 0; }
  #summary blockquote { margin: 16px 0; padding: 12px 15px; background: var(--bg);
                        border-left: 3px solid var(--warn); border-radius: 0 8px 8px 0;
                        font-size: 15px; color: var(--muted); }

  @media (max-width: 700px) {
    header { gap: 10px; padding: 10px 12px; }
    .headerIdentity { flex-basis: 100%; gap: 8px; }
    .brand > span:last-child { display: none; }
    #title { flex: 1; width: auto; }
    header .spacer { display: none; }
    .workspaceTabs { flex: 1 1 100%; width: 100%; }
    .recordingStatus { flex: 1 1 100%; min-width: 0; justify-content: center; padding-left: 0; }
    .headerActions { width: 100%; padding-left: 0; border-left: 0; }
    .headerActions .recordAction { flex: 1; }
    .workspaceTabs { flex: 1; }
    .workspaceTab { flex: 1; min-width: 0; }
    .summaryShell { padding: 20px 14px 48px; }
    .summaryHead { align-items: stretch; flex-direction: column; }
    .summaryHead #btnSummarize { width: 100%; }
    .summaryOnline { align-items: stretch; }
    .summaryOnline > * { flex: 1 1 100%; }
    .onlineTargets { display: flex; flex-direction: column; }
    .onlineTargetOption { justify-content: center; }
    .onlineTargetOption:first-of-type { border-radius: 9px 9px 0 0; }
    .onlineTargetOption:last-of-type { border-radius: 0 0 9px 9px; }
    .onlineTargetOption + .onlineTargetOption { margin-left: 0; margin-top: -1px; }
    .onlineActions > * { flex: 1 1 auto; }
    .summaryRangeRow { flex-wrap: wrap; }
    .summaryRangeRow select { flex: 1 1 calc(50% - 18px); }
    .summaryRangeRow #btnFromLast { flex-basis: 100% !important; }
    .summaryControls, .summaryUtilities { grid-template-columns: 1fr; }
    #summary { padding: 24px 20px 32px; border-radius: 12px; font-size: 16px; }
    #summary h2 { font-size: 21px; }
    #summary h3 { font-size: 18px; }
    .toolbar { gap: 8px; }
    #search { flex-basis: calc(100% - 70px); }
    .line { grid-template-columns: 18px 48px minmax(0,1fr) 26px 26px; gap: 5px; padding-inline: 4px; }
    .ts { font-size: 11px; }
    .paneNote { display: none; }
    #live { flex-direction: column; gap: 6px; }
    .row { flex-wrap: wrap; }
    .row > * { min-width: 120px; }
  }

  @media (prefers-reduced-motion: reduce) {
    html { scroll-behavior: auto; }
    *, *::before, *::after {
      scroll-behavior: auto !important;
      animation-duration: .01ms !important;
      animation-iteration-count: 1 !important;
      transition-duration: .01ms !important;
    }
  }
"""#
}
