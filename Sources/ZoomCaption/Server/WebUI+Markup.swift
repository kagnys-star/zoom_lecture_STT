import Foundation

extension WebUI {
  /// 화면 뼈대 (HTML). `WebUI.page` 의 `<body>` 안에 들어간다.
  ///
  /// **값이 들어가는 자리는 전부 빈 채로 둔다.** 서버는 HTML 을 조립하지 않고,
  /// 브라우저가 켜진 뒤 `script` 가 `/api/state` 를 받아 채운다.
  /// 그래서 사용자 기록(자막 본문)이 HTML 문자열에 섞여 들어갈 일이 없다.
  ///
  /// 큰 구획 셋:
  /// - `#stream` — 위 칸. Whisper 기록. 이게 정식 기록이다
  /// - `#fastPane` — 아래 칸. 실시간 전사기. 지금 무슨 말이 나오는지 보는 용도
  /// - 오른쪽 탭 — 요약 · 교안 · 대조 · 세션 · 설정
  ///
  /// 관리자 전용 영역(`#adminBox`, `#quietBox`)은 `display:none` 으로 두고
  /// `/api/admin` 이 켜져 있다고 답할 때만 JS 가 연다.
  static let markup = #"""

<header>
  <span class="brand">ZoomCaption</span>
  <input id="title" value="Zoom 수업" spellcheck="false" aria-label="수업 제목">
  <span class="pill sub" id="sessionChip" style="display:none"></span>
  <span class="pill" id="status"><span class="dot"></span><span id="statusText">대기 중</span><span class="conn" id="connDot" title="서버와 연결됨"></span></span>
  <span class="pill" id="clock">00:00:00</span>
  <span class="spacer"></span>
  <button id="btnStart" class="primary">시작</button>
  <button id="btnStop" class="stop" style="display:none">정지</button>
  <button id="btnQuitTop" class="danger" title="ZoomCaption 앱을 완전히 종료합니다">⏻ 완전 종료</button>
</header>

<!-- 완전 종료 확인 -->
<div id="quitVeil" hidden>
  <div class="quitCard">
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
  <div class="stopCard">
    <h3>마무리하는 중…</h3>
    <p class="stopHint">기록을 정리하는 중입니다. 창을 닫지 말고 잠시만 기다려 주세요.</p>
    <div id="stopStepsBox"></div>
  </div>
</div>

<main>
  <section class="captions">
    <div id="resumeBar">
      <span class="grow" id="resumeText"></span>
      <button id="btnResumeOK" class="sm">알겠습니다</button>
    </div>
    <div id="silentBar">
      <span class="grow" id="silentText"></span>
      <button id="btnSilentOK" class="sm">알겠습니다</button>
    </div>
    <div class="toolbar">
      <span class="paneTag main">Whisper</span>
      <input id="search" type="search" placeholder="자막 검색…" autocomplete="off">
      <button id="btnEdit" class="sm">편집</button>
      <label class="toggle" title="실시간 기록과 갈린 자리에 밑줄을 긋습니다. 눌러서 고칠 수 있습니다.">
        <input type="checkbox" id="showDiv"> 갈린 곳 표시 <b id="divCount"></b></label>
      <label class="toggle"><input type="checkbox" id="autoscroll" checked> 자동 스크롤</label>
      <span class="size-ctl">글자 <input type="range" id="fontSize" min="15" max="34" value="20"></span>
      <span class="size-ctl" id="waitNote"></span>
      <span class="size-ctl" id="count">0줄</span>
    </div>
    <div class="editbar">
      <span class="grow" id="editInfo">줄을 눌러 고치고, 체크해서 지우세요. Shift+클릭으로 구간 선택.</span>
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

  <button id="sideToggle" title="사이드 패널 접기" aria-label="사이드 패널 접기">‹</button>

  <aside>
    <div class="tabs">
      <div class="tab on" data-tab="sum">요약</div>
      <div class="tab" data-tab="doc">교안</div>
      <div class="tab" data-tab="cmp">대조</div>
      <div class="tab" data-tab="pol">다듬기</div>
      <div class="tab" data-tab="ses">세션</div>
      <div class="tab" data-tab="cfg">설정</div>
    </div>

