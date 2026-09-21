import Foundation

extension WebUI {
  /// 화면 뼈대 (HTML). `WebUI.page` 의 `<body>` 안에 들어간다.
  ///
  /// **값이 들어가는 자리는 전부 빈 채로 둔다.** 서버는 HTML 을 조립하지 않고,
  /// 브라우저가 켜진 뒤 `script` 가 `/api/state` 를 받아 채운다.
  /// 그래서 사용자 기록(자막 본문)이 HTML 문자열에 섞여 들어갈 일이 없다.
  ///
  /// 큰 구획 셋:
  /// - 메인 탭 `#view-whisper` — Whisper 기록과 실시간 전사
  /// - 메인 탭 `#view-summary` — 넓은 화면에서 읽는 전체 요약
  /// - 오른쪽 보조 탭 — 일반 사용자는 교안 · 세션 · 설정, 관리자는 검수·진단 탭 추가
  ///
  /// 관리자 전용 영역은 서버가 정한 body 역할 클래스와 API 403 검사를 함께 쓴다.
  /// CSS는 보이지 않게 만드는 UX 경계이고, 실제 권한 경계는 서버 라우트다.
  static let markup = #"""

<a class="skipLink" href="#primaryWorkspace">자막 화면으로 건너뛰기</a>

<header class="appHeader">
  <div class="headerIdentity">
    <span class="brand"><span class="brandMark" aria-hidden="true">
      <svg viewBox="0 0 24 24" focusable="false"><path d="M5 14v-4M9.5 17V7M14.5 15.5v-7M19 14v-4"/></svg>
    </span><span>ZoomCaption</span></span>
    <span class="administratorBadge administratorOnly" aria-label="관리자 모드">관리자 모드</span>
    <input id="title" value="Zoom 수업" spellcheck="false" aria-label="수업 제목">
    <span class="pill sub" id="sessionChip" style="display:none"></span>
  </div>

  <nav class="workspaceTabs" role="tablist" aria-label="주요 화면">
    <button class="workspaceTab on" id="tab-whisper" type="button" role="tab"
            aria-selected="true" aria-controls="view-whisper" data-view="whisper">
      <span class="tabIcon waveformIcon" aria-hidden="true"><i></i><i></i><i></i><i></i></span>
      <span>Whisper</span>
    </button>
    <button class="workspaceTab" id="tab-summary" type="button" role="tab"
            aria-selected="false" aria-controls="view-summary" data-view="summary">
      <span class="tabIcon summaryIcon" aria-hidden="true"></span><span>요약</span>
    </button>
  </nav>

  <div class="recordingStatus" aria-label="녹음 상태">
    <span class="statusCaption">녹음 상태</span>
    <span class="pill" id="status" role="status" aria-live="polite"><span class="dot" aria-hidden="true"></span><span id="statusText">대기 중</span><span class="conn" id="connDot" title="서버와 연결됨" aria-hidden="true"></span></span>
    <span class="pill clockPill" id="clock">00:00:00</span>
  </div>

  <div class="headerActions">
    <button id="btnStart" class="primary recordAction"><span class="recordGlyph" aria-hidden="true"></span> __RECORD_BUTTON_LABEL__</button>
    <button id="btnStop" class="stop recordAction" style="display:none"><span class="stopGlyph" aria-hidden="true"></span> 녹음 정지</button>
    <button id="btnQuitTop" class="danger quitAction" title="ZoomCaption 앱을 완전히 종료합니다" aria-label="ZoomCaption 완전 종료"><span class="powerGlyph" aria-hidden="true"></span></button>
  </div>
</header>

<!-- 완전 종료 확인 -->
<div id="quitVeil" hidden>
  <div class="quitCard" role="dialog" aria-modal="true" aria-labelledby="quitTitle" aria-describedby="quitBody">
    <h3 id="quitTitle">ZoomCaption을 완전히 종료할까요?</h3>
    <p id="quitBody"></p>
    <div class="quitBtns">
      <button id="quitCancel">취소</button>
      <button id="quitGo" class="stop">완전 종료</button>
    </div>
  </div>
</div>

<!-- 정지 → 마무리 대기. 단계는 JS(stopSteps 배열)가 채운다 —
     지금은 Whisper 정리 한 단계뿐이지만, 나중에 LLM 다듬기를 자동으로 붙이면
     이 카드에 줄이 하나 늘어난다(WebUI+Script.swift 의 stopSteps 주석 참고). -->
<div id="stopVeil" hidden>
  <div class="stopCard" role="dialog" aria-modal="true" aria-labelledby="stopTitle" aria-describedby="stopHint">
    <h3 id="stopTitle">마무리하는 중…</h3>
    <p class="stopHint" id="stopHint">기록을 정리하는 중입니다. 창을 닫지 말고 잠시만 기다려 주세요.</p>
    <div id="stopStepsBox"></div>
  </div>
</div>

<main>
  <div id="primaryWorkspace" tabindex="-1">
    <!-- 어느 메인 탭에 있든 녹음 상태 문제를 놓치지 않도록 공통 영역에 둔다. -->
    <div id="resumeBar">
      <span class="grow" id="resumeText"></span>
      <button id="btnResumeOK" class="sm">알겠습니다</button>
    </div>
    <div id="silentBar">
      <span class="grow" id="silentText"></span>
      <button id="btnSilentOK" class="sm">알겠습니다</button>
    </div>

  <section class="captions workspaceView" id="view-whisper" role="tabpanel"
           aria-labelledby="tab-whisper">
    <div class="toolbar">
      <span class="paneTag main">Whisper</span>
      <label class="srOnly" for="search">자막 검색</label>
      <input id="search" type="search" placeholder="자막 검색…" autocomplete="off">
      <button id="btnEdit" class="sm">편집</button>
      <label class="toggle administratorOnly" title="실시간 기록과 갈린 자리에 밑줄을 긋습니다. 눌러서 고칠 수 있습니다.">
        <input type="checkbox" id="showDiv"> 갈린 곳 표시 <b id="divCount"></b></label>
      <label class="toggle"><input type="checkbox" id="autoscroll" checked> 자동 스크롤</label>
      <fieldset class="captionSizeControl" aria-label="자막 글자 크기">
        <legend>글자</legend>
        <button type="button" data-caption-size="small" aria-pressed="false">작게</button>
        <button type="button" data-caption-size="medium" aria-pressed="true">중간</button>
        <button type="button" data-caption-size="large" aria-pressed="false">크게</button>
      </fieldset>
      <span class="size-ctl" id="waitNote"></span>
      <span class="size-ctl" id="count" role="status" aria-live="polite">0줄</span>
    </div>
    <div class="editbar">
      <span class="grow" id="editInfo">줄을 눌러 고치고, 체크해서 지우세요. Shift+클릭으로 구간 선택.</span>
      <button id="btnTranscriptFile" class="sm" title="시각 없이 문장만 담은 .md 파일을 내려받습니다. 밖에서 고친 뒤 다시 넣을 수 있습니다.">문장 .md 내보내기</button>
      <button id="btnTranscriptImport" class="sm" title="내보낸 문장 파일을 고쳐서 다시 넣습니다.">되넣기</button>
      <input id="transcriptFileInput" type="file" accept=".md,.markdown,.txt" hidden>
      <button id="btnDelSel" class="danger sm" disabled>선택 삭제</button>
      <button id="btnEditDone" class="sm">완료</button>
    </div>
    <div id="divBar"></div>
    <div id="stream">
      <div class="empty" id="empty">
        <span id="emptyMain">아직 Whisper 자막이 없습니다.<br>
        <kbd>시작</kbd> 을 누르면 아래에 실시간 자막이 먼저 흐르고,<br>
        30초쯤 뒤부터 여기에 정확한 자막이 쌓입니다.</span>
        <div id="emptyWhy" class="notice warn" style="display:none;margin:16px auto 0;max-width:520px;text-align:left"></div>
      </div>
    </div>