    <!-- 요약 -->
    <div class="panel on" id="panel-sum">
      <div class="field">
        <label for="sumFrom">요약 시작 지점</label>
        <div class="row">
          <input type="text" id="sumFrom" placeholder="전체 (비우면 처음부터)">
          <button id="btnFromLast" class="sm" style="flex:0 0 auto" disabled>이어서</button>
        </div>
        <div class="hint" id="fromHint">자막의 시각을 클릭하면 여기에 들어갑니다.</div>
      </div>
      <div class="row" style="margin-bottom:13px">
        <button id="btnSummarize" class="primary">요약 생성</button>
        <button id="btnMd">MD</button>
        <button id="btnSrt">SRT</button>
      </div>
      <div class="hint" id="engineLine" style="margin-bottom:12px"></div>
      <div id="sumNotice"></div>
      <div class="field" id="saveSummaryBox" style="display:none">
        <label>요약 저장</label>
        <div class="row" style="margin-bottom:6px">
          <input type="text" id="sumDir" placeholder="기본: 수업 폴더" readonly>
          <button id="btnSumPick" class="sm" style="flex:0 0 auto">폴더…</button>
        </div>
        <div class="row">
          <input type="text" id="sumName" placeholder="파일 이름">
          <button id="btnSumSave" class="sm" style="flex:0 0 auto">저장</button>
        </div>
        <div class="hint" id="sumSaveHint"></div>
      </div>
      <div class="field" id="sumFilesBox" style="display:none">
        <label>이 수업에 저장된 요약</label>
        <div id="sumFiles"></div>
      </div>
      <div id="summary"><p class="muted-note">수업이 끝난 뒤 <b>요약 생성</b>을 누르면 전체 기록을 온디바이스 모델로 정리합니다.</p></div>
    </div>

    <!-- 교안 -->
    <div class="panel" id="panel-doc">
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
    <div class="panel" id="panel-cmp">
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
    <div class="panel" id="panel-pol">
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
    <div class="panel" id="panel-ses">
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
    <div class="panel" id="panel-cfg">
      <div id="cfgNotice"></div>

      <!-- 관리자 모드로 켰을 때만 보인다. Zoom 없이 저장된 소리로 전체 경로를 시험한다. -->
      <div class="field" id="adminBox" style="display:none">
        <label>관리자 — 소리 되먹임</label>
        <div class="hint">저장된 WAV를 <b>실제 녹음과 같은 경로</b>로 흘려 넣습니다.
          Zoom도 재생도 필요 없고 실시간보다 빠르게 돌릴 수 있어, 수업 없이 확인할 수 있습니다.
          이 모드에서는 Zoom 외의 소리도 함께 잡습니다.</div>
        <div class="row" style="margin-top:9px">
          <input type="text" id="adminPath" placeholder="WAV 경로 (예: /tmp/sample.wav)">
          <input type="text" id="adminSpeed" value="4" style="flex:0 0 64px" title="배속">
          <button id="btnAdminFeed" class="sm primary" style="flex:0 0 auto">흘려 넣기</button>
          <button id="btnAdminStop" class="sm" style="flex:0 0 auto">멈춤</button>
        </div>
        <div id="adminClips" class="hint" style="margin-top:8px"></div>
        <div id="adminNote"></div>
        <div style="border-top:1px solid var(--line);margin:14px 0 12px"></div>
        <label>관리자 — Zoom 캡처 A/B</label>
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
      <div class="field">
        <label>녹음</label>
        <div class="hint" style="margin-bottom:9px">Zoom 소리만 잡습니다. Zoom 회의 오디오 프로세스를 찾지 못하면 다른 앱의 소리를 잡지 않고 시작을 중단합니다.</div>
        <label class="check"><input type="checkbox" id="keepAudio" checked>
          <span>소리도 함께 저장<span class="hint">수업 폴더에 WAV로 남깁니다(<b>시간당 약 110MB</b>).
          나중에 인식이 틀린 곳을 다시 듣거나 재전사하려면 필요합니다.</span></span></label>
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
        <button id="btnQuit" class="danger" style="width:100%">⏻ ZoomCaption 완전 종료</button>
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
  </aside>
</main>

"""#
}