    <!-- 아래 칸: 실시간 전사기. 지금 무슨 말이 나오는지 보는 용도라 최근 것만 남긴다. -->
    <div id="fastPane">
      <div class="paneBar">
        <span class="paneTag fast">실시간</span>
        <span class="paneNote">SpeechTranscriber · Whisper가 정리하기 전까지만 표시 (전부 저장됩니다)</span>
        <span class="spacer"></span>
        <span class="paneNote" id="fastCount"></span>
      </div>
      <div id="fastStream"></div>
      <div id="live" hidden>
        <span class="liveTag">받아쓰는 중</span>
        <span id="liveText"></span>
      </div>
    </div>
  </section>

  <!-- 전체 너비 읽기 화면. 기존 id를 유지해 서버 상태·SSE 연결을 그대로 쓴다. -->
  <section class="workspaceView summaryView" id="view-summary" role="tabpanel"
           aria-labelledby="tab-summary" hidden>
    <div class="summaryScroll">
      <div class="summaryShell">
        <div class="summaryHead">
          <div>
            <h1>수업 요약</h1>
            <div class="summaryMeta">
              <span id="engineLine"></span><span id="summarySource">현재 세션 요약</span>
              <button id="btnCurrentSummary" type="button" style="display:none">현재 요약으로 돌아가기</button>
            </div>
          </div>
          <div class="summaryHeadActions">
            <button id="btnCancelSummary" class="sm" style="display:none"
                    title="진행 중인 로컬 요약을 중단합니다">요약 취소</button>
            <button id="btnSummarize" class="primary">요약 생성</button>
          </div>
        </div>

        <!-- 한 버튼이 선택한 엔진에 따라 로컬 실행 또는 온라인 프롬프트 반출을 맡는다.
             온라인 결과는 브라우저 클립보드 읽기 권한에 기대지 않고 파일/붙여넣기로 받는다. -->
        <div class="summaryOnline">
          <fieldset class="onlineTargets" id="onlineTargets">
            <legend>요약 모델</legend>
            <label class="onlineTargetOption">
              <input type="radio" name="onlineTarget" value="local" checked>
              <span>로컬 모델</span>
            </label>
            <label class="onlineTargetOption">
              <input type="radio" name="onlineTarget" value="claude">
              <span>Claude</span>
            </label>
            <label class="onlineTargetOption">
              <input type="radio" name="onlineTarget" value="chatgpt">
              <span>ChatGPT</span>
            </label>
            <label class="onlineTargetOption">
              <input type="radio" name="onlineTarget" value="gemini">
              <span>Gemini</span>
            </label>
          </fieldset>
          <div class="onlineActions">
            <button id="btnPromptFile" class="sm" style="display:none">프롬프트 .md 저장</button>
            <button id="btnImportSummary" class="sm" style="display:none">요약 .md 불러오기</button>
            <input id="summaryFileInput" type="file" accept=".md,.markdown,.txt" hidden>
          </div>
        </div>
        <div id="onlineStep" class="onlineStep" role="status" aria-live="polite" style="display:none"></div>

        <div class="summaryControls">
          <div class="summaryRange">
            <label for="sumRangeStart">요약 범위</label>
            <div class="summaryRangeRow">
              <select id="sumRangeStart" aria-label="요약 시작 구간">
                <option value="">처음부터</option>
              </select>
              <span aria-hidden="true">~</span>
              <select id="sumRangeEnd" aria-label="요약 종료 구간">
                <option value="">끝까지</option>
              </select>
              <button id="btnFromLast" class="sm" style="flex:0 0 auto" disabled>이어서</button>
            </div>
            <div class="hint" id="sumRangeHint">구간을 고르지 않으면 전체를 요약합니다.</div>
          </div>
          <div class="summarySave" id="saveSummaryBox" style="display:none">
            <label for="sumName">요약 저장</label>
            <div class="row">
              <input type="text" id="sumName" placeholder="파일 이름">
              <button id="btnSumSave" class="sm" style="flex:0 0 auto">저장</button>
            </div>
            <div class="row summarySaveDestination">
              <input type="text" id="sumDir" placeholder="기본: 수업 폴더" readonly>
              <button id="btnSumPick" class="sm" style="flex:0 0 auto">폴더…</button>
            </div>
            <div class="hint" id="sumSaveHint"></div>
          </div>
          <div id="summaryProgress" class="summaryProgress" role="status" aria-live="polite"></div>
        </div>

        <div id="sumNotice"></div>
        <!-- 빈 상태 안내는 WebUI+Script.swift의 showCurrentSummary()가 요약이 없을 때
             내놓는 내용과 반드시 같아야 한다 — 새로고침 직후엔 이 정적 HTML이,
             그 뒤로는 JS가 같은 문구를 그린다. 한쪽만 고치면 새로고침 타이밍에 따라
             안내가 갈린다. -->
        <article id="summary" aria-live="polite" class="onlineHelp">
          <p class="muted-note">이 수업의 전체 기록을 정리합니다. 위 <b>요약 모델</b>에서 방식을 고른 뒤 진행하세요.</p>
          <p class="muted-note"><b>로컬 모델</b> — 이 기기에 설치된 Qwen이 인터넷 연결 없이 정리합니다. <b>요약 생성</b>을 누르면 바로 시작되고, 진행 중에는 <b>요약 취소</b>로 멈출 수 있습니다.</p>
          <p class="muted-note"><b>Claude · ChatGPT · Gemini</b> — API 키 없이 각 서비스의 웹 화면을 그대로 씁니다. 이 앱이 로그인하거나 화면을 대신 조작하지 않고, 붙여넣을 프롬프트만 준비합니다.</p>
          <ol class="muted-note">
            <li>위에서 Claude · ChatGPT · Gemini 중 하나를 고르고, 필요하면 <b>요약 범위</b>로 구간을 지정합니다.</li>
            <li><b>프롬프트 복사하고 열기</b>를 누르면 프롬프트가 클립보드에 복사되고 그 서비스의 새 탭이 열립니다.</li>
            <li>새 탭에서 <kbd>⌘V</kbd>로 붙여넣고 Enter를 누릅니다.</li>
            <li>모델이 만든 문서(아티팩트·캔버스)를 .md 파일로 내려받습니다.</li>
            <li>내려받은 파일을 이 화면에 끌어다 놓거나, <b>요약 .md 불러오기</b>로 고르거나, 내용을 그대로 붙여넣습니다 — 확인 뒤 자동으로 요약에 반영됩니다.</li>
          </ol>
          <p class="muted-note">온라인 모델을 쓰면 이 수업의 기록이 그 서비스로 전달됩니다. 각 서비스의 대화 학습 사용 설정을 먼저 확인하세요.</p>
        </article>

        <div class="summaryUtilities">
          <details class="summaryUtility" id="sumFilesBox" style="display:none">
            <summary>이 수업에 저장된 요약</summary>
            <div class="summaryUtilityBody" id="sumFiles"></div>
          </details>
        </div>
      </div>
    </div>
  </section>
  </div>

  <button id="sideToggle" title="사이드 패널 접기" aria-label="사이드 패널 접기"
          aria-controls="utilityPanel" aria-expanded="true"><span aria-hidden="true">‹</span></button>

  <aside id="utilityPanel" aria-label="교안, 세션 및 설정">
    <div class="tabs" role="tablist" aria-label="보조 도구">
      <button class="tab on" id="side-tab-doc" type="button" role="tab" aria-selected="true"
              aria-controls="panel-doc" data-tab="doc">교안</button>
      <button class="tab" id="side-tab-ses" type="button" role="tab" aria-selected="false"
              aria-controls="panel-ses" data-tab="ses">세션</button>
      <button class="tab" id="side-tab-cfg" type="button" role="tab" aria-selected="false"
              aria-controls="panel-cfg" data-tab="cfg">설정</button>
      <button class="tab administratorOnly" id="side-tab-cmp" type="button" role="tab"
              aria-selected="false" aria-controls="panel-cmp" data-tab="cmp">대조</button>
      <button class="tab administratorOnly" id="side-tab-pol" type="button" role="tab"
              aria-selected="false" aria-controls="panel-pol" data-tab="pol">다듬기</button>
      <button class="tab administratorOnly" id="side-tab-adm" type="button" role="tab"
              aria-selected="false" aria-controls="panel-adm" data-tab="adm">오디오 진단</button>
    </div>

    <!-- 교안 -->
    <div class="panel on" id="panel-doc" role="tabpanel" aria-labelledby="side-tab-doc">
      <div class="field">
        <label>교안 PDF</label>
        <div class="drop" id="drop">
          PDF를 끌어다 놓거나 눌러서 고르세요<br>
          <span style="font-size:12px">교안 용어를 인식 힌트와 요약 용어집으로 씁니다</span>
        </div>
        <input type="file" id="pdfInput" accept="application/pdf,.pdf" style="display:none">
      </div>
      <div id="docInfo"></div>
    </div>

    <!-- 대조 -->
    <div class="panel administratorOnly" id="panel-cmp" role="tabpanel" aria-labelledby="side-tab-cmp">
      <div id="cmpNotice"></div>
      <div id="cmpStat"></div>
      <div class="field" id="quietBox" style="display:none;padding-top:16px;border-top:1px solid var(--line)">
        <label>무음 의심 (관리자)</label>
        <div class="hint">Whisper 는 30초 덩어리를 받으면 <b>끝까지 뭔가를 채워야 하는 구조</b>라,
          소리가 없는 구간에서도 문장을 지어냅니다(「감사합니다」, 「자막 제공 및 광고를…」).
          실시간 전사기는 음성 활동 검출이 들어 있어 이런 오류가 없습니다.
          여기서는 <b>지우지 않고 표시만</b> 합니다 — 눌러서 직접 들어 보시고 판단하세요.</div>
        <div class="row" style="margin-top:9px">
          <button id="btnQuiet" class="sm">무음 구간 찾기</button>
        </div>
        <div id="quietResult"></div>
      </div>

      <div class="field" style="padding-top:16px;border-top:1px solid var(--line)">
        <label>표본 모으기</label>
        <div class="hint">갈린 자리의 <b>소리를 듣고 어느 쪽이 맞는지 고르기만</b> 하면 됩니다.
          받아쓰기가 아니라서 한 지점에 몇 초면 끝납니다.
          숫자키 <b>1~4</b>로 고르고 <b>Space</b>로 다시 듣습니다.</div>
        <div id="goldScore"></div>
        <div id="goldAll" class="hint" style="margin-top:7px"></div>
        <div class="row" style="margin-top:9px">
          <button id="btnGold" class="sm primary" style="flex:0 0 auto">표본 모으기 시작</button>
          <label class="toggle" style="font-size:12.5px">
            <input type="checkbox" id="goldSkip" checked> 판정한 지점 건너뛰기</label>
          <button id="btnCorrectRevert" class="sm danger" style="display:none;flex:0 0 auto">교정 되돌리기</button>
        </div>
        <div id="goldCard" class="goldCard" style="display:none">
          <div class="goldTrack"><div id="goldFill"></div></div>
          <div class="goldHead">
            <span><b id="goldPos">0</b> / <span id="goldTotal">0</span></span>
            <span id="goldWhen"></span>
          </div>
          <button id="goldPlay" class="goldPlay">▶ 소리 듣기</button>
          <button class="goldOpt" data-v="live"><kbd>1</kbd><span class="who">실시간</span>
            <span class="val" id="goldLive"></span></button>
          <button class="goldOpt" data-v="whisper"><kbd>2</kbd><span class="who">Whisper</span>
            <span class="val" id="goldWhisper"></span></button>
          <button class="goldOpt" data-v="both"><kbd>3</kbd><span class="who">둘 다 아님</span>
            <span class="val">직접 적기</span></button>
          <button class="goldOpt" data-v="unclear"><kbd>4</kbd><span class="who">모르겠음</span>
            <span class="val">넘기기</span></button>
          <div id="goldTruthWrap" class="row" style="display:none;margin-top:7px">
            <input type="text" id="goldTruth" placeholder="실제로 들린 내용">
            <button id="goldTruthOk" class="sm primary" style="flex:0 0 auto">확인</button>
          </div>
          <div class="goldKeys">Space 다시 듣기 · 1~4 판정 · ← 이전 · Esc 그만</div>
        </div>
      </div>

    </div>

    <!-- 다듬기 (미리보기 단계 — 원문은 아직 안 건드림) -->
    <div class="panel administratorOnly" id="panel-pol" role="tabpanel" aria-labelledby="side-tab-pol">
      <div class="field">
        <label>문맥 다듬기 (미리보기)</label>
        <div class="hint">강의 전체를 다시 훑어서, 음성 인식이 잘못 알아들어 표기가
          갈린 자리(예: 「빔 팩토리」 ↔ 「Bean Factory」)를 찾습니다.
          <b>여기서는 제안만 보여줄 뿐, 원문을 바로 고치지는 않습니다.</b></div>
        <div class="row" style="margin-top:9px">
          <button id="btnPolish" class="sm primary" style="flex:0 0 auto">다듬기 확인</button>
        </div>
      </div>
      <div id="polNotice"></div>
      <div id="polResult"></div>
    </div>

    <!-- 세션 -->
    <div class="panel" id="panel-ses" role="tabpanel" aria-labelledby="side-tab-ses">
      <div id="sesNotice"></div>
      <div class="field">
        <label>현재 세션</label>
        <div class="card current" id="curSession">
          <div class="meta"><div class="name" id="curName">저장 폴더 없음</div>
          <div class="sub" id="curSub">시작하면 폴더가 만들어집니다</div></div>
        </div>
        <div class="row" style="margin-top:9px">
          <button id="btnNewSession" class="sm">새 세션</button>
          <button id="btnSave" class="sm">지금 저장</button>
        </div>
        <div class="row" style="margin-top:8px">
          <button id="btnMd" class="sm" title="요약과 전체 기록이 들어 있는 Markdown을 저장합니다">전체 기록 MD</button>
          <button id="btnSrt" class="sm" title="Whisper 자막을 SRT로 저장합니다">자막 SRT</button>
        </div>
      </div>
      <div class="field">
        <label>저장된 수업 — 눌러서 이어 적기</label>
        <div id="sessionList"><div class="hint">아직 저장된 수업이 없습니다.</div></div>
        <div class="row" style="margin-top:9px">
          <button id="btnOpenElsewhere" class="sm" style="flex:0 0 auto">다른 위치에서 열기…</button>
        </div>
      </div>
    </div>

    <!-- 설정 -->
    <div class="panel" id="panel-cfg" role="tabpanel" aria-labelledby="side-tab-cfg">
      <div id="cfgNotice"></div>
      <div class="field">
        <label>녹음</label>
        <div class="hint">Zoom 소리를 정확한 자막으로 바꾸기 위해 오디오는 이 Mac 안에서만
          처리됩니다. Zoom 회의 오디오 프로세스를 찾지 못하면 다른 앱의 소리를 잡지 않고
          시작을 중단합니다.</div>
      </div>
      <div class="field">
        <label>저장 및 개인정보</label>
        <label class="check"><input type="checkbox" id="retainOriginalAudio" checked>
          <span>Whisper 처리 후 원본 소리 보관<span class="hint">켜면 수업 폴더에 WAV를 남겨
          다시 듣기와 재전사에 사용할 수 있습니다(<b>시간당 약 110MB</b>). 꺼도 정확한
          Whisper 자막은 만들며, 처리가 안전하게 끝난 뒤 원본 소리만 삭제합니다.</span></span></label>
        <div id="audioStorageStatus" class="hint" aria-live="polite"></div>
      </div>
      <div class="field">
        <label>저장 위치</label>
        <div class="row">
          <input type="text" id="baseDir" placeholder="비우면 기본 위치" readonly>
          <button id="btnPick" class="sm" style="flex:0 0 auto">폴더 선택…</button>
        </div>
        <div class="hint">이 폴더 <b>안에</b> 이번 수업 폴더가 새로 만들어집니다.</div>
      </div>
      <div class="field">
        <label for="folder">수업 폴더 이름</label>
        <input type="text" id="folder" placeholder="비우면 날짜_제목 으로 자동 생성">
      </div>
      <div class="field">
        <label>앱 종료</label>
        <button id="btnQuit" class="danger" style="width:100%"><span class="powerGlyph" aria-hidden="true"></span> ZoomCaption 완전 종료</button>
        <div class="hint">브라우저 탭만 닫으면 앱은 뒤에서 계속 돌아갑니다.
          정말 끄려면 이 버튼(또는 위쪽 <b>완전 종료</b>)을 누르세요.</div>
      </div>

      <div class="field" style="margin-top:22px;padding-top:18px;border-top:1px solid var(--line)">
        <label>문제 해결</label>
        <div id="diagBox" class="hint">불러오는 중…</div>
        <div class="row" style="margin-top:9px">
          <button id="btnLogs" class="sm">로그 보기</button>
          <button id="btnLogFolder" class="sm">로그 폴더 열기</button>
          <button id="btnCopyDiag" class="sm">진단 복사</button>
        </div>
        <div class="row" style="margin-top:7px">
          <button id="btnClearCache" class="sm">교안 캐시 비우기</button>
        </div>
        <pre id="logView"></pre>
      </div>
    </div>

    <!-- 관리자 실행 진입점에서만 화면에 나타난다. 일반 모드에서는 CSS뿐 아니라
         모든 관련 API도 서버에서 403으로 막아 개발자 도구로 표시를 바꿔도 실행되지 않는다. -->
    <div class="panel administratorOnly" id="panel-adm" role="tabpanel" aria-labelledby="side-tab-adm">
      <div class="notice warn"><b>관리자 진단 모드</b><br>
        테스트 캡처에는 Zoom 밖의 시스템 소리가 포함될 수 있습니다. 실사용 녹음을 멈춘
        상태에서 전용 저장 위치와 포트로만 사용하세요.</div>
      <div class="field" id="adminBox">
        <label>소리 되먹임</label>
        <div class="hint">저장된 WAV를 <b>실제 녹음과 같은 경로</b>로 흘려 넣습니다.
          Zoom도 재생도 필요 없고 실시간보다 빠르게 돌릴 수 있어, 수업 없이 확인할 수 있습니다.</div>
        <div class="row" style="margin-top:9px">
          <input type="text" id="adminPath" placeholder="WAV 경로 (예: /tmp/sample.wav)">
          <input type="text" id="adminSpeed" value="4" style="flex:0 0 64px" title="배속">
          <button id="btnAdminFeed" class="sm primary" style="flex:0 0 auto">흘려 넣기</button>
          <button id="btnAdminStop" class="sm" style="flex:0 0 auto">멈춤</button>
        </div>
        <div id="adminClips" class="hint" style="margin-top:8px"></div>
        <div id="adminNote"></div>
        <div style="border-top:1px solid var(--line);margin:14px 0 12px"></div>
        <label>Zoom 캡처 A/B</label>
        <div class="hint">운영 녹음을 정지한 상태에서 후보 하나씩 측정합니다. 오디오는
          저장하거나 전사하지 않습니다. 같은 경로를 초기화해 ① 원격만 재생, ② 원격을
          멈추고 로컬 마이크로 고유 문구 발화 순서로 비교하세요.</div>
        <div class="row" style="margin-top:9px">
          <select id="adminProbeProcess" aria-label="A/B 오디오 프로세스"></select>
          <button id="btnAdminProbeRefresh" class="sm" style="flex:0 0 auto">후보 새로고침</button>
        </div>
        <div class="row" style="margin-top:8px">
          <select id="adminProbeRoute" aria-label="A/B 출력 경로"></select>
          <button id="btnAdminProbeStart" class="sm primary" style="flex:0 0 auto">측정 시작·초기화</button>
          <button id="btnAdminProbeStop" class="sm" style="flex:0 0 auto">측정 종료</button>
        </div>
        <div id="adminProbeResult" class="hint" style="margin-top:8px"></div>
      </div>
    </div>
  </aside>
</main>

"""#
}
