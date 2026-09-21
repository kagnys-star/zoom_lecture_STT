import Foundation

extension WebUI {
  /// 화면 동작 전부 (JS). `WebUI.page` 의 `<script>` 안에 들어간다.
  ///
  /// **서버와 이어지는 방식.** SSE(`/events`) 한 줄로 이어져 있다. 끊기면 브라우저가
  /// 자동으로 다시 붙는데, 그때 `Last-Event-ID` 를 보내 **빠진 것만** 받아 온다.
  /// 이어 붙일 수 없을 때(서버가 다시 뜬 경우 등)만 `resync` 로 전체를 다시 받는다.
  /// 90분 수업의 `/api/state` 는 수백 KB 라, 주기 확인에는 가벼운 `/api/sync` 를 쓴다.
  ///
  /// **고칠 때 주의.** 이 안의 요소 참조(`$('#...')`)가 `WebUI+Markup.swift` 에
  /// 실제로 있는지 반드시 맞춰야 한다. 없는 id 를 만지면 그 줄에서 스크립트가 멈추고
  /// **그 아래가 전부 죽는다** — 지운 버튼의 처리기를 안 지워 실제로 겪었다.
  /// 아래 한 줄로 확인할 수 있다:
  /// ```
  /// grep -o "\$('#[a-zA-Z]*')" WebUI+Script.swift | sort -u
  /// ```
  ///
  /// 구획은 파일 안에 `// ── 이름 ──` 으로 나눠 두었다.
  static let script = #"""
(() => {
  const $ = s => document.querySelector(s);
  const stream = $('#stream'), live = $('#live'), liveText = $('#liveText'), empty = $('#empty');
  const fastStream = $('#fastStream');

  // 아래 칸은 "지금 무슨 말이 나오나" 를 보는 용도다. Whisper 가 이미 정리해서 위 칸에
  // 올려놓은 구간은 아래 칸에서 뺀다 — 같은 내용이 두 번 보일 이유가 없고, 위 칸(문단화된
  // Whisper)이 더 정확하다. 저장은 서버가 전부 하고 있고, 정식 기록은 위 칸이다.
  //
  // Whisper 가 못 따라오거나(밀림) 아예 꺼져 있으면 whisperCoverEnd 가 안 늘어나는데,
  // 그럴 때도 90분치가 DOM 에 쌓여 렌더가 끊기면 안 되므로 SAFETY_WINDOW 로 상한을 둔다
  // (최근 값 기준 최대 3분 — 정상 상황에서 Whisper 지연은 60~90초대라 이 안에서는
  // whisperCoverEnd 가 항상 이긴다).
  const SAFETY_WINDOW = 180;
  let whisperCoverEnd = 0;   // Whisper 가 지금까지 처리한 구간의 끝(초). 이 전은 아래 칸에서 뺀다.
  let fastTotal = 0;

  function fastCutoff(now) { return Math.max(whisperCoverEnd, now - SAFETY_WINDOW); }

  function addFast(seg) {
    const el = document.createElement('div');
    el.className = 'fline';
    el.dataset.start = seg.start; el.dataset.id = seg.id;
    el.innerHTML = `<span class="t">${clock(seg.start)}</span><span>${esc(seg.text)}</span>`;
    setLectureBoundaryMarker(el, seg.boundaryAfter);
    fastStream.appendChild(el);
    fastTotal++;
    trimFast(fastCutoff(seg.start));
    fastStream.scrollTop = fastStream.scrollHeight;
    $('#fastCount').textContent = fastTotal + '줄 저장됨';
  }

  function trimFast(cutoff) {
    for (const el of [...fastStream.children]) {
      if (parseFloat(el.dataset.start) < cutoff && fastStream.children.length > 1) el.remove();
      else break;
    }
  }

  // Whisper 쪽 목록이 바뀔 때마다(새 조각·문단화 확정 포함) 부른다. 커버리지가 늘어난
  // 만큼 아래 칸에서 겹치는 줄을 뺀다. 뒤로 갈 일은 없으니(Whisper 는 계속 앞으로만
  // 나아간다) 줄어드는 방향은 고려하지 않는다.
  function extendCoverage(end) {
    if (end <= whisperCoverEnd) return;
    whisperCoverEnd = end;
    trimFast(whisperCoverEnd);
  }
  let running = false, startedAt = null, tick = null;
  let lines = new Map();      // id -> element
  let lastPicked = null;
  let state = {};
  let summaryTargets = {
    local: { name: '로컬 모델', url: '' },
    claude: { name: 'Claude', url: 'https://claude.ai/new' },
    chatgpt: { name: 'ChatGPT', url: 'https://chatgpt.com/' },
    gemini: { name: 'Gemini', url: 'https://gemini.google.com/app' },
  };
  let promptRequestGeneration = 0;
  let onlineEnvironmentLogged = false;
  const isAdministratorMode = document.body.classList.contains('administrator-mode');

  // 자막 크기는 사용자가 의미를 알기 어려운 15~34 연속 숫자가 아니라, 반복해서
  // 같은 결과를 얻을 수 있는 세 가지 읽기 단계로만 제공한다. 픽셀 값은 이 한곳에
  // 모아 CSS와 저장값이 서로 다른 크기를 가리키지 않게 한다.
  const captionSizePixelsByPreference = Object.freeze({ small: 12, medium: 16, large: 20 });
  const captionLineHeightByPreference = Object.freeze({ small: 1.4, medium: 1.55, large: 1.7 });
  const captionRowPaddingByPreference = Object.freeze({ small: '4px', medium: '7px', large: '10px' });
  const captionSizeStorageKey = 'zoomcaption.captionSize';
  const originalAudioRetentionStorageKey = 'zoomcaption.retainOriginalAudio';

  const esc = s => String(s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
  const clock = t => {
    t = Math.max(0, Math.floor(t));
    return [t/3600|0, (t%3600)/60|0, t%60].map(n => String(n).padStart(2,'0')).join(':');
  };

  // 강의 종료는 실제 전사 문구가 아니라 Segment의 구조화된 boundaryAfter 값이다.
  // 같은 렌더 함수를 Whisper 줄과 실시간 폴백 줄에 써야 SSE와 /api/state 재동기화가
  // 어느 경로로 들어와도 똑같이 보인다. 이미 있는 표식은 갱신하고, 값이 사라지면
  // DOM에서도 제거해 서버 상태를 유일한 진실로 유지한다.
  function setLectureBoundaryMarker(lineElement, boundaryAfter) {
    let marker = lineElement.querySelector('.lectureEndMarker');
    // 서버의 구조화 경계 값에만 라벨을 연결해야 발화 텍스트를 오염시키지 않고, 알 수
    // 없는 미래 값도 잘못 표시하는 대신 안전하게 기존 표식을 제거할 수 있다.
    const boundaryLabels = { lectureEnded: '강의 종료', recordingStopped: '녹음 종료' };
    const boundaryLabel = boundaryLabels[boundaryAfter];
    // 편집 버튼의 눌림 상태도 여기서 맞춘다. 자동 경계·SSE·재동기화가 모두 이 함수를
    // 거치므로, 어느 경로로 값이 바뀌어도 버튼과 표식이 갈리지 않는다.
    const boundaryButton = lineElement.querySelector('.bnd');
    if (boundaryButton) {
      boundaryButton.setAttribute('aria-pressed', boundaryLabel ? 'true' : 'false');
      boundaryButton.title = boundaryLabel
        ? '이 줄의 강의 종료 표시를 지웁니다' : '여기서 강의가 끝났다고 표시합니다';
    }
    if (!boundaryLabel) {
      delete lineElement.dataset.boundaryAfter;
      if (marker) marker.remove();
      return;
    }
    lineElement.dataset.boundaryAfter = boundaryAfter;
    if (!marker) {
      marker = document.createElement('span');
      marker.className = 'lectureEndMarker';
      lineElement.appendChild(marker);
    }
    marker.textContent = boundaryLabel;
  }
  const post = (url, body) => fetch(url, {
    method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body || {})
  }).then(r => r.json());

  // 프라이버시 약속 때문에 이 통로에는 전사·프롬프트·요약 본문을 절대 싣지 않는다.
  // 브라우저 종류, API 지원 여부, 본문 길이, 오류 이름/메시지 같은 진단 메타데이터만
  // 보낸다. 로그 전송 자체가 실패하면 재귀 전송하지 않고 콘솔에 원래 오류를 남긴다.
  function clientLog(level, message) {
    fetch('/api/clientLog', {
      method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({ level, message: String(message || '').slice(0, 500) }),
    }).catch(clientLogError => console.warn('클라이언트 로그 전송 실패', clientLogError));
  }

  function errorDescription(error) {
    const errorName = error?.name || error?.constructor?.name || 'Error';
    const errorMessage = error?.message || String(error || '알 수 없는 오류');
    return `${errorName}: ${errorMessage}`;
  }

  let toastTimer = null;
  function toast(text) {
    let el = $('#toast');
    if (!el) {
      el = document.createElement('div'); el.id = 'toast'; document.body.appendChild(el);
    }
    el.textContent = text;
    el.classList.add('on');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove('on'), 2200);
  }

  // ── 갈린 곳 표시 ──
  //
  // Whisper 기록을 원안으로 두고, 실시간 기록과 갈린 자리에만 점선을 긋는다.
  // 누르면 실시간 쪽이 뭐라고 적었는지 바로 아래에 펴 보이고, 골라서 고친다.
  //
  // 고르는 행위 하나가 두 가지 일을 한다 — 기록을 바로잡고, **정답지 표본이 된다.**
  // 표본을 모으려고 따로 시간을 낼 필요가 없는 게 이 방식의 핵심이다.
  const divs = new Map();          // segID → [블록…] (rangeStart 오름차순)
  let divSettled = -1;             // 이 시각까지만 비교됐다. -1 이면 제한 없음
  let divOpen = null;              // 지금 펴 놓은 자리

  const divKey = b => `${b.segID}:${b.rangeStart}:${b.rangeEnd}`;
  const divSeen = new Set();       // 이미 판정한 자리 (표시만 남긴다)

  async function loadDivs() {
    if (!$('#showDiv').checked) return;
    let d;
    try { d = await fetch('/api/compare').then(r => r.json()); } catch { return; }
    if (!d || !d.blocks) return;
    divs.clear();
    divSettled = (d.settledUntil === undefined) ? -1 : d.settledUntil;
    for (const b of d.blocks) {
      if (!b.mark || b.segID < 0) continue;
      if (!divs.has(b.segID)) divs.set(b.segID, []);
      divs.get(b.segID).push(b);
    }
    for (const list of divs.values()) list.sort((x, y) => x.rangeStart - y.rangeStart);
    let n = 0; for (const l of divs.values()) n += l.length;
    $('#divCount').textContent = n ? `(${n})` : '';
    const bar = $('#divBar');
    if (!d.hasBoth) {
      bar.innerHTML = '두 기록이 다 있어야 갈린 곳을 찾을 수 있습니다. ' +
        'Whisper 가 아직 안 돌았거나 실시간 기록이 없습니다.';
    } else if (divSettled >= 0) {
      bar.innerHTML = `갈린 곳 <b>${n}</b>곳. 녹음 중이라 <b>${clock(divSettled)}</b> 까지만 ` +
        '비교했습니다 — Whisper 가 뒤에서 따라오는 중이라 그 뒤는 아직 정해지지 않았습니다.';
    } else {
      bar.innerHTML = `갈린 곳 <b>${n}</b>곳. 점선을 눌러 실시간 기록과 견주어 고치세요. ` +
        '고른 것은 정답지 표본으로도 쌓입니다.';
    }
    bar.style.display = '';
    stream.querySelectorAll('.line').forEach(paintDivs);
  }

  /// 한 줄의 본문을 다시 그리면서 갈린 구간에 점선을 넣는다.
  function paintDivs(el) {
    const txt = el.querySelector('.txt');
    if (!txt || txt.getAttribute('contenteditable') === 'true') return;
    const id = +el.dataset.id;
    const list = $('#showDiv').checked ? (divs.get(id) || []) : [];
    const s = el.dataset.text || '';
    if (!list.length) { txt.innerHTML = esc(s); return; }
    let out = '', at = 0;
    for (const b of list) {
      // 그 사이 본문이 바뀌었으면 자리를 못 믿는다. 조용히 건너뛴다.
      if (b.rangeStart < at || b.rangeEnd > s.length) continue;
      if (s.slice(b.rangeStart, b.rangeEnd) !== b.whisperRaw) continue;
      const cls = divSeen.has(divKey(b)) ? 'dv kept' : 'dv';
      out += esc(s.slice(at, b.rangeStart)) +
        `<span class="${cls}" data-dk="${esc(divKey(b))}">${esc(b.whisperRaw)}</span>`;
      at = b.rangeEnd;
    }
    out += esc(s.slice(at));
    txt.innerHTML = out;
  }

  function findDiv(key) {
    for (const list of divs.values()) for (const b of list) if (divKey(b) === key) return b;
    return null;
  }

  /// 갈린 자리를 눌렀을 때 그 줄 아래에 펴 보인다.
  function openDiv(span, el) {
    closeDiv();
    const b = findDiv(span.dataset.dk);
    if (!b) return;
    span.classList.add('open');
    const box = document.createElement('div');
    box.className = 'fixBox';
    const liveVal = b.liveRaw || b.live || '(실시간 기록 없음)';
    box.innerHTML =
      `<div class="fbRow"><span class="fbWho">Whisper</span>` +
      `<span class="fbVal">${esc(b.whisperRaw)}</span></div>` +
      `<div class="fbRow" style="margin-top:5px"><span class="fbWho">실시간</span>` +
      `<span class="fbVal">${esc(liveVal)}</span></div>` +
      `<div class="fbBtns">` +
      `<button class="sm primary" data-fx="live"${b.liveRaw ? '' : ' disabled'}>` +
      `<kbd>1</kbd>실시간 것으로</button>` +
      `<button class="sm" data-fx="whisper"><kbd>2</kbd>원안이 맞음</button>` +
      `<button class="sm" data-fx="type"><kbd>3</kbd>직접 입력</button>` +
      `<button class="sm" data-fx="play">▶ 소리</button>` +
      `<button class="sm" data-fx="close">닫기</button></div>` +
      `<div class="fbNote">고른 것은 <b>정답지 표본</b>으로 남습니다. ` +
      `되돌리려면 대조 탭의 ‘교정 되돌리기’.</div>`;
    el.after(box);
    divOpen = { span, box, block: b, line: el };
    box.querySelectorAll('button').forEach(btn => {
      btn.onclick = e => { e.stopPropagation(); handleFix(btn.dataset.fx); };
    });
    box.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  }

  function closeDiv() {
    if (!divOpen) return;
    divOpen.span.classList.remove('open');
    divOpen.box.remove();
    divOpen = null;
  }

  async function handleFix(what) {
    if (!divOpen) return;
    const { block: b, line: el, box } = divOpen;
    if (what === 'close') { closeDiv(); return; }
    if (what === 'play') {
      const from = Math.max(0, b.start - 1.0);
      const to = b.end > b.start + 0.5 ? b.end + 2.0 : b.start + 6.0;
      new Audio(`/api/audio?from=${from.toFixed(2)}&to=${to.toFixed(2)}`).play().catch(() => {});
      return;
    }
    if (what === 'type') {
      if (box.querySelector('input[type=text]')) return;
      const row = document.createElement('div');
      row.className = 'fbRow'; row.style.marginTop = '9px';
      row.innerHTML = `<input type="text" placeholder="실제로 들린 내용" value="${esc(b.whisperRaw)}">` +
                      `<button class="sm primary" style="flex:0 0 auto">확인</button>`;
      box.querySelector('.fbBtns').after(row);
      const input = row.querySelector('input');
      input.focus(); input.select();
      const send = () => sendFix('both', input.value);
      row.querySelector('button').onclick = e => { e.stopPropagation(); send(); };
      input.onkeydown = e => {
        e.stopPropagation();
        if (e.key === 'Enter') send();
        if (e.key === 'Escape') row.remove();
      };
      return;
    }
    if (what === 'live')    return sendFix('live', b.liveRaw);
    if (what === 'whisper') return sendFix('whisper', b.whisperRaw);
  }

  async function sendFix(verdict, after) {
    if (!divOpen) return;
    const { block: b, line: el, span } = divOpen;
    const r = await post('/api/fix', {
      segID: b.segID, rangeStart: b.rangeStart, rangeEnd: b.rangeEnd,
      before: b.whisperRaw, after: after || '', verdict,
      start: b.start, end: b.end, kind: b.kind, live: b.liveRaw || b.live || '',
    });
    if (!r || !r.ok) { toast(r && r.error || '고치지 못했습니다.'); closeDiv(); loadDivs(); return; }
    divSeen.add(divKey(b));
    closeDiv();
    if (r.changed) {
      // 글자가 바뀌었으니 그 줄의 다른 자리들도 위치가 밀렸다. 다시 받아 온다.
      await loadDivs();
      toast('고쳤습니다. 표본 1개가 쌓였습니다.');
    } else {
      span.classList.add('kept');
      toast('원안 유지로 기록했습니다.');
    }
  }

  // ── 자막 렌더 ──
  // 문단 번호가 바로 앞 줄과 다르면 그 줄에 위 여백을 준다(.parastart, CSS 참고).
  // 같은 문단이 이어지는 줄(.paracont)은 타임스탬프를 숨긴다 — Whisper 세그먼트 경계는
  // 문법적 문장 경계와 안 맞을 때가 있어서, 안 숨기면 한 문장 한가운데에 다음 세그먼트의
  // 타임스탬프가 끼어 보인다(예: "proxy가 [00:01:00] 포함되어 있는"). 문단이 아직 안
  // 배정된 줄(방금 올라온 꼬리 부분)은 그 자체로 독립된 줄이니 항상 보여준다.
  // el 자신뿐 아니라 바로 다음 줄도 다시 봐야 한다 — el 이 그 사이에 새로 끼어들었을 수 있다.
  function markParaBoundary(el) {
    const prev = el.previousElementSibling;
    const isStart = !!el.dataset.para && el.dataset.para !== (prev ? prev.dataset.para : undefined);
    el.classList.toggle('parastart', isStart);
    el.classList.toggle('paracont', !!el.dataset.para && !isStart);
    const next = el.nextElementSibling;
    if (next) {
      const nextIsStart = !!next.dataset.para && next.dataset.para !== el.dataset.para;
      next.classList.toggle('parastart', nextIsStart);
      next.classList.toggle('paracont', !!next.dataset.para && !nextIsStart);
    }
  }

  function addSegment(seg, fresh) {
    empty.style.display = 'none';
    extendCoverage(seg.end); // 이 구간은 이제 Whisper 가 처리했다 — 아래 칸에서 겹치는 줄을 뺀다
    const el = document.createElement('div');
    el.className = 'line' + (fresh ? ' fresh' : '') + (seg.edited ? ' wasEdited' : '');
    el.dataset.id = seg.id; el.dataset.text = seg.text; el.dataset.start = seg.start;
    if (seg.paragraph != null) el.dataset.para = seg.paragraph;
    el.innerHTML =
      `<input type="checkbox" class="pick">` +
      `<span class="ts">${clock(seg.start)}</span>` +
      `<span class="txt">${esc(seg.text)}</span>` +
      `<button class="bnd" aria-pressed="false" title="여기서 강의가 끝났다고 표시합니다">⏹</button>` +
      `<button class="del" title="이 줄 삭제">✕</button>`;
    setLectureBoundaryMarker(el, seg.boundaryAfter);

    // 시간순 삽입 (이어 적기·정지 후 재개에서도 순서 유지)
    let ref = null;
    for (const other of stream.querySelectorAll('.line')) {
      if (parseFloat(other.dataset.start) > seg.start) { ref = other; break; }
    }
    stream.insertBefore(el, ref);
    lines.set(seg.id, el);
    markParaBoundary(el);
    wire(el);
    if ($('#showDiv').checked && divs.has(seg.id)) paintDivs(el);
    updateCount();
    // 새로 들어온 줄만 손본다. 검색 중이 아니면 이미 제대로 그려져 있어 할 일이 없다.
    const q = $('#search').value.trim();
    if (q) applyToLine(el, q);
    if (fresh) scrollToEnd();
  }

  function wire(el) {
    const id = +el.dataset.id;
    const txt = el.querySelector('.txt');

    txt.addEventListener('click', e => {
      // 갈린 자리를 눌렀으면 편집이 아니라 견주기 패널을 편다.
      const span = e.target.closest && e.target.closest('.dv');
      if (span && !document.body.classList.contains('editing')) {
        e.stopPropagation();
        if (divOpen && divOpen.span === span) closeDiv(); else openDiv(span, el);
        return;
      }
      if (!document.body.classList.contains('editing')) return;
      if (txt.getAttribute('contenteditable') === 'true') return;
      txt.setAttribute('contenteditable', 'true');
      txt.textContent = el.dataset.text;
      txt.focus();
      const r = document.createRange(); r.selectNodeContents(txt);
      const s = getSelection(); s.removeAllRanges(); s.addRange(r);
    });
    txt.addEventListener('keydown', e => {
      if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); txt.blur(); }
      if (e.key === 'Escape') { txt.textContent = el.dataset.text; txt.blur(); }
    });
    txt.addEventListener('blur', async () => {
      if (txt.getAttribute('contenteditable') !== 'true') return;
      txt.removeAttribute('contenteditable');
      const next = txt.textContent.trim();
      if (next === el.dataset.text) { txt.innerHTML = esc(next); return; }
      await post('/api/segment/update', { id, text: next, list: 'whisper' });
      if (!next) { removeLine(id); return; }
      el.dataset.text = next;
      el.classList.add('wasEdited');
      txt.innerHTML = esc(next);
      applyFilter();
    });

    // 강의 종료 토글. 이 표식이 곧 요약 구간이라, 사용자가 요약을 어디서 끊을지
    // 직접 정하는 자리다. 응답이 올 때까지 버튼을 잠가 연타가 요청을 겹쳐 보내지
    // 못하게 하고, 거부 사유(무음과 같은 180초 간격 규칙)는 편집 바에 그대로 보여 준다.
    const boundaryButton = el.querySelector('.bnd');
    boundaryButton.addEventListener('click', async () => {
      boundaryButton.disabled = true;
      try {
        const hadBoundary = !!el.dataset.boundaryAfter;
        const response = await post('/api/segment/boundary',
          { id, boundary: hadBoundary ? '' : 'lectureEnded', list: 'whisper' });
        if (!response.ok) {
          $('#editInfo').textContent = response.error || '강의 종료를 바꾸지 못했습니다.';
          return;
        }
        setLectureBoundaryMarker(el, response.boundaryAfter);
        await loadSummaryUnits();
        // 경계가 하나 바뀌면 그 뒤 구간 번호가 통째로 밀린다. 이미 저장해 둔 요약의
        // "3강"과 지금의 "3강"이 다를 수 있다는 사실은 반드시 눈에 보여야 한다.
        const unitCountNote = `구간이 ${response.unitCount}개가 되었습니다 — `
          + '이미 저장한 요약의 강 번호와 다를 수 있습니다.';
        $('#editInfo').textContent = unitCountNote;
        notice('#sumNotice', 'warn', esc(unitCountNote));
      } finally {
        boundaryButton.disabled = false;
      }
    });

    el.querySelector('.del').addEventListener('click', async () => {
      await post('/api/segment/delete', { ids: [id], list: 'whisper' });
      removeLine(id);
    });

    el.querySelector('.ts').addEventListener('click', async () => {
      // 임의 시각을 요청에 싣지 않고, 서버가 계산한 구간 중 이 문장을 포함하는 id를
      // 고른다. 그래야 JSON 소수점 축약 때문에 마지막 문장이 빠지는 경로가 다시 생기지 않는다.
      if (!(state.summaryUnits || []).length) await loadSummaryUnits();
      const segmentStart = Number(el.dataset.start);
      const containingUnit = (state.summaryUnits || []).find(unit =>
        segmentStart >= Number(unit.start) && segmentStart <= Number(unit.end));
      if (containingUnit) {
        $('#sumRangeStart').value = String(containingUnit.id);
        $('#sumRangeEnd').value = '';
        handleSummarySelectionChange('start');
      }
      setWorkspaceView('summary');
      $('#sumRangeStart').focus();
    });

    el.querySelector('.pick').addEventListener('click', e => {
      if (e.shiftKey && lastPicked !== null) {
        const all = [...stream.querySelectorAll('.line')];
        const a = all.findIndex(x => +x.dataset.id === lastPicked);
        const b = all.findIndex(x => x === el);
        if (a >= 0 && b >= 0) {
          const [lo, hi] = a < b ? [a, b] : [b, a];
          for (let i = lo; i <= hi; i++) all[i].querySelector('.pick').checked = true;
        }
      }
      lastPicked = id;
      syncPicked();
    });
  }

  function removeLine(id) {
    const el = lines.get(id);
    if (el) { el.remove(); lines.delete(id); }
    updateCount(); syncPicked();
    if (lines.size === 0) empty.style.display = '';
  }

  function updateCount() {
    $('#count').textContent = lines.size + '줄';
  }

  function syncPicked() {
    let n = 0;
    stream.querySelectorAll('.line').forEach(el => {
      const on = el.querySelector('.pick').checked;
      el.classList.toggle('picked', on);
      if (on) n++;
    });
    $('#btnDelSel').disabled = n === 0;
    $('#btnDelSel').textContent = n ? `선택 삭제 (${n})` : '선택 삭제';
  }

  // 한 줄에만 검색 상태를 반영한다.
  function applyToLine(el, q) {
    const raw = el.dataset.text || '';
    const txt = el.querySelector('.txt');
    if (txt.getAttribute('contenteditable') === 'true') return;
    if (!q) {
      el.style.display = ''; el.classList.remove('hit');
      txt.innerHTML = esc(raw);
      return;
    }
    const hit = raw.toLowerCase().includes(q.toLowerCase());
    el.style.display = hit ? '' : 'none';
    el.classList.toggle('hit', hit);
    if (hit) {
      const re = new RegExp(q.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi');
      txt.innerHTML = esc(raw).replace(re, m => `<mark>${m}</mark>`);
    }
  }

  // 전체 훑기는 검색어가 바뀔 때만. 자막이 한 줄 늘 때마다 부르면 안 된다.
  // 800줄에서 이 함수 한 번이 78ms 라, 매 문장마다 부르면 실시간 자막이 그만큼 멈춰 선다.
  function applyFilter() {
    const q = $('#search').value.trim();
    stream.querySelectorAll('.line').forEach(el => applyToLine(el, q));
  }

  // 자동 스크롤은 scrollHeight 를 읽는 순간 전체 레이아웃을 강제로 다시 계산시킨다.
  // 프레임당 한 번으로 묶어서 받아쓰는 동안 같은 계산이 반복되지 않게 한다.
  let scrollQueued = false;
  function scrollToEnd() {
    if (scrollQueued || !$('#autoscroll').checked) return;
    // 탭이 뒤에 있으면 rAF 가 안 돌아 예약이 영영 안 풀린다. 그때는 바로 처리한다.
    if (document.hidden) { stream.scrollTop = stream.scrollHeight; return; }
    scrollQueued = true;
    requestAnimationFrame(() => { scrollQueued = false; stream.scrollTop = stream.scrollHeight; });
  }

  // ── 상태 ──
  function showSummaryProgress(message, busy = false) {
    const el = $('#summaryProgress');
    el.textContent = message || '';
    el.classList.toggle('busy', !!message && busy);
  }

  // WebUI+Markup.swift의 #summary 정적 초기값과 반드시 같은 문구를 유지한다.
  // 새로고침 직후에는 저 정적 HTML이 보이고, 그 다음부터는 이 함수가 같은 자리를
  // 다시 그리므로 한쪽만 고치면 새로고침 타이밍에 따라 안내가 달라진다.
  const summaryEmptyState =
    '<p class="muted-note">이 수업의 전체 기록을 정리합니다. 위 <b>요약 모델</b>에서 방식을 고른 뒤 진행하세요.</p>' +
    '<p class="muted-note"><b>로컬 모델</b> — 이 기기에 설치된 Qwen이 인터넷 연결 없이 정리합니다. ' +
    '<b>요약 생성</b>을 누르면 바로 시작되고, 진행 중에는 <b>요약 취소</b>로 멈출 수 있습니다.</p>' +
    '<p class="muted-note"><b>Claude · ChatGPT · Gemini</b> — API 키 없이 각 서비스의 웹 화면을 그대로 씁니다. ' +
    '이 앱이 로그인하거나 화면을 대신 조작하지 않고, 붙여넣을 프롬프트만 준비합니다.</p>' +
    '<ol class="muted-note">' +
      '<li>위에서 Claude · ChatGPT · Gemini 중 하나를 고르고, 필요하면 <b>요약 범위</b>로 구간을 지정합니다.</li>' +
      '<li><b>프롬프트 복사하고 열기</b>를 누르면 프롬프트가 클립보드에 복사되고 그 서비스의 새 탭이 열립니다.</li>' +
      '<li>새 탭에서 <kbd>⌘V</kbd>로 붙여넣고 Enter를 누릅니다.</li>' +
      '<li>모델이 만든 문서(아티팩트·캔버스)를 .md 파일로 내려받습니다.</li>' +
      '<li>내려받은 파일을 이 화면에 끌어다 놓거나, <b>요약 .md 불러오기</b>로 고르거나, 내용을 그대로 붙여넣습니다 — 확인 뒤 자동으로 요약에 반영됩니다.</li>' +
    '</ol>' +
    '<p class="muted-note">온라인 모델을 쓰면 이 수업의 기록이 그 서비스로 전달됩니다. 각 서비스의 대화 학습 사용 설정을 먼저 확인하세요.</p>';

  function showCurrentSummary(markdown = state.summary, clearNotice = false) {
    $('#summarySource').textContent = '현재 세션 요약';
    $('#btnCurrentSummary').style.display = 'none';
    $('#saveSummaryBox').style.display = markdown ? '' : 'none';
    $('#summary').innerHTML = markdown ? md(markdown) : summaryEmptyState;
    $('#summary').classList.toggle('onlineHelp', !markdown);
    if (clearNotice) notice('#sumNotice', '', '');
  }

  // 라디오는 select와 달리 값이 한 요소에 모이지 않으므로 선택된 항목을 직접 읽는다.
  // 선택이 풀린 비정상 상태는 안전한 기존 동작인 로컬 모델로 되돌린다.
  function selectedSummaryTarget() {
    const checkedTarget = document.querySelector('input[name="onlineTarget"]:checked');
    return checkedTarget ? checkedTarget.value : 'local';
  }

  function selectedSummaryRange() {
    const startValue = $('#sumRangeStart').value;
    const endValue = $('#sumRangeEnd').value;
    return {
      fromUnit: startValue === '' ? null : Number(startValue),
      toUnit: endValue === '' ? null : Number(endValue),
    };
  }

  function summaryRangeCacheKey(target = selectedSummaryTarget()) {
    const range = selectedSummaryRange();
    return `${target}:${range.fromUnit ?? ''}:${range.toUnit ?? ''}`;
  }

  function unitsInSelectedRange() {
    const range = selectedSummaryRange();
    return (state.summaryUnits || []).filter(unit =>
      (range.fromUnit === null || Number(unit.id) >= range.fromUnit) &&
      (range.toUnit === null || Number(unit.id) <= range.toUnit));
  }

  function invalidateOnlineContext() {
    // 대상이나 범위가 바뀐 뒤 옛 기대 구간 수를 import 검증에 쓰면 정상 응답에도
    // 누락 경고가 뜬다. 진행 작업과 프롬프트를 같은 순간에 버려 둘이 엇갈리지 않게 한다.
    state.onlineJob = null;
    state.promptCache = null;
    promptRequestGeneration += 1;
  }

  function syncSummaryRangeConstraints(changedSide) {
    const startSelect = $('#sumRangeStart');
    const endSelect = $('#sumRangeEnd');
    let range = selectedSummaryRange();
    if (range.fromUnit !== null && range.toUnit !== null && range.toUnit < range.fromUnit) {
      // 이미 고른 반대편 option을 disabled 상태로 남겨 두면 브라우저마다 표시가
      // 달라진다. 사용자가 방금 바꾼 쪽을 보존하고 다른 쪽만 기본값으로 되돌린다.
      if (changedSide === 'start') endSelect.value = '';
      else startSelect.value = '';
      range = selectedSummaryRange();
    }
    [...endSelect.options].forEach(option => {
      option.disabled = option.value !== '' && range.fromUnit !== null
        && Number(option.value) < range.fromUnit;
    });
    [...startSelect.options].forEach(option => {
      option.disabled = option.value !== '' && range.toUnit !== null
        && Number(option.value) > range.toUnit;
    });
  }

  function renderSummaryRangeOptions(units) {
    const startSelect = $('#sumRangeStart');
    const endSelect = $('#sumRangeEnd');
    const previousStart = startSelect.value;
    const previousEnd = endSelect.value;
    const validUnitIDs = new Set(units.map(unit => String(unit.id)));

    startSelect.innerHTML = '<option value="">처음부터</option>' + units.map(unit =>
      `<option value="${unit.id}">${unit.id}강 시작 · ${clock(unit.start)}</option>`).join('');
    endSelect.innerHTML = '<option value="">끝까지</option>' + units.map(unit =>
      `<option value="${unit.id}">${unit.id}강 끝 · ${clock(unit.end)}</option>`).join('');
    // SSE 경계 추가나 정지 후 재조회가 와도 아직 존재하는 사용자의 선택은 지킨다.
    // 매번 처음/끝으로 초기화하면 긴 수업에서 고른 범위를 조용히 잃는다.
    startSelect.value = previousStart === '' || validUnitIDs.has(previousStart) ? previousStart : '';
    endSelect.value = previousEnd === '' || validUnitIDs.has(previousEnd) ? previousEnd : '';
    syncSummaryRangeConstraints();
    showLastSummarized(state.lastSummarizedAt);
    updateSummaryControls();
  }

  async function loadSummaryUnits() {
    try {
      const response = await fetch('/api/summary/units', { cache: 'no-store' }).then(result => result.json());
      if (!response.ok) throw new Error(response.error || '구간 목록을 읽지 못했습니다.');
      state.summaryUnits = response.units || [];
      renderSummaryRangeOptions(state.summaryUnits);
      return state.summaryUnits;
    } catch (unitLoadError) {
      console.warn('요약 구간 조회 실패', unitLoadError);
      clientLog('warn', '요약 구간 조회 실패 — ' + errorDescription(unitLoadError));
      return [];
    }
  }

  function promptRequestBody(target) {
    const range = selectedSummaryRange();
    const requestBody = { target };
    if (range.fromUnit !== null) requestBody.fromUnit = range.fromUnit;
    if (range.toUnit !== null) requestBody.toUnit = range.toUnit;
    return requestBody;
  }

  async function fetchPromptBundle(target, showErrors) {
    const cacheKey = summaryRangeCacheKey(target);
    const requestGeneration = ++promptRequestGeneration;
    try {
      const response = await post('/api/summary/prompt', promptRequestBody(target));
      if (!response.ok) {
        if (showErrors) notice('#sumNotice', 'warn', esc(response.error || '프롬프트를 만들지 못했습니다.'));
        return null;
      }
      // 사용자가 fetch 도중 선택을 바꾸면 늦게 온 옛 응답이 새 선택의 캐시를 덮지
      // 못하게 세대와 키를 모두 확인한다.
      if (requestGeneration !== promptRequestGeneration || cacheKey !== summaryRangeCacheKey(target)) {
        return null;
      }
      state.promptCache = { ...response, cacheKey };
      return state.promptCache;
    } catch (promptFetchError) {
      console.warn('온라인 프롬프트 준비 실패', promptFetchError);
      clientLog('warn', '온라인 프롬프트 준비 실패 — ' + errorDescription(promptFetchError));
      if (showErrors) notice('#sumNotice', 'warn', '프롬프트를 준비하는 동안 서버 연결이 끊겼습니다.');
      return null;
    }
  }

  function prefetchPromptForSelection() {
    const target = selectedSummaryTarget();
    if (target === 'local' || running || stopping || state.summarizing) return;
    const expectedKey = summaryRangeCacheKey(target);
    if (state.promptCache?.cacheKey === expectedKey) return;
    void fetchPromptBundle(target, false);
  }

  function handleSummarySelectionChange(changedSide) {
    syncSummaryRangeConstraints(changedSide);
    invalidateOnlineContext();
    updateSummaryControls();
    prefetchPromptForSelection();
  }

  function appendOnlineOpenButton(container, targetURL) {
    const openButton = document.createElement('button');
    openButton.className = 'sm';
    openButton.textContent = '열기';
    openButton.onclick = () => {
      const openedWindow = window.open(targetURL, '_blank');
      if (!openedWindow) clientLog('warn', '온라인 요약 팝업 차단 — 두 번째 열기 클릭');
    };
    container.appendChild(openButton);
  }

  function appendOnlineImportInputs(container) {
    const importButton = document.createElement('button');
    importButton.className = 'sm';
    importButton.textContent = '요약 .md 불러오기';
    importButton.onclick = () => $('#summaryFileInput').click();
    container.appendChild(importButton);

    const pasteTextarea = document.createElement('textarea');
    pasteTextarea.placeholder = '온라인 LLM이 만든 마크다운을 여기에 붙여넣으세요.';
    pasteTextarea.setAttribute('aria-label', '온라인 요약 붙여넣기');
    pasteTextarea.addEventListener('paste', async pasteEvent => {
      const pastedText = pasteEvent.clipboardData?.getData('text') || '';
      if (!pastedText) return;
      pasteEvent.preventDefault();
      pasteTextarea.value = pastedText;
      await importOnlineSummary(pastedText);
    });
    container.appendChild(pasteTextarea);
  }

  function showOnlineTransfer(bundle, copiedToClipboard, popupBlocked, clipboardError) {
    const onlineStep = $('#onlineStep');
    onlineStep.style.display = '';
    onlineStep.innerHTML =
      '<div class="onlineStepRow"><span class="onlineStepNumber">1</span><div>' +
      `<strong>${esc(bundle.targetName)}에 프롬프트 전달</strong>` +
      (copiedToClipboard
        ? '프롬프트를 복사했습니다. 열린 탭에서 <kbd>⌘V</kbd> 한 뒤 요약 문서를 .md로 내려받으세요.'
        : `자동 복사가 실패했습니다 (${esc(errorDescription(clipboardError))}). ` +
          '아래 전문이 전체 선택되어 있습니다. 직접 복사한 뒤 [열기]를 누르세요.') +
      '</div></div>' +
      '<div class="onlineStepRow"><span class="onlineStepNumber">2</span><div>' +
      '<strong>다운로드한 .md를 놓거나, 불러오거나, 붙여넣으세요</strong>' +
      '요약 화면에 파일을 끌어다 놓을 수 있고, 파일 선택이나 아래 붙여넣기도 사용할 수 있습니다.' +
      '</div></div>';

    const firstStepBody = onlineStep.querySelector('.onlineStepRow > div');
    if (!copiedToClipboard) {
      const promptTextarea = document.createElement('textarea');
      promptTextarea.readOnly = true;
      promptTextarea.value = bundle.text;
      promptTextarea.setAttribute('aria-label', '온라인 LLM 프롬프트 전문');
      firstStepBody.appendChild(promptTextarea);
      appendOnlineOpenButton(firstStepBody, bundle.url);
      // 실패 뒤 다시 드래그할 필요가 없도록 전문을 미리 선택한다. 이동은 아직 하지
      // 않았으므로 현재 문서가 포커스를 가진 상태에서 사용자가 바로 ⌘C 할 수 있다.
      promptTextarea.focus();
      promptTextarea.select();
    } else if (popupBlocked) {
      appendOnlineOpenButton(firstStepBody, bundle.url);
    }
    const secondStepBody = onlineStep.querySelectorAll('.onlineStepRow > div')[1];
    appendOnlineImportInputs(secondStepBody);
  }

  async function importOnlineSummary(markdownText) {
    const onlineJob = state.onlineJob;
    const requestBody = {
      markdown: markdownText,
      expectedUnitCount: onlineJob?.unitCount || 0,
      targetName: onlineJob?.targetName || '외부 LLM',
    };
    if (onlineJob?.fromUnit !== null && onlineJob?.fromUnit !== undefined) {
      requestBody.fromUnit = onlineJob.fromUnit;
    }
    if (onlineJob?.toUnit !== null && onlineJob?.toUnit !== undefined) {
      requestBody.toUnit = onlineJob.toUnit;
    }

    let response;
    try {
      response = await post('/api/summary/import', requestBody);
    } catch (importRequestError) {
      console.warn('온라인 요약 적용 실패', importRequestError);
      clientLog('error', '온라인 요약 적용 연결 실패 — ' + errorDescription(importRequestError));
      notice('#sumNotice', 'warn', '요약을 적용하는 동안 서버 연결이 끊겼습니다.');
      return;
    }
    if (!response.ok) {
      const rejectionMessage = response.error || '요약을 가져오지 못했습니다.';
      clientLog('warn', '온라인 요약 import 거부 — ' + rejectionMessage);
      notice('#sumNotice', 'warn', esc(rejectionMessage));
      return;
    }
    state.onlineJob = null;
    $('#onlineStep').style.display = '';
    $('#onlineStep').innerHTML =
      '<div class="onlineStepRow"><span class="onlineStepNumber">✓</span><div>' +
      '<strong>온라인 요약을 적용했습니다.</strong>서버가 모든 열린 탭을 같은 요약으로 갱신했습니다.</div></div>';
    // 화면 갱신은 서버가 보내는 summaryDone SSE가 맡는다. 여기서 직접 그리면 같은
    // 결과가 두 번 렌더되고 다른 기기 탭과 적용 순서가 어긋날 수 있다.
    if (response.warning) notice('#sumNotice', 'warn', esc(response.warning));
  }

  function localSummaryUnavailable() {
    return selectedSummaryTarget() === 'local'
      && (!!state.summarizerNote || String(state.summaryEngine || '').includes('사용 불가'));
  }

  function renderSummaryEngineLine() {
    if (localSummaryUnavailable()) {
      $('#engineLine').textContent = '로컬 요약 불가: '
        + (state.summarizerNote || 'Ollama와 Qwen 모델이 필요합니다.');
      return;
    }
    const displayedSummaryEngine = state.summaryEngineNote || state.summaryEngine;
    $('#engineLine').textContent = displayedSummaryEngine ? '요약 엔진: ' + displayedSummaryEngine : '';
  }

  function updateSummaryControls() {
    const busy = !!state.summarizing;
    // 입력 스냅샷이 계속 늘어나는 녹음·정리 중에는 어느 경로도 쓸 수 없다.
    const blocked = running || stopping;
    const target = selectedSummaryTarget();
    const usesLocalModel = target === 'local';
    // 로컬만 Ollama를 점유하므로 진행 중에는 중복 실행을 막는다. 온라인은 프롬프트를
    // 만들어 건네줄 뿐이라 로컬 요약이 도는 동안에도 병행할 수 있다. 그 사이 도착한
    // 온라인 결과가 뒤늦게 끝난 로컬 요약에 덮이지 않도록 서버가 로컬 쪽을 취소한다.
    const button = $('#btnSummarize');
    button.disabled = blocked || (usesLocalModel && (busy || localSummaryUnavailable()));
    button.textContent = usesLocalModel
      ? (busy ? '요약 생성 중…' : (state.summary ? '요약 다시 생성' : '요약 생성'))
      : '프롬프트 복사하고 열기';
    button.title = running ? '녹음과 Whisper 정리가 끝난 뒤 요약할 수 있습니다.'
                 : stopping ? 'Whisper 정리가 끝난 뒤 요약할 수 있습니다.'
                 : localSummaryUnavailable() ? (state.summarizerNote || 'Ollama와 Qwen 모델이 필요합니다.')
                 : '';
    $('#btnPromptFile').style.display = usesLocalModel ? 'none' : '';
    $('#btnImportSummary').style.display = usesLocalModel ? 'none' : '';
    $('#btnPromptFile').disabled = blocked;
    $('#btnImportSummary').disabled = blocked;
    // 대상 선택까지 잠그면 로컬 요약이 도는 동안 온라인으로 갈아탈 수 없다. 그건
    // 수 분을 기다리라는 뜻이라, 녹음·정리 중에만 막는다.
    $('#onlineTargets').disabled = blocked;
    // 취소는 로컬 요약이 실제로 도는 동안에만 의미가 있다.
    $('#btnCancelSummary').style.display = busy ? '' : 'none';
    const hasMultipleUnits = (state.summaryUnits || []).length > 1;
    $('#sumRangeStart').disabled = blocked || !hasMultipleUnits;
    $('#sumRangeEnd').disabled = blocked || !hasMultipleUnits;
    const continuationUnitID = $('#btnFromLast').dataset.unitId;
    $('#btnFromLast').disabled = blocked || !hasMultipleUnits || !continuationUnitID;
    if (!hasMultipleUnits) {
      $('#sumRangeHint').textContent = '이 수업에는 강의 종료 표시가 없어 전체만 요약할 수 있습니다.';
    }
    renderSummaryEngineLine();
    if (busy && !$('#summaryProgress').textContent) {
      showSummaryProgress('요약을 생성하는 중입니다.', true);
    } else if (!busy && !blocked && $('#summaryProgress').textContent === '요약을 생성하는 중입니다.') {
      showSummaryProgress('');
    }
  }

  function setRunning(on) {
    const wasRunning = running;
    running = on;
    $('#status').classList.toggle('live', on);
    $('#statusText').textContent = on ? '녹음 중' : '대기 중';
    $('#btnStart').style.display = on ? 'none' : '';
    $('#btnStop').style.display = on ? '' : 'none';
    document.querySelectorAll('#retainOriginalAudio, #folder, #baseDir, #btnPick, #btnNewSession, #btnEdit')
      .forEach(e => e.disabled = on);
    $('#btnEdit').title = on ? '녹음 중에는 편집할 수 없습니다 — 정지한 뒤 이용하세요.' : '';
    if (on) {
      // 새 녹음이 시작되면 실제로 들어오는 자막을 바로 볼 수 있게 한다. 사용자는 이후
      // 기존 요약을 읽으러 다시 전환할 수 있고, 공통 장애 배너는 어느 화면에서나 보인다.
      if (!wasRunning) {
        setWorkspaceView('whisper');
        // 정지 중에 미리 받은 프롬프트는 새 전사가 붙는 순간 더 이상 같은 입력이
        // 아니다. 다음 정지 뒤 서버 구간을 다시 받은 다음에만 새 캐시를 만든다.
        invalidateOnlineContext();
      }
      // 녹음 중엔 편집을 막는다(서버도 같은 판단을 한다 — 여긴 그걸 미리 보여줄 뿐이다).
      // 이미 편집 모드였다면(다른 탭에서 방금 시작을 눌렀을 수도 있다) 강제로 빠져나온다.
      document.body.classList.remove('editing');
      stream.querySelectorAll('.pick').forEach(c => c.checked = false);
      startedAt = startedAt || Date.now();
      tick = tick || setInterval(() => $('#clock').textContent = clock((Date.now() - startedAt)/1000), 500);
      setLive('');            // 받아쓰기 칸을 미리 띄워 자리를 잡아 둔다
    } else {
      clearInterval(tick); tick = null;
      showSilent('');
      setLive('');            // 멈췄으면 받아쓰던 줄도 같이 치운다
      $('#resumeBar').classList.remove('on');
    }
    updateSummaryControls();
    if (wasRunning && !on) void loadSummaryUnits();
  }

  // 아직 확정되지 않은 텍스트. 확정 자막과 다른 칸에 그린다.
  // 녹음 중에는 글이 비어도 칸을 그대로 둔다 — 나타났다 사라지면 위쪽이 계속 밀린다.
  // scrollHeight 를 읽으면 그 순간 문서 전체 레이아웃이 다시 계산된다.
  // 글자가 들어올 때마다 읽으면 자막 800줄을 매번 다시 재는 셈이라, 프레임당 한 번으로 묶는다.
  let liveScrollQueued = false;
  function setLive(text) {
    const t = (text || '').trim();
    live.hidden = !running && !t;
    liveText.textContent = t;
    if (liveScrollQueued || document.hidden) return;
    liveScrollQueued = true;
    requestAnimationFrame(() => { liveScrollQueued = false; live.scrollTop = live.scrollHeight; });
  }

  function notice(where, kind, html) {
    $(where).innerHTML = html ? `<div class="notice ${kind}">${html}</div>` : '';
  }

  function renderSession(s) {
    // 온라인 작업 맥락은 예상 수·대상·범위를 흩어진 플래그로 두지 않고 onlineJob
    // 객체 하나로 보존한다. promptCache와 서버 구간 목록은 작업이 아니라 재요청을
    // 줄이는 파생 캐시이므로 그대로 옮기되, import 판단은 onlineJob만 본다.
    const onlineJob = state.onlineJob || null;
    const promptCache = state.promptCache || null;
    const summaryUnits = state.summaryUnits || [];
    state = s;
    state.onlineJob = onlineJob;
    state.promptCache = promptCache;
    state.summaryUnits = summaryUnits;
    $('#baseDir').value = s.storageLocation || '';
    if (s.sessionName) {
      $('#sessionChip').style.display = ''; $('#sessionChip').textContent = '📁 ' + s.sessionName;
      $('#curName').textContent = s.sessionName;
      $('#curSub').textContent = s.sessionDir;
    } else {
      $('#sessionChip').style.display = 'none';
      $('#curName').textContent = '저장 폴더 없음';
      $('#curSub').textContent = '시작하면 폴더가 만들어집니다';
    }
    renderSummaryEngineLine();
    // 새로고침해도 몇 번째 호출인지 보이게 서버가 들고 있던 진행률을 되살린다.
    // 이게 없으면 수 분짜리 작업이 멈춘 것처럼 보여 사용자가 중복 실행을 시도한다.
    if (s.summarizing) {
      const restored = s.summaryProgress;
      showSummaryProgress(restored && restored.total
        ? `요약 중… ${restored.done}/${restored.total}`
        : '요약을 생성하는 중입니다.', true);
    } else showSummaryProgress('');
    updateSummaryControls();
    notice('#sesNotice', 'info', s.continuing
      ? `이어 적기 모드입니다. 새 자막은 <b>${clock(s.timeBase)}</b> 이후 시각으로 붙습니다.` : '');
    if (s.domainSource) renderDoc({ name: s.domainSource, terms: s.domainTerms || [] });
    $('#btnCorrectRevert').style.display = s.hasCorrections ? '' : 'none';
    const audioMegabytes = Number(s.audioMB || 0);
    const retentionStatusLabels = {
      kept: `원본 소리 ${audioMegabytes.toFixed(1)}MB를 보관 중입니다.`,
      deletedAfterWhisper: 'Whisper 처리가 끝나 원본 소리를 삭제했습니다.',
      retainedForRecovery: 'Whisper 처리가 완전히 끝나지 않아 복구용 원본 소리를 보관했습니다.',
      deletionFailed: `원본 소리 삭제에 실패해 ${audioMegabytes.toFixed(1)}MB가 남아 있습니다.`,
    };
    $('#audioStorageStatus').textContent = retentionStatusLabels[s.audioRetentionStatus]
      || (audioMegabytes > 0 ? `현재 세션 원본 소리: ${audioMegabytes.toFixed(1)}MB` : '');
    showWhisperWhy(s.running ? (s.whisperLiveNote || '') : '');
  }

  function renderDoc(d) {
    const chips = (d.terms || []).slice(0, 40).map(t => `<span class="chip">${esc(t)}</span>`).join('');
    // 같은 교안을 다시 올리면 분석을 건너뛴다. 그 사실을 보여줘야 기다리지 않는다.
    const speed = d.cached ? ` · <b>캐시에서 즉시</b>(${d.elapsedMs}ms)`
                : (d.elapsedMs != null ? ` · 새로 분석 ${(d.elapsedMs/1000).toFixed(1)}초` : '');
    $('#docInfo').innerHTML =
      `<div class="card"><div class="meta"><div class="name">${esc(d.name)}</div>` +
      `<div class="sub">${d.pages ? d.pages + '쪽 · ' : ''}용어 ${(d.terms||[]).length}개 반영 중${speed}</div></div>` +
      `<button class="danger sm" id="btnClearDoc">해제</button></div>` +
      (chips ? `<div class="chips">${chips}</div>` : '') +
      (d.scanned ? `<div class="notice warn" style="margin-top:12px">텍스트 레이어가 없는 스캔 PDF입니다. 용어를 뽑지 못했습니다 — OCR을 먼저 돌리거나 용어를 직접 입력하세요.</div>` : '');
    const c = $('#btnClearDoc');
    if (c) c.onclick = async () => { await post('/api/domain/clear'); $('#docInfo').innerHTML = ''; };
  }

  async function loadSessions() {
    const r = await fetch('/api/sessions').then(r => r.json());
    const list = r.sessions || [];
    if (!list.length) { $('#sessionList').innerHTML = '<div class="hint">아직 저장된 수업이 없습니다.</div>'; return; }
    $('#sessionList').innerHTML = list.map(s => {
      const when = new Date(s.updatedAt).toLocaleString('ko-KR', { month:'numeric', day:'numeric', hour:'2-digit', minute:'2-digit' });
      return `<div class="card"><div class="meta"><div class="name">${esc(s.title)}</div>` +
             `<div class="sub">${s.segments}줄 · ${clock(s.duration)} · ${when}${s.hasSummary ? ' · 요약 있음' : ''}</div></div>` +
             `<button class="sm" data-open="${esc(s.path)}">이어 적기</button>` +
             `<button class="sm danger" data-del="${esc(s.path)}">삭제</button></div>`;
    }).join('');
    $('#sessionList').querySelectorAll('[data-open]').forEach(b => b.onclick = async () => {
      const r = await post('/api/session/open', { path: b.dataset.open });
      if (!r.ok) { notice('#sesNotice', 'warn', esc(r.error)); return; }
      reloadAll(r.state);
    });
    $('#sessionList').querySelectorAll('[data-del]').forEach(b => b.onclick = async () => {
      if (!confirm('이 수업 기록을 지울까요? 휴지통으로 이동합니다.')) return;
      const r = await post('/api/session/delete', { path: b.dataset.del });
      if (!r.ok) { notice('#sesNotice', 'warn', esc(r.error)); return; }
      loadSessions();
    });
  }

  function reloadAll(s) {
    if (state.sessionDir && state.sessionDir !== s.sessionDir) {
      // 다른 수업의 구간 id와 프롬프트를 새 세션에 재사용하면 같은 숫자라도 전혀 다른
      // 발화를 가리킨다. 세션 전환은 선택 변경보다 강한 캐시 무효화 경계다.
      invalidateOnlineContext();
      state.summaryUnits = [];
      $('#sumRangeStart').value = '';
      $('#sumRangeEnd').value = '';
    }
    stream.querySelectorAll('.line').forEach(e => e.remove());
    lines.clear();
    fastStream.innerHTML = '';
    whisperCoverEnd = 0;   // 다른 세션으로 갈아탈 수 있으니 이전 커버리지를 들고 오면 안 된다
    $('#title').value = s.title || 'Zoom 수업';

    // 위 칸 = Whisper(정식 기록, 문단화됨). 아래 칸 = Whisper 가 아직 못 따라간 구간만.
    // addSegment 가 안에서 whisperCoverEnd 를 늘려 두므로, 아래 fast 필터는 그 값을 그대로 쓴다.
    (s.whisperSegments || []).forEach(seg => addSegment(seg, false));
    const fast = s.segments || [];
    fastTotal = fast.length;
    const last = fast.length ? fast[fast.length - 1].start : 0;
    fast.filter(x => x.start >= fastCutoff(last)).forEach(x => {
      const el = document.createElement('div');
      el.className = 'fline'; el.dataset.start = x.start; el.dataset.id = x.id;
      el.innerHTML = `<span class="t">${clock(x.start)}</span><span>${esc(x.text)}</span>`;
      setLectureBoundaryMarker(el, x.boundaryAfter);
      fastStream.appendChild(el);
    });
    $('#fastCount').textContent = fastTotal ? fastTotal + '줄 저장됨' : '';
    fastStream.scrollTop = fastStream.scrollHeight;

    if ($('#search').value.trim()) applyFilter();   // 다 그린 뒤 한 번만
    empty.style.display = lines.size ? 'none' : '';
    showLastSummarized(s.lastSummarizedAt);
    if (s.summary && !$('#sumName').value) $('#sumName').value = (s.title || '수업') + '_요약.md';
    showCurrentSummary(s.summary);
    renderSession(s);
    void loadSummaryUnits();
    loadSummaryFiles();
    // 창을 새로 열어도 경과 시간은 서버가 아는 진짜 시작 시각에서 이어 센다.
    startedAt = s.running ? (s.startedAt ? s.startedAt * 1000 : Date.now() - (s.elapsed || 0) * 1000) : null;
    setRunning(!!s.running);
    updateCount();
  }

  // ── 마크다운 ──
  function md(src) {
    const lines = String(src).split('\n'); let out = '', inUl = false;
    const inline = s => esc(s).replace(/\*\*(.+?)\*\*/g, '<b>$1</b>').replace(/`(.+?)`/g, '<code>$1</code>');
    for (let raw of lines) {
      const l = raw.trim();
      const heading = l.match(/^(#{1,3})\s+(.+)$/);
      if (heading) { if (inUl) { out += '</ul>'; inUl = false; }
        const tag = heading[1].length === 1 ? 'h2' : (heading[1].length === 2 ? 'h3' : 'h4');
        out += `<${tag}>${inline(heading[2])}</${tag}>`; continue; }
      if (/^[-*]\s/.test(l)) { if (!inUl) { out += '<ul>'; inUl = true; }
        out += `<li>${inline(l.replace(/^[-*]\s/, ''))}</li>`; continue; }
      if (inUl) { out += '</ul>'; inUl = false; }
      if (l === '---') { out += '<hr>'; continue; }
      if (/^>\s?/.test(l)) { out += `<blockquote>${inline(l.replace(/^>\s?/, ''))}</blockquote>`; continue; }
      if (l) out += `<p>${inline(l)}</p>`;
    }
    if (inUl) out += '</ul>';
    return out;
  }

  // ── SSE ──
  //
  // 이벤트는 **힌트**로만 쓴다. 진실은 서버의 /api/state 다.
  // EventSource 는 끊기면 알아서 다시 붙지만, 끊겨 있던 동안 쏜 이벤트는 되돌려주지 않는다.
  // 그걸 모르고 이벤트만 믿으면 화면이 조용히 굳은 채로 자기가 굳은 줄도 모른다.
  // 그래서 모든 이벤트의 일련번호를 세고, 하나라도 건너뛰면 통째로 다시 맞춘다.
  let lastSeq = 0, boot = null;
  let resyncing = false;

  // 서버 상태에 화면을 **맞춘다**. 통째로 다시 그리지 않는다.
  //
  // 90분 수업이면 위 칸에만 수백 줄이 쌓인다. 재구축하면 스크롤이 튀고,
  // 편집 중이던 줄이 날아가고, 검색이 풀리고, 줄 수에 비례해 렌더가 멈춘다.
  // 그래서 id 를 기준으로 없는 것만 넣고, 사라진 것만 빼고, 바뀐 것만 고친다.
  function mergeWhisper(list) {
    const byID = new Map(list.map(x => [x.id, x]));
    let added = 0, removed = 0, changed = 0;

    for (const [id, el] of [...lines]) {
      if (byID.has(id)) continue;
      el.remove(); lines.delete(id); removed++;
    }
    for (const seg of list) {
      const el = lines.get(seg.id);
      if (!el) { addSegment(seg, false); added++; continue; }
      const txt = el.querySelector('.txt');
      if (txt.getAttribute('contenteditable') === 'true') continue;  // 편집 중인 줄은 건드리지 않는다
      if (el.dataset.text !== seg.text) {
        el.dataset.text = seg.text;
        txt.innerHTML = esc(seg.text);
        el.classList.toggle('wasEdited', !!seg.edited);
        changed++;
      }
      // dataset 값은 항상 문자열이라 숫자와 그냥 비교하면 매번 다르다고 나온다 —
      // 그래서 String 으로 맞춰서 비교한다. undefined 로 지정하면 문자열 "undefined" 가
      // 박히므로 delete 로 속성 자체를 뗀다.
      const para = seg.paragraph != null ? String(seg.paragraph) : undefined;
      if (el.dataset.para !== para) {
        if (para === undefined) delete el.dataset.para; else el.dataset.para = para;
        markParaBoundary(el);
      }
      setLectureBoundaryMarker(el, seg.boundaryAfter);
    }
    return { added, removed, changed };
  }

  function mergeFast(list) {
    const last = list.length ? list[list.length - 1].start : 0;
    const cutoff = fastCutoff(last);
    const want = list.filter(x => x.start >= cutoff);
    const wantIDs = new Set(want.map(x => String(x.id)));
    for (const el of [...fastStream.children]) {
      if (!wantIDs.has(el.dataset.id)) el.remove();   // Whisper 가 따라잡아 빠진 줄 정리
    }
    const have = new Set([...fastStream.children].map(e => e.dataset.id));
    for (const x of want) {
      if (have.has(String(x.id))) {
        const existingLine = fastStream.querySelector(`.fline[data-id="${x.id}"]`);
        if (existingLine) setLectureBoundaryMarker(existingLine, x.boundaryAfter);
        continue;
      }
      const el = document.createElement('div');
      el.className = 'fline'; el.dataset.start = x.start; el.dataset.id = x.id;
      el.innerHTML = `<span class="t">${clock(x.start)}</span><span>${esc(x.text)}</span>`;
      setLectureBoundaryMarker(el, x.boundaryAfter);
      fastStream.appendChild(el);
    }
    fastTotal = list.length;
    $('#fastCount').textContent = fastTotal ? fastTotal + '줄 저장됨' : '';
  }

  async function resync(why) {
    if (resyncing) return;
    resyncing = true;
    try {
      const s = await fetch('/api/state', { cache: 'no-store' }).then(r => r.json());
      lastSeq = s.seq || 0;
      const bootChanged = boot !== null && boot !== s.boot;
      boot = s.boot;
      // 세션이 바뀌었거나(이어 적기·새 세션) 앱이 재시작했으면 병합이 아니라 새로 그린다.
      if (bootChanged || s.sessionDir !== state.sessionDir) { reloadAll(s); return; }
      const keepTop = stream.scrollTop, keepBottom = fastStream.scrollTop;
      const d = mergeWhisper(s.whisperSegments || []);
      mergeFast(s.segments || []);
      renderSession(s);
      setRunning(!!s.running);
      updateCount();
      stream.scrollTop = keepTop; fastStream.scrollTop = keepBottom;
      if (d.added || d.removed || d.changed) {
        console.log(`[동기화] ${why} — 추가 ${d.added} 제거 ${d.removed} 수정 ${d.changed}`);
      }
      setConn(true);
    } catch {
      setConn(false);
    } finally {
      resyncing = false;
    }
  }

  // 번호가 건너뛰었는지 본다. Last-Event-ID 재전송이 정상이면 여기 걸릴 일이 없다.
  function seen(d) {
    const n = d._seq;
    if (typeof n !== 'number') return true;
    if (lastSeq && n > lastSeq + 1) { resync('빠진 이벤트 ' + (n - lastSeq - 1) + '개'); lastSeq = n; return false; }
    lastSeq = Math.max(lastSeq, n);
    return true;
  }

  function setConn(ok) {
    $('#connDot').classList.toggle('off', !ok);
    $('#connDot').title = ok ? '서버와 연결됨' : '연결이 끊겼습니다 — 다시 붙는 중';
  }

  const es = new EventSource('/events');
  // 재연결될 때마다 무조건 다시 맞춘다. 끊긴 사이의 공백을 메우는 유일한 방법이다.
  // Last-Event-ID 재전송이 붙었으므로 재연결 자체로는 전체를 다시 받지 않는다.
  es.onopen = () => setConn(true);
  es.onerror = () => setConn(false);
  // 보관함에서 밀려나 재전송이 불가능할 때만 서버가 이걸 보낸다.
  es.addEventListener('resync', () => resync('서버가 재동기화 요청'));

  // 마지막 안전망. 녹음 중에는 주기적으로 서버와 대조한다.
  // 마지막 안전망. 개수만 받아 대조한다 — 전체 상태를 끌어오면 90분 수업에서 수백 KB다.
  setInterval(() => {
    if (document.hidden) return;
    fetch('/api/sync', { cache: 'no-store' }).then(r => r.json()).then(s => {
      setConn(true);
      if (s.boot !== boot || s.whisper !== lines.size || s.seq !== lastSeq) {
        resync(s.boot !== boot ? '앱이 재시작됨' : '주기 대조에서 어긋남');
      }
    }).catch(() => setConn(false));
  }, 60000);
  // 실시간 전사기 → 아래 칸,  Whisper → 위 칸(정식 기록)
  es.addEventListener('segment', e => {
    const d = JSON.parse(e.data); if (!seen(d)) return;
    showSilent(''); addFast(d);
  });
  // 문단이 확정된 줄만 서버가 보낸다(ZoomCaptionApp.ingestWhisperLines 참고) —
  // 그래서 이 줄은 등장할 때 이미 최종 모양이고, 나중에 다시 갱신될 일이 없다.
  //
  // 같은 id 가 두 번 오는 경우가 실제로 있다 — resync()(60초 안전망·이벤트 누락
  // 감지)가 /api/state 스냅샷으로 mergeWhisper 를 돌리는 순간, 마침 같은 줄의
  // 라이브 이벤트가 SSE 큐에 남아 있다가 뒤이어 도착하면 이 핸들러가 한 번 더
  // addSegment 를 부른다. mergeWhisper 는 lines.get 으로 이미 걸러 주는데, 여기는
  // 그 확인이 없어서 stop() 이 finalizeParagraphs 로 한꺼번에 여러 줄을 쏟아낼 때
  // (=바로 이 경합이 열리는 순간) 화면에 같은 줄이 두 번 그려졌다.
  es.addEventListener('whisperSegment', e => {
    const d = JSON.parse(e.data); if (!seen(d)) return;
    if (lines.has(d.id)) return;   // 이미 그려진 줄 — 다시 만들지 않는다
    addSegment(d, true);
  });
  // 180초 무음 처리에서 기존 마지막 문장에 경계 필드만 추가될 때 받는다. 문장
  // 전체를 다시 삽입하면 중복 줄이 생길 수 있으므로 해당 DOM의 표식만 갱신한다.
  // 이벤트를 놓쳐도 다음 /api/state 병합이 같은 boundaryAfter 값을 복원한다.
  es.addEventListener('lectureBoundary', serverEvent => {
    const boundaryEvent = JSON.parse(serverEvent.data); if (!seen(boundaryEvent)) return;
    const targetLine = boundaryEvent.collection === 'whisper'
      ? lines.get(boundaryEvent.id)
      : fastStream.querySelector(`.fline[data-id="${boundaryEvent.id}"]`);
    if (targetLine) setLectureBoundaryMarker(targetLine, boundaryEvent.boundaryAfter);
    // 경계가 하나 늘면 선택 가능한 강의 단위도 즉시 달라진다. 서버의 Chunker 결과를
    // 다시 받아야 option과 실제 요약 범위가 정의상 같은 상태를 유지한다.
    void loadSummaryUnits();
  });
  es.addEventListener('whisperLive', e => {
    const d = JSON.parse(e.data); if (!seen(d)) return;
    const behind = d.total - d.done;
    $('#waitNote').textContent = behind > 0
      ? `Whisper 가 ${behind}조각 뒤에서 따라오는 중` : '';
    if (d.note !== undefined) showWhisperWhy(d.note);
    // 정지를 누른 뒤 대기 중이면, 같은 신호로 마무리 카드의 진행률도 채운다.
    if (stopping) setStopStep('whisper', 'active', d.total > 0 ? `${d.done} / ${d.total} 조각` : '');
  });

  // 소리가 안 들어오면 자막 위에 띄운다. 소리가 돌아오면 알아서 사라진다.
  function showSilent(html) {
    $('#silentText').innerHTML = html;
    $('#silentBar').classList.toggle('on', !!html);
  }

  // 위 칸이 비어 있을 때는 "왜" 를 반드시 보여준다.
  // 조용히 비어 있으면 사용자는 기다리기만 하다가 수업을 통째로 놓친다.
  function showWhisperWhy(note) {
    const box = $('#emptyWhy');
    if (!note) { box.style.display = 'none'; return; }
    box.innerHTML = '<b>Whisper 자막이 만들어지지 않습니다.</b><br>' + esc(note);
    box.style.display = '';
  }
  es.addEventListener('volatile', e => {
    const d = JSON.parse(e.data); if (!seen(d)) return;
    setLive(d.text);
  });
  es.addEventListener('edited', e => {
    const d = JSON.parse(e.data); if (!seen(d)) return;
    const el = lines.get(d.id);
    if (el && el.querySelector('.txt').getAttribute('contenteditable') !== 'true') {
      el.dataset.text = d.text;
      el.querySelector('.txt').innerHTML = esc(d.text);
    }
  });
  es.addEventListener('deleted', e => {
    const d = JSON.parse(e.data); if (!seen(d)) return;
    (d.ids || []).forEach(removeLine);
  });
  es.addEventListener('status', e => {
    const d = JSON.parse(e.data); if (!seen(d)) return;
    if (typeof d.running === 'boolean') setRunning(d.running);
    if (d.message !== undefined) notice('#cfgNotice', d.level || 'info', d.message ? esc(d.message) : '');
    // 서버는 0 PCM이 계속 도착하는 정상 침묵에는 이 배너를 보내지 않는다. 실제
    // Core Audio 콜백 중단이나 시작 때 선택한 Zoom 대상 소실처럼 캡처 경로 자체가
    // 비정상일 때만 `silent: true`가 오며, 복구·정지 때 false로 명시적으로 지운다.
    if (d.silent) {
      showSilent(`<b>${esc(d.silentMessage || '오디오 입력에 문제가 있습니다.')}</b>`);
    } else if (d.silent === false) {
      showSilent('');
    }
  });
  es.addEventListener('summaryProgress', e => {
    const d = JSON.parse(e.data); if (!seen(d)) return;
    state.summarizing = true;
    showSummaryProgress(`요약 중… ${d.done}/${d.total}`, true);
    updateSummaryControls();
  });
  es.addEventListener('summaryDone', e => {
    const d = JSON.parse(e.data); if (!seen(d)) return;
    state.summarizing = false;
    showSummaryProgress('');
    updateSummaryControls();
    if (!d.ok) {
      // 사용자가 직접 멈췄거나 온라인 결과가 대체한 경우다. 오류 배너를 띄우면
      // 자기가 한 조작을 실패로 읽게 되므로 담백한 안내로 구분한다.
      notice('#sumNotice', d.cancelled ? 'info' : 'warn',
             esc(d.error || '요약에 실패했습니다.'));
      if (!state.summary) {
        $('#summary').innerHTML = '<p class="muted-note">요약 결과가 없습니다. 문제를 해결한 뒤 다시 시도해 주세요.</p>';
      }
      return;
    }
    notice('#sumNotice', '', '');
    state.summary = d.markdown;
    if (d.engineNote) {
      state.summaryEngineNote = d.engineNote;
      $('#engineLine').textContent = '요약 엔진: ' + d.engineNote;
    }
    showCurrentSummary(d.markdown);
    updateSummaryControls();
    showLastSummarized(d.lastSummarizedAt);
    $('#saveSummaryBox').style.display = '';
    if (!$('#sumName').value) $('#sumName').value = ($('#title').value || '수업') + '_요약.md';
    $('.summaryScroll').scrollTop = 0;
  });
  es.addEventListener('polishProgress', e => {
    const d = JSON.parse(e.data); if (!seen(d)) return;
    $('#polResult').innerHTML = `<p class="muted-note">${esc(d.message)}</p>`;
  });
  es.addEventListener('polishDone', e => {
    const d = JSON.parse(e.data); if (!seen(d)) return;
    $('#btnPolish').disabled = false;
    if (!d.ok) { notice('#polNotice', 'warn', esc(d.error || '실패')); $('#polResult').innerHTML = ''; return; }
    notice('#polNotice', '', '');
    renderPolish(d.corrections, d.model);
  });

  // ── 액션 ──
  $('#btnStart').onclick = async () => {
    if (running) return;              // 이미 돌고 있으면 요청 자체를 보내지 않는다
    $('#btnStart').disabled = true;
    const r = await post('/api/start', {
      title: $('#title').value,
      folder: $('#folder').value,
      baseDir: $('#baseDir').value,
      retainOriginalAudio: $('#retainOriginalAudio').checked
    });
    $('#btnStart').disabled = false;
    if (!r.ok) {
      notice('#cfgNotice', 'warn', esc(r.error || '시작 실패'));
      if (r.state) reloadAll(r.state);
      return;
    }
    startedAt = Date.now(); setRunning(true); renderSession(r.state);
    showSilent('');   // 무음 배너가 남아있었다면 재시작으로 문제를 해결했다고 보고 지운다
  };
  // ── 정지 → 마무리 대기 ──
  //
  // /api/stop 은 Whisper 남은 조각을 다 처리할 때까지 서버에서 붙잡고 있다가 응답한다
  // (ZoomCaptionApp.stop() 참고). 그동안 화면이 멈춘 것처럼 보이면 안 되니 카드를 띄우고,
  // 이미 흐르고 있던 whisperLive SSE 로 그 안의 진행률(조각 수)을 채운다.
  //
  // stopSteps 는 **단계 목록**이다. 지금은 whisper 하나뿐이지만, 나중에 정지 직후
  // LLM 다듬기(/api/polish/suggest, 이미 있음)를 자동으로 붙이려면 이 배열에
  // 원소 하나만 더하면 된다:
  //   { key: 'llm', label: 'AI 교정', run: async () => {
  //       await post('/api/polish/suggest');
  //       await new Promise(res => es.addEventListener('polishDone', res, { once: true }));
  //     } }
  // run() 안에서 폴리시 단계 전용 진행률을 보여주고 싶으면 polishProgress 리스너에서
  // whisperLive 와 같은 방식으로 setStopStep('llm', 'active', d.message) 를 불러 주면 된다.
  const stopSteps = [
    { key: 'whisper', label: 'Whisper 인식 정리', run: async () => {
        const r = await post('/api/stop');
        setRunning(false); startedAt = null;
        if (r.state) renderSession(r.state);
        loadSessions();
      } },
  ];
  let stopping = false;

  function renderStopSteps() {
    $('#stopStepsBox').innerHTML = stopSteps.map(s => `
      <div class="stopStep ${s.status || 'pending'}" data-step="${s.key}">
        <span class="stopIcon"></span>
        <span class="stopLabel">${esc(s.label)}</span>
        <span class="stopDetail">${esc(s.detail || '')}</span>
      </div>`).join('');
  }
  function setStopStep(key, status, detail) {
    const s = stopSteps.find(x => x.key === key);
    if (!s) return;
    s.status = status;
    if (detail !== undefined) s.detail = detail;
    renderStopStepsThrottled();
  }
  // whisperLive 는 조각마다 온다(수십 개) — 매번 innerHTML 을 다시 그릴 것 없이 다음
  // 애니메이션 프레임에 한 번만 그린다.
  let stopStepsRAF = null;
  function renderStopStepsThrottled() {
    if (stopStepsRAF) return;
    stopStepsRAF = requestAnimationFrame(() => { stopStepsRAF = null; renderStopSteps(); });
  }

  $('#btnStop').onclick = async () => {
    if (stopping) return;
    stopping = true;
    updateSummaryControls();
    stopSteps.forEach(s => { s.status = 'pending'; s.detail = ''; });
    renderStopSteps();
    $('#stopVeil').hidden = false;
    const shownAt = Date.now();
    try {
      for (const step of stopSteps) {
        setStopStep(step.key, 'active');
        await step.run();
        setStopStep(step.key, 'done');
      }
    } finally {
      // Whisper 가 이미 다 따라잡았으면(흔한 경우) /api/stop 이 거의 즉시 끝나서
      // 카드가 뜨자마자 사라진다 — 떴는지도 모르게 없어지면 "아무 반응 없음" 처럼
      // 보이니, 최소한은 눈에 보이게 붙잡아 둔다.
      const minVisible = 500;
      const left = minVisible - (Date.now() - shownAt);
      if (left > 0) await new Promise(res => setTimeout(res, left));
      stopping = false;
      updateSummaryControls();
      prefetchPromptForSelection();
      $('#stopVeil').hidden = true;
    }
  };

  $('#btnEdit').onclick = () => document.body.classList.add('editing');
  $('#btnEditDone').onclick = () => {
    document.body.classList.remove('editing');
    stream.querySelectorAll('.pick').forEach(c => c.checked = false);
    syncPicked();
  };
  // 시각 없는 전사 파일 왕복. 내보내기는 그냥 내려받기고, 되넣기는 파일 본문을 그대로
  // 서버에 넘긴다 — 파일 형식을 아는 곳을 TranscriptDocument 한 군데로 유지한다.
  $('#btnTranscriptFile').onclick = () => { location.href = '/export/transcript.md'; };
  $('#btnTranscriptImport').onclick = () => $('#transcriptFileInput').click();
  $('#transcriptFileInput').onchange = async () => {
    const chosenFile = $('#transcriptFileInput').files?.[0];
    // 같은 파일을 다시 고쳐 넣어도 change가 또 발생하도록 값을 비운다.
    $('#transcriptFileInput').value = '';
    if (!chosenFile) return;
    try {
      const markdown = await chosenFile.text();
      const result = await post('/api/transcript/import', { markdown });
      if (!result.ok) {
        $('#editInfo').textContent = result.error || '되넣지 못했습니다.';
        return;
      }
      // 서버가 고친 문장을 화면에 그대로 가져온다. 브라우저가 파일을 해석해 따로
      // 그리면 저장된 내용과 보이는 내용이 갈릴 수 있다.
      await resync('전사 문서 되넣기');
      $('#editInfo').textContent =
        `${result.lineCount}줄을 읽어 ${result.changed}줄을 고쳤습니다.`
        + (result.skipped ? ` (${result.skipped}줄은 번호를 찾지 못해 건너뜀)` : '');
    } catch (importError) {
      $('#editInfo').textContent = '파일을 읽지 못했습니다 — ' + errorDescription(importError);
    }
  };

  $('#btnDelSel').onclick = async () => {
    const ids = [...stream.querySelectorAll('.line')]
      .filter(el => el.querySelector('.pick').checked).map(el => +el.dataset.id);
    if (!ids.length || !confirm(`${ids.length}줄을 지울까요?`)) return;
    await post('/api/segment/delete', { ids, list: 'whisper' });
    ids.forEach(removeLine);
  };

  $('#btnSummarize').onclick = async () => {
    if (running || stopping) return;
    const target = selectedSummaryTarget();
    // 로컬만 중복 실행을 막는다. 온라인은 진행 중인 로컬 요약과 병행할 수 있다.
    if (target === 'local' && state.summarizing) return;
    const range = selectedSummaryRange();
    if (target !== 'local') {
      notice('#sumNotice', '', '');
      if (!onlineEnvironmentLogged) {
        onlineEnvironmentLogged = true;
        clientLog('info', '온라인 요약 환경 — userAgent=' + navigator.userAgent
          + '; secureContext=' + String(window.isSecureContext)
          + '; clipboard=' + String(!!navigator.clipboard));
      }

      // 복사 성공 여부와 관계없이 이 클릭이 시작한 대상·범위를 먼저 고정한다.
      // 파일 드롭이나 붙여넣기가 나중에 도착해도 그때의 현재 UI 선택이 아니라
      // 실제로 내보낸 작업의 기대 구간 수로 검증해야 한다.
      state.onlineJob = {
        target,
        targetName: summaryTargets[target]?.name || target,
        fromUnit: range.fromUnit,
        toUnit: range.toUnit,
        unitCount: unitsInSelectedRange().length,
        startedAt: Date.now(),
      };

      const expectedCacheKey = summaryRangeCacheKey(target);
      let bundle = state.promptCache?.cacheKey === expectedCacheKey ? state.promptCache : null;
      if (!bundle) bundle = await fetchPromptBundle(target, true);
      if (!bundle) return;
      state.onlineJob.targetName = bundle.targetName;
      state.onlineJob.unitCount = bundle.unitCount;

      let clipboardError = null;
      try {
        if (!navigator.clipboard?.writeText) {
          throw new Error('Clipboard.writeText를 지원하지 않는 브라우저입니다.');
        }
        // 캐시가 있으면 이 호출 전에는 await가 없다. 클릭 제스처와 문서 포커스가
        // 살아 있는 동안 writeText를 시작해야 Safari/Chrome의 권한 판정을 통과한다.
        const clipboardWrite = navigator.clipboard.writeText(bundle.text);
        await clipboardWrite;
      } catch (copyError) {
        clipboardError = copyError;
        console.warn('온라인 프롬프트 클립보드 복사 실패', copyError);
        clientLog('error', '클립보드 복사 실패 — ' + errorDescription(copyError));
        // 복사가 실패하면 이동하지 않는다. 사용자가 빈 온라인 탭에서 헤매지 않도록
        // 현재 문서에 전문과 두 번째 클릭용 열기 버튼을 먼저 제공한다.
        showOnlineTransfer(bundle, false, false, clipboardError);
        return;
      }

      // window.open은 반드시 writeText 성공 뒤에만 실행한다. 먼저 열면 현재 문서가
      // 포커스를 잃어 Clipboard API가 NotAllowedError로 실패한다.
      const openedWindow = window.open(bundle.url, '_blank');
      const popupBlocked = !openedWindow;
      if (popupBlocked) clientLog('warn', '온라인 요약 팝업 차단 — 첫 열기');
      showOnlineTransfer(bundle, true, popupBlocked, null);
      return;
    }

    // 저장된 옛 요약을 보고 있었다면, 실패 시 보존해야 할 현재 세션 요약으로 먼저 돌아온다.
    showCurrentSummary(state.summary);
    state.summarizing = true;
    notice('#sumNotice', '', '');
    showSummaryProgress('요약을 준비하는 중입니다.', true);
    updateSummaryControls();
    const requestBody = {};
    if (range.fromUnit !== null) requestBody.fromUnit = range.fromUnit;
    if (range.toUnit !== null) requestBody.toUnit = range.toUnit;
    const response = await post('/api/summarize', requestBody);
    if (!response.ok) {
      state.summarizing = false;
      showSummaryProgress('');
      notice('#sumNotice', 'warn', esc(response.error || '요약을 시작하지 못했습니다.'));
      updateSummaryControls();
    }
  };

  $('#btnCancelSummary').onclick = async () => {
    $('#btnCancelSummary').disabled = true;
    const response = await post('/api/summarize/cancel', {});
    $('#btnCancelSummary').disabled = false;
    if (!response.ok) notice('#sumNotice', 'warn', esc(response.error || '취소하지 못했습니다.'));
  };

  $('#btnPromptFile').onclick = () => {
    const target = selectedSummaryTarget();
    if (target === 'local') return;
    const range = selectedSummaryRange();
    const query = new URLSearchParams({ target });
    if (range.fromUnit !== null) query.set('fromUnit', String(range.fromUnit));
    if (range.toUnit !== null) query.set('toUnit', String(range.toUnit));
    location.href = '/export/prompt.md?' + query.toString();
  };

  $('#btnImportSummary').onclick = () => $('#summaryFileInput').click();
  $('#summaryFileInput').onchange = () => {
    const selectedFile = $('#summaryFileInput').files?.[0];
    if (selectedFile) importSummaryFile(selectedFile);
    // 같은 파일을 고쳐 다시 선택해도 change가 다시 발생하도록 값을 비운다.
    $('#summaryFileInput').value = '';
  };
  $('#sumRangeStart').onchange = () => handleSummarySelectionChange('start');
  $('#sumRangeEnd').onchange = () => handleSummarySelectionChange('end');
  document.querySelectorAll('input[name="onlineTarget"]').forEach(targetInput => {
    targetInput.onchange = () => handleSummarySelectionChange();
  });

  $('#btnPolish').onclick = async () => {
    $('#btnPolish').disabled = true;
    notice('#polNotice', '', '');
    $('#polResult').innerHTML = '<p class="muted-note">모델을 준비하는 중…</p>';
    const r = await post('/api/polish/suggest');
    if (!r.ok) {
      notice('#polNotice', 'warn', esc(r.error || '실패'));
      $('#polResult').innerHTML = '';
      $('#btnPolish').disabled = false;
    }
  };

  // 미리보기 단계라 반영 버튼은 없다 — before/after/근거만 보여준다.
  // beforeExists=false 면 서버가 원문에서 그 글자를 못 찾았다는 뜻(모델이 살짝
  // 다르게 옮겨 적었을 수 있음), afterGrounded=false 면 교안·녹취 어디에도
  // 근거가 없다는 뜻 — 둘 다 사람이 거를 때 참고하라고 보여주는 것뿐이다.
  function renderPolish(corrections, model) {
    if (!corrections || !corrections.length) {
      $('#polResult').innerHTML = `<p class="muted-note">고칠 만한 표기 불일치를 못 찾았습니다. (모델: ${esc(model || '?')})</p>`;
      return;
    }
    $('#polResult').innerHTML =
      `<p class="hint" style="margin-bottom:10px">모델: ${esc(model)} · 제안 ${corrections.length}건 — 원문은 아직 안 바뀌었습니다.</p>` +
      corrections.map(c => `
        <div class="card" style="margin-bottom:8px;flex-direction:column;align-items:flex-start;gap:4px">
          <div><span style="text-decoration:line-through;color:var(--muted)">${esc(c.before)}</span>
            → <b>${esc(c.after)}</b></div>
          <div class="hint">${esc(c.reason || '')}</div>
          ${(!c.beforeExists || !c.afterGrounded) ? `<div class="hint" style="color:var(--warn)">
            ${!c.beforeExists ? '⚠ 원문에서 정확히 못 찾음 ' : ''}${!c.afterGrounded ? '⚠ 근거(교안/녹취) 없음' : ''}</div>` : ''}
        </div>`).join('');
  }
  // 마지막으로 요약이 훑은 지점을 보여주고, 다음 요약 시작점으로 넣을 수 있게 한다.
  function showLastSummarized(at) {
    state.lastSummarizedAt = Number(at) || 0;
    const continuationButton = $('#btnFromLast');
    delete continuationButton.dataset.unitId;
    const units = state.summaryUnits || [];
    if (units.length <= 1) {
      continuationButton.disabled = true;
      $('#sumRangeHint').textContent = '이 수업에는 강의 종료 표시가 없어 전체만 요약할 수 있습니다.';
      return;
    }
    if (!state.lastSummarizedAt) {
      continuationButton.disabled = true;
      $('#sumRangeHint').textContent = '구간을 고르지 않으면 전체를 요약합니다.';
      return;
    }
    // 마지막 요약 끝과 다음 구간 시작이 정확히 맞닿을 수 있어 >=를 쓴다. end보다
    // 작은 시작을 가진 현재 구간은 건너뛰고, 그 지점 이후에 시작하는 첫 id만 고른다.
    const continuationUnit = units.find(unit => Number(unit.start) >= state.lastSummarizedAt);
    if (!continuationUnit) {
      continuationButton.disabled = true;
      $('#sumRangeHint').innerHTML = '마지막 요약 지점: <b>' + clock(state.lastSummarizedAt)
        + '</b> — 이어서 요약할 새 구간이 없습니다.';
      return;
    }
    continuationButton.dataset.unitId = String(continuationUnit.id);
    continuationButton.disabled = running || stopping || !!state.summarizing;
    $('#sumRangeHint').innerHTML = '마지막 요약 지점: <b>' + clock(state.lastSummarizedAt)
      + '</b> — “이어서”는 ' + continuationUnit.id + '강부터 시작합니다.';
  }
  $('#btnFromLast').onclick = () => {
    const continuationUnitID = $('#btnFromLast').dataset.unitId;
    if (!continuationUnitID) return;
    $('#sumRangeStart').value = continuationUnitID;
    $('#sumRangeEnd').value = '';
    handleSummarySelectionChange('start');
  };

  $('#btnSumPick').onclick = async () => {
    $('#btnSumPick').disabled = true;
    const r = await post('/api/pickFolder');
    $('#btnSumPick').disabled = false;
    if (r.ok && r.path) $('#sumDir').value = r.path;
  };
  $('#btnSumSave').onclick = async () => {
    const r = await post('/api/summary/save', {
      dir: $('#sumDir').value, filename: $('#sumName').value
    });
    $('#sumSaveHint').textContent = r.ok ? '저장했습니다: ' + r.path : (r.error || '저장 실패');
    if (r.ok) renderSummaryFiles(r.summaries || []);
  };

  // 1교시·2교시로 나눠 저장한 요약들을 다시 찾아 열 수 있게 한다.
  // 세션 안에는 마지막 요약 하나만 남기 때문에, 앞선 것은 파일로만 존재한다.
  function renderSummaryFiles(list) {
    $('#sumFilesBox').style.display = list.length ? '' : 'none';
    $('#sumFiles').innerHTML = list.map(f => {
      const when = new Date(f.savedAt * 1000)
        .toLocaleString('ko-KR', { month:'numeric', day:'numeric', hour:'2-digit', minute:'2-digit' });
      return `<div class="card"><div class="meta"><div class="name">${esc(f.name)}</div>` +
             `<div class="sub">${when} · ${(f.size/1024).toFixed(0)}KB</div></div>` +
             `<button class="sm" data-sum="${esc(f.path)}">열기</button></div>`;
    }).join('');
    $('#sumFiles').querySelectorAll('[data-sum]').forEach(b => b.onclick = async () => {
      const r = await post('/api/summary/open', { path: b.dataset.sum });
      if (!r.ok) { notice('#sumNotice', 'warn', esc(r.error)); return; }
      $('#summary').innerHTML = md(r.markdown);
      const name = b.previousElementSibling.querySelector('.name').textContent;
      $('#summarySource').textContent = name;
      $('#btnCurrentSummary').style.display = '';
      // 이 상태에서 서버 저장을 누르면 화면의 옛 파일이 아니라 현재 세션 요약이 저장된다.
      // 오해를 막기 위해 현재 요약으로 돌아오기 전까지 저장 도구는 숨긴다.
      $('#saveSummaryBox').style.display = 'none';
      notice('#sumNotice', 'info', esc(name) + ' 를 불러왔습니다.');
      setWorkspaceView('summary');
      $('.summaryScroll').scrollTop = 0;
    });
  }
  async function loadSummaryFiles() {
    const r = await fetch('/api/summaries').then(r => r.json()).catch(() => null);
    if (r) renderSummaryFiles(r.summaries || []);
  }

  $('#btnMd').onclick = () => location.href = '/export/md';
  $('#btnSrt').onclick = () => location.href = '/export/srt';
  $('#btnCurrentSummary').onclick = () => {
    showCurrentSummary(state.summary, true);
    $('.summaryScroll').scrollTop = 0;
  };

  $('#btnNewSession').onclick = async () => {
    if (lines.size && !confirm('현재 기록을 닫고 새 세션을 시작할까요? (저장된 파일은 그대로 남습니다)')) return;
    const r = await post('/api/session/new');
    if (r.ok) { reloadAll(r.state); $('#docInfo').innerHTML = ''; loadSessions(); }
  };
  $('#btnSave').onclick = async () => {
    const r = await post('/api/save');
    notice('#sesNotice', r.ok ? 'info' : 'warn', r.ok ? '저장했습니다.' : esc(r.error));
    if (r.ok) { loadSessions(); fetch('/api/state').then(x => x.json()).then(renderSession); }
  };
  $('#btnOpenElsewhere').onclick = async () => {
    $('#btnOpenElsewhere').disabled = true;
    const picked = await post('/api/pickFolder');
    $('#btnOpenElsewhere').disabled = false;
    if (!picked.ok || !picked.path) return;          // 취소 — 조용히 무시 (#btnPick과 동일)
    const r = await post('/api/session/open', { path: picked.path });
    if (!r.ok) { notice('#sesNotice', 'warn', esc(r.error)); return; }
    reloadAll(r.state);
  };
  $('#btnPick').onclick = async () => {
    $('#btnPick').disabled = true;
    const r = await post('/api/pickFolder');
    $('#btnPick').disabled = false;
    if (r.ok && r.path) {
      $('#baseDir').value = r.path;
      await post('/api/settings/storageLocation', { path: r.path });
    }
  };

  // 교안 업로드
  const drop = $('#drop'), pdfInput = $('#pdfInput');
  drop.onclick = () => pdfInput.click();
  drop.ondragover = e => { e.preventDefault(); drop.classList.add('over'); };
  drop.ondragleave = () => drop.classList.remove('over');
  drop.ondrop = e => { e.preventDefault(); drop.classList.remove('over');
                       if (e.dataTransfer.files[0]) upload(e.dataTransfer.files[0]); };
  pdfInput.onchange = () => pdfInput.files[0] && upload(pdfInput.files[0]);

  // 온라인 LLM에서 아티팩트를 .md로 내려받은 사용자를 위한 경로다. ~/Downloads를
  // 감시하면 macOS 폴더 접근 권한이 추가로 필요하므로 권한 없는 드래그앤드롭만 쓴다.
  const summaryDropZone = $('#view-summary');
  let summaryDragDepth = 0;
  summaryDropZone.addEventListener('dragenter', event => {
    if (![...(event.dataTransfer?.items || [])].some(item => item.kind === 'file')) return;
    event.preventDefault();
    summaryDragDepth += 1;
    summaryDropZone.classList.add('summaryDropActive');
  });
  summaryDropZone.addEventListener('dragover', event => {
    event.preventDefault();
    summaryDropZone.classList.add('summaryDropActive');
  });
  summaryDropZone.addEventListener('dragleave', () => {
    summaryDragDepth = Math.max(0, summaryDragDepth - 1);
    if (summaryDragDepth === 0) summaryDropZone.classList.remove('summaryDropActive');
  });
  summaryDropZone.addEventListener('drop', event => {
    event.preventDefault();
    summaryDragDepth = 0;
    summaryDropZone.classList.remove('summaryDropActive');
    const summaryFile = event.dataTransfer?.files?.[0];
    if (!summaryFile) return;
    if (!/\.(md|markdown|txt)$/i.test(summaryFile.name)) {
      notice('#sumNotice', 'warn', '마크다운(.md, .markdown)이나 텍스트(.txt) 파일만 받을 수 있습니다.');
      return;
    }
    const fileReader = new FileReader();
    fileReader.onload = async () => {
      const markdownText = typeof fileReader.result === 'string' ? fileReader.result : '';
      await importOnlineSummary(markdownText);
    };
    fileReader.onerror = () => notice('#sumNotice', 'warn', '요약 파일을 읽지 못했습니다.');
    fileReader.readAsText(summaryFile);
  });

  async function upload(file) {
    if (!/\.pdf$/i.test(file.name)) { notice('#docInfo', 'warn', 'PDF 파일만 됩니다.'); return; }
    $('#docInfo').innerHTML = `<div class="hint">분석 중… (${(file.size/1048576).toFixed(1)}MB)</div>`;
    const r = await fetch('/api/domain?name=' + encodeURIComponent(file.name), {
      method: 'POST', headers: {'Content-Type': 'application/pdf'}, body: file
    }).then(r => r.json()).catch(() => ({ ok: false, error: '업로드 실패 (파일이 너무 큰가요?)' }));
    if (!r.ok) { $('#docInfo').innerHTML = `<div class="notice warn">${esc(r.error)}</div>`; return; }
    renderDoc(r);
  }

  // ── 정렬·대조 ──
  //
  // 두 기록을 글자 단위로 맞춰 어디서 갈리는지 보여 준다.
  // 실측(600초 실제 강의): 72% 일치, 나머지는 표기/누락/다름 세 갈래로 나뉜다.
  // 갈래마다 처리법이 달라서 색을 다르게 준다.
  // 통계만 보여 준다. 갈린 지점 하나하나는 **본문에 밑줄로** 나오므로
  // 여기 목록은 같은 걸 두 번 그리는 것이었다 — DOM 4,001 노드에 응답 776KB 를 먹었다.
  async function loadCompare() {
    const c = await fetch('/api/compare?stats=1').then(r => r.json()).catch(() => null);
    if (!c || !c.hasBoth) { $('#cmpStat').innerHTML = ''; return; }
    const d = c.diffChars || 1;
    $('#cmpStat').innerHTML =
      `<div class="notice info">두 기록이 <b>${(c.agreeRatio*100).toFixed(1)}%</b> 일치합니다 ` +
      `(${c.agreeChars}자 / ${c.totalChars}자)</div>` +
      `<div class="hint">갈리는 ${d}자 — 표기 ${c.script}자(${(c.script/d*100).toFixed(0)}%) · ` +
      `누락 ${c.missing}자(${(c.missing/d*100).toFixed(0)}%) · ` +
      `다름 ${c.differ}자(${(c.differ/d*100).toFixed(0)}%)` +
      `<br>갈린 자리는 위 칸 본문에 밑줄로 표시됩니다 — <b>갈린 곳 표시</b>를 켜세요.</div>`;
  }

  // 본문에서 직접 고친 것을 전부 원래대로 되돌린다.
  $('#btnCorrectRevert').onclick = async () => {
    const r = await post('/api/correct/revert');
    if (!r.ok) { toast(r.error || '되돌리지 못했습니다.'); return; }
    reloadAll(r.state);
    notice('#cmpNotice', 'info', `${r.reverted}줄을 교정 전으로 되돌렸습니다.`);
    loadCompare();
  };

  // ── 표본 모으기 ──
  //
  // 정답지를 통째로 받아쓰게 하면 5분 구간에 800자다. 그래서 아무도 안 한다.
  // 갈린 자리는 대부분 둘 중 하나가 맞으니, **듣고 고르기**로 바꾸면 한 지점에 몇 초다.
  // 소리를 들려주는 게 핵심이다 — 못 들으면 판정이 아니라 짐작이 된다.
  let goldQueue = [], goldIdx = 0, goldJudged = new Set(), goldAudio = null, goldOn = false;

  async function loadGold() {
    const g = await fetch('/api/gold').then(r => r.json()).catch(() => null);
    if (!g) return;
    goldJudged = new Set(g.judged || []);
    renderGoldScore(g.score, g.hasAudio);
  }

  function renderGoldScore(s, hasAudio) {
    const el = $('#goldScore');
    if (hasAudio === false) {
      el.innerHTML = '<div class="notice warn">저장된 소리가 없어 표본을 모을 수 없습니다. ' +
        '소리가 있는 세션에서만 됩니다.</div>';
      $('#btnGold').disabled = true;
      return;
    }
    $('#btnGold').disabled = false;
    if (!s || !s.judged) { el.innerHTML = ''; return; }
    const pct = v => (v * 100).toFixed(0) + '%';
    el.innerHTML =
      `<div class="scoreGrid">` +
      `<div class="${s.live > s.whisper ? 'win' : ''}"><div class="k">실시간이 맞음</div>` +
      `<div class="v">${s.live}</div><div class="k">${pct(s.liveRatio)}</div></div>` +
      `<div class="${s.whisper > s.live ? 'win' : ''}"><div class="k">Whisper가 맞음</div>` +
      `<div class="v">${s.whisper}</div><div class="k">${pct(s.whisperRatio)}</div></div>` +
      `<div><div class="k">둘 다 틀림</div><div class="v">${s.both}</div>` +
      `<div class="k">${pct(s.bothRatio)}</div></div></div>` +
      `<div class="hint" style="margin-top:7px">표본 ${s.judged}개. ` +
      `<b>둘 다 틀림</b>이 많을수록 두 전사기가 함께 놓치는 자리가 많다는 뜻입니다.</div>`;
  }

  function goldPlay() {
    const b = goldQueue[goldIdx];
    if (!b) return;
    // 갈린 지점의 시각은 그 문장이 시작한 시각이라, 낱말은 조금 뒤에 나온다. 넉넉히 잡는다.
    const from = Math.max(0, b.start - 1.0);
    const to = b.end > b.start + 0.5 ? b.end + 2.0 : b.start + 6.0;
    if (goldAudio) { goldAudio.pause(); goldAudio = null; }
    const btn = $('#goldPlay');
    goldAudio = new Audio(`/api/audio?from=${from.toFixed(2)}&to=${to.toFixed(2)}`);
    btn.classList.add('on');
    btn.textContent = '♪ 듣는 중…';
    goldAudio.onended = () => { btn.classList.remove('on'); btn.textContent = '▶ 다시 듣기 (Space)'; };
    goldAudio.onerror = () => {
      btn.classList.remove('on');
      btn.textContent = '이 구간 소리를 찾지 못했습니다';
    };
    goldAudio.play().catch(() => {
      btn.classList.remove('on');
      btn.textContent = '▶ 눌러서 듣기';
    });
  }

  function renderGold() {
    const b = goldQueue[goldIdx];
    if (!b) { endGold(true); return; }
    $('#goldPos').textContent = goldIdx + 1;
    $('#goldTotal').textContent = goldQueue.length;
    $('#goldFill').style.width = (goldIdx / goldQueue.length * 100).toFixed(1) + '%';
    const label = { script: '표기', missing: '누락', differ: '다름' };
    $('#goldWhen').textContent = `${clock(b.start)} · ${label[b.kind] || b.kind}`;
    // 정규화된 글자가 아니라 원문 그대로 보여준다. 안 그러면 사람도 엉뚱한 걸 고른다.
    $('#goldLive').textContent = b.liveRaw || '(없음)';
    $('#goldWhisper').textContent = b.whisperRaw || '(없음)';
    document.querySelector('.goldOpt[data-v="live"]').disabled = !b.live;
    document.querySelector('.goldOpt[data-v="whisper"]').disabled = !b.whisper;
    $('#goldTruthWrap').style.display = 'none';
    $('#goldTruth').value = '';
    goldPlay();
  }

  async function goldJudge(verdict, truth) {
    const b = goldQueue[goldIdx];
    if (!b) return;
    // 둘 다 틀렸다면 실제로 뭐라고 했는지는 사람만 안다. 받아 적게 한다.
    if (verdict === 'both' && !truth) {
      $('#goldTruthWrap').style.display = '';
      $('#goldTruth').focus();
      return;
    }
    // 화면에 보여준 것과 **똑같은 원문**을 보낸다.
    // 정규화된 글자(hashmap이나hashset)를 보내면 사람이 본 것과 다른 게 정답으로 박힌다.
    const r = await post('/api/gold', {
      start: b.start, end: b.end, kind: b.kind,
      live: b.liveRaw || b.live, whisper: b.whisperRaw || b.whisper,
      verdict, truth: truth || '',
    });
    if (r && r.ok) {
      goldJudged.add(b.key);
      renderGoldScore(r.score, true);
    } else if (r && r.error) {
      notice('#cmpNotice', 'warn', r.error);
      return;
    }
    goldIdx++;
    renderGold();
  }

  function endGold(finished) {
    goldOn = false;
    if (goldAudio) { goldAudio.pause(); goldAudio = null; }
    $('#goldCard').style.display = 'none';
    $('#btnGold').textContent = '표본 모으기 시작';
    if (finished) notice('#cmpNotice', 'info', '이 세션에서 볼 지점을 다 봤습니다.');
  }

  $('#btnGold').onclick = async () => {
    if (goldOn) { endGold(false); return; }
    const skip = $('#goldSkip').checked;
    // 목록을 화면에 안 그리므로 여기서만 직접 받아 온다.
    const c = await fetch('/api/compare').then(r => r.json()).catch(() => null);
    const blocks = (c && c.blocks || []).filter(b => b.kind !== 'same');
    goldQueue = blocks.filter(b => !skip || !goldJudged.has(b.key));
    if (!goldQueue.length) {
      notice('#cmpNotice', 'info',
        skip ? '아직 판정하지 않은 지점이 없습니다.' : '갈린 지점이 없습니다.');
      return;
    }
    goldOn = true;
    goldIdx = 0;
    $('#goldCard').style.display = '';
    $('#btnGold').textContent = '그만하기';
    renderGold();
  };

  document.querySelectorAll('.goldOpt').forEach(btn => {
    btn.onclick = () => goldJudge(btn.dataset.v);
  });
  $('#goldPlay').onclick = goldPlay;
  $('#goldTruth').onkeydown = e => {
    if (e.key === 'Enter') { e.preventDefault(); goldJudge('both', $('#goldTruth').value.trim()); }
    if (e.key === 'Escape') { $('#goldTruthWrap').style.display = 'none'; $('#goldTruth').blur(); }
    e.stopPropagation();
  };

  // 손이 자판에 있는 채로 끝나야 빠르다. 다른 입력칸에 있을 때는 가로채지 않는다.
  document.addEventListener('keydown', e => {
    if (!goldOn) return;
    const t = e.target.tagName;
    if (t === 'INPUT' || t === 'TEXTAREA' || e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key === ' ') { e.preventDefault(); goldPlay(); return; }
    if (e.key === 'Escape') { endGold(false); return; }
    if (e.key === 'ArrowLeft') { if (goldIdx > 0) { goldIdx--; renderGold(); } return; }
    const map = { '1': 'live', '2': 'whisper', '3': 'both', '4': 'unclear' };
    if (map[e.key]) { e.preventDefault(); goldJudge(map[e.key]); }
  });

  // ── 문제 해결 ──
  async function loadDiag() {
    try {
      const [d, l] = await Promise.all([
        fetch('/api/diag').then(r => r.json()),
        fetch('/api/logs?limit=1').then(r => r.json())
      ]);
      const total = (l.files || []).reduce((a, f) => a + f.size, 0);
      $('#diagBox').innerHTML =
        `요약 엔진: ${esc(state.summaryEngine || '-')}<br>` +
        `오디오 입력: ${esc(d.levelAdvice || '-')}<br>` +
        (d.framesSeen ? `피크 ${(d.peakDBFS).toFixed(1)} dBFS · RMS ${(d.rms).toFixed(4)}<br>` : '') +
        `캡처 경로: ${esc(d.captureScope || '-')} · ` +
          `${d.captureHasReceivedBuffer ? `${Number(d.secondsSinceCaptureBuffer || 0).toFixed(1)}초 전 버퍼 수신` : '버퍼 대기'}<br>` +
        `소리 보관: ${d.audioClips ? `${d.audioClips}개 · ${clock(d.audioSeconds)} · ${d.audioMB.toFixed(0)}MB` : '없음'}<br>` +
        `재전사: ${d.whisperReady ? '' : '<b>불가</b> — '}${esc(d.whisperDetail || '-')}<br>` +
        `교안 캐시: ${d.domainCacheCount}개 · ${d.domainCacheKB}KB<br>` +
        `로그: ${(l.files || []).length}개 · ${(total/1024).toFixed(0)}KB · ${l.retentionDays}일 보관<br>` +
        `<span style="word-break:break-all">${esc(l.directory || '')}</span>`;
    } catch { $('#diagBox').textContent = '진단 정보를 읽지 못했습니다.'; }
  }
  $('#btnLogs').onclick = async () => {
    const v = $('#logView');
    if (v.classList.contains('on')) { v.classList.remove('on'); $('#btnLogs').textContent = '로그 보기'; return; }
    const r = await fetch('/api/logs?limit=400').then(r => r.json());
    v.innerHTML = (r.lines || []).map(line => {
      const cls = /\[ERROR/.test(line) ? 'err' : /\[WARN/.test(line) ? 'warn' : '';
      return cls ? `<span class="${cls}">${esc(line)}</span>` : esc(line);
    }).join('\n') || '(비어 있음)';
    v.classList.add('on');
    v.scrollTop = v.scrollHeight;
    $('#btnLogs').textContent = '로그 닫기';
  };
  $('#btnLogFolder').onclick = () => post('/api/logs/reveal');
  $('#btnClearCache').onclick = async () => {
    if (!confirm('교안 분석 캐시를 비울까요?\n다음에 같은 교안을 올리면 처음부터 다시 분석합니다(30초쯤).')) return;
    await post('/api/domain/cache/clear');
    loadDiag();
  };
  $('#btnCopyDiag').onclick = async () => {
    const [d, l, st] = await Promise.all([
      fetch('/api/diag').then(r => r.json()),
      fetch('/api/logs?limit=120').then(r => r.json()),
      fetch('/api/state').then(r => r.json())
    ]);
    const text = [
      '## ZoomCaption 진단',
      '요약 엔진: ' + (st.summaryEngine || '-'),
      '녹음 중: ' + st.running + ' / 자막 ' + (st.segments || []).length + '줄',
      '세션: ' + (st.sessionDir || '없음'),
      '오디오 프레임: ' + d.framesSeen + ', 소리 감지: ' + d.heardSound,
      '탭 포맷: ' + d.sourceFormat + ', 피크 ' + (d.peakDBFS||0).toFixed(1) + ' dBFS',
      '캡처 경로: ' + (d.captureScope || '-') + ', 최근 버퍼: '
        + (d.captureHasReceivedBuffer ? Number(d.secondsSinceCaptureBuffer || 0).toFixed(1) + '초 전' : '없음'),
      '소리 보관: ' + d.audioClips + '개 / ' + d.audioSeconds + '초 / ' + (d.audioMB||0).toFixed(0) + 'MB',
      'whisper: ' + (d.whisperReady ? 'OK' : '불가') + ' — ' + d.whisperDetail,
      'whisper 실행 파일: ' + (d.whisperBinary || '없음') + ', 재전사 중: ' + d.retranscribing,
      'Whisper 기록: ' + (st.whisperLines || 0) + '줄',
      '', '## 최근 로그', ...(l.lines || [])
    ].join('\n');
    try {
      await navigator.clipboard.writeText(text);
      $('#diagBox').insertAdjacentHTML('beforeend', '<br><b>진단 정보를 복사했습니다.</b>');
    } catch {
      $('#logView').textContent = text; $('#logView').classList.add('on');
    }
  };

  // ── 완전 종료 ──
  // 브라우저 탭을 닫는 것만으로는 앱이 꺼지지 않는다. 녹음은 뒤에서 계속 돌기 때문에
  // "완전히 끄는" 길은 따로 있어야 하고, 정말 꺼졌는지도 확인해서 알려 줘야 한다.
  // 종료 절차를 밟는 중인가. 이때는 창 닫기를 붙잡지 않는다.
  let quitting = false;
  let quitReturnFocus = { current: null };

  function askQuit() {
    quitReturnFocus.current = document.activeElement;
    $('#quitTitle').textContent = '진짜 종료하시겠습니까?';
    $('#quitBody').innerHTML = running
      ? '지금 <b>녹음 중</b>입니다. 종료하면 여기까지의 기록을 저장한 뒤 앱이 완전히 꺼집니다.'
      : '앱 자체가 꺼집니다. 저장된 기록은 폴더에 그대로 남습니다. '
        + '다시 쓰려면 ZoomCaption 앱을 열면 됩니다.';
    $('#quitCancel').textContent = '취소';
    $('.quitBtns').hidden = false;
    $('#quitGo').disabled = false;
    $('#quitCancel').disabled = false;
    $('#quitVeil').hidden = false;
    $('#quitCancel').focus();
  }

  function closeQuitDialog() {
    $('#quitVeil').hidden = true;
    if (quitReturnFocus.current && document.contains(quitReturnFocus.current)) {
      quitReturnFocus.current.focus();
    }
  }

  // 서버가 응답을 멈출 때까지 확인한다. 응답이 끊겨야 진짜로 죽은 것이다.
  async function confirmDead(deadline) {
    while (Date.now() < deadline) {
      await new Promise(r => setTimeout(r, 400));
      try {
        const c = new AbortController();
        setTimeout(() => c.abort(), 900);
        await fetch('/api/state', { signal: c.signal, cache: 'no-store' });
      } catch { return true; }     // 연결 실패 = 프로세스가 사라짐
    }
    return false;
  }

  $('#quitGo').onclick = async () => {
    quitting = true;             // 이제부터는 창을 닫아도 붙잡지 않는다
    $('#quitGo').disabled = true; $('#quitCancel').disabled = true;
    $('#quitTitle').textContent = '종료하는 중…';
    $('#quitBody').textContent = '녹음을 멈추고 기록을 저장하고 있습니다.';
    es.close();                    // 끊긴 SSE 가 자동 재연결하며 소음을 내지 않도록
    try { await post('/api/quit'); } catch {}

    if (await confirmDead(Date.now() + 12000)) {
      $('#quitVeil').hidden = true;
      document.body.innerHTML =
        '<div class="empty" style="margin:auto">ZoomCaption이 완전히 종료되었습니다.<br>이 창은 닫아도 됩니다.</div>';
      return;
    }
    // 여기까지 왔으면 앱이 안 죽은 것이다. 얼버무리지 말고 손으로 끄는 법을 준다.
    $('#quitTitle').textContent = '종료되지 않았습니다';
    $('#quitBody').innerHTML =
      '앱이 아직 응답하고 있습니다. 터미널에서 아래를 실행해 강제로 끄세요.'
      + '<code>pkill -f ZoomCaption.app</code>'
      + '설정 탭의 <b>진단 복사</b> 를 눌러 로그를 함께 남겨 주시면 원인을 찾을 수 있습니다.';
    $('.quitBtns').hidden = true;
  };
  $('#quitCancel').onclick = closeQuitDialog;
  $('#quitVeil').onclick = e => { if (e.target === $('#quitVeil')) closeQuitDialog(); };
  document.addEventListener('keydown', e => {
    if ($('#quitVeil').hidden) return;
    if (e.key === 'Escape' && !$('#quitCancel').disabled) closeQuitDialog();
    if (e.key === 'Tab') {
      const focusable = [...$('#quitVeil').querySelectorAll('button:not(:disabled)')];
      if (!focusable.length) return;
      const first = focusable[0], last = focusable[focusable.length - 1];
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    }
  });
  $('#btnQuitTop').onclick = askQuit;
  $('#btnQuit').onclick = askQuit;

  // ── 창을 닫으려 할 때 ──
  //
  // 이 앱은 Dock 아이콘이 없어서, 창만 닫으면 **앱이 계속 도는 줄 모른다.**
  // 실제로 그 상태에서 앱을 다시 열면 빈 페이지만 뜨는 사고가 났다.
  //
  // 브라우저 제약이 둘 있다 — beforeunload 에서는 ① 문구를 바꾼 창을 띄울 수 없고
  // ② 비동기 작업(종료 요청)을 걸 수 없다. 그래서 이렇게 나눈다:
  //   1) 나가려 하면 브라우저 기본 확인창으로 일단 붙잡는다.
  //   2) 사용자가 "머무르기" 를 골라 페이지가 살아 있으면, 그때 우리 창을 띄워
  //      **앱이 아직 돌고 있다는 사실**과 정말 끌지를 묻는다.
  let leaveGuard = 0;
  window.addEventListener('beforeunload', e => {
    // 이미 종료 절차를 밟는 중이면 붙잡지 않는다.
    if (quitting) return;
    leaveGuard = Date.now();
    e.preventDefault();
    e.returnValue = '';
  });

  // beforeunload 뒤에도 페이지가 살아 있으면 = 사용자가 나가기를 취소한 것이다.
  window.addEventListener('focus', () => {
    if (!leaveGuard || Date.now() - leaveGuard > 60000) return;
    leaveGuard = 0;
    if (quitting || !$('#quitVeil').hidden) return;
    askLeave();
  });

  /// 창을 닫으려 했을 때 묻는다. 앱이 살아 있는지 실제로 확인해서 알려 준다.
  async function askLeave() {
    let alive = false;
    try {
      const c = new AbortController();
      setTimeout(() => c.abort(), 1500);
      alive = (await fetch('/api/state', { signal: c.signal, cache: 'no-store' })).ok;
    } catch { alive = false; }

    if (!alive) {
      // 이미 죽어 있으면 붙잡을 이유가 없다. 창을 닫아도 된다고 알려만 준다.
      $('#quitTitle').textContent = '앱은 이미 꺼져 있습니다';
      $('#quitBody').textContent = '이 창은 닫아도 됩니다.';
      $('.quitBtns').hidden = true;
      $('#quitVeil').hidden = false;
      return;
    }
    $('#quitTitle').textContent = '진짜 종료하시겠습니까?';
    $('#quitBody').innerHTML =
      'ZoomCaption 은 <b>아직 돌고 있습니다</b>. 창만 닫으면 앱은 그대로 남습니다'
      + (running ? ' — 지금 <b>녹음 중</b>이라 계속 기록됩니다.' : '.')
      + '<br><br><b>완전 종료</b> 를 누르면 기록을 저장한 뒤 앱을 끕니다. '
      + '<b>계속 쓰기</b> 를 누르면 이대로 둡니다.';
    $('#quitCancel').textContent = '계속 쓰기';
    $('.quitBtns').hidden = false;
    $('#quitGo').disabled = false;
    $('#quitCancel').disabled = false;
    $('#quitVeil').hidden = false;
  }

  // ── 갈린 곳 표시 ──
  $('#showDiv').onchange = async () => {
    closeDiv();
    if ($('#showDiv').checked) {
      await loadDivs();
    } else {
      divs.clear();
      $('#divCount').textContent = '';
      $('#divBar').style.display = 'none';
      stream.querySelectorAll('.line').forEach(paintDivs);
    }
  };
  // 패널이 펴져 있을 때만 듣는다. 평소에는 숫자 키를 가로채지 않는다.
  document.addEventListener('keydown', e => {
    if (!divOpen) return;
    if (e.target && /^(INPUT|TEXTAREA)$/.test(e.target.tagName)) return;
    if (e.key === 'Escape') { e.preventDefault(); closeDiv(); return; }
    if (e.key === ' ')      { e.preventDefault(); handleFix('play'); return; }
    const map = { '1': 'live', '2': 'whisper', '3': 'type' };
    if (map[e.key]) { e.preventDefault(); handleFix(map[e.key]); }
  });
  // 본문 밖을 누르면 접는다.
  document.addEventListener('click', e => {
    if (!divOpen) return;
    if (e.target.closest('.fixBox') || e.target.closest('.dv')) return;
    closeDiv();
  });

  // ── 무음 의심 ──
  //
  // 지우지 않는다. 표본이 아직 환각 6건뿐이라, 우선 사람이 듣고 확인하는 단계다.
  $('#btnQuiet').onclick = async () => {
    const btn = $('#btnQuiet');
    btn.disabled = true; btn.textContent = '소리를 대조하는 중…';
    let r = null;
    try { r = await fetch('/api/quiet').then(x => x.json()); } catch {}
    btn.disabled = false; btn.textContent = '무음 구간 찾기';
    const box = $('#quietResult');
    if (!r || !r.ok) {
      box.innerHTML = `<div class="notice warn">${esc((r && r.error) || '검사하지 못했습니다.')}</div>`;
      return;
    }
    if (!r.hasAudio) {
      box.innerHTML = '<div class="notice info">저장된 소리가 없어 대조할 수 없습니다. ' +
        '원본 소리를 보관한 세션에서만 다시 듣고 판정할 수 있습니다.</div>';
      return;
    }
    const undoBar = r.dropped
      ? `<div class="notice info" style="margin-top:9px">치워 둔 줄 <b>${r.dropped}개</b>가 있습니다. ` +
        `<button id="btnQuietRestore" class="sm" style="margin-left:6px">되돌리기</button></div>`
      : '';
    if (!r.items.length) {
      box.innerHTML = `<div class="notice info">Whisper ${r.checked}줄을 소리와 대조했습니다. ` +
        `<b>무음 위에 적힌 줄은 없습니다.</b></div>` + undoBar;
      wireQuietRestore();
      return;
    }
    // 소리도 없고 실시간 대응도 없으면 '확실', 하나만 걸리면 '의심'.
    const certain = r.items.filter(x => x.verdict === 'certain');
    box.innerHTML =
      `<div class="notice warn" style="margin-top:9px">${r.checked}줄 중 <b>${r.items.length}줄</b>이 ` +
      `${r.ceiling}dBFS 보다 조용한 구간에 적혀 있습니다.` +
      (r.hasLive
        ? ` 그중 <b>${certain.length}줄</b>은 같은 시각에 실시간 기록도 없어 <b>거의 확실</b>합니다.`
        : ' 실시간 기록이 없어 두 번째 확인은 못 했습니다.') +
      `</div>` + undoBar +
      (certain.length
        ? `<div class="row" style="margin-top:9px"><button id="btnQuietClean" class="sm danger">` +
          `확실한 ${certain.length}줄 한 번에 치우기</button>` +
          `<span class="hint" style="align-self:center">되돌릴 수 있습니다</span></div>`
        : '') +
      r.items.map(it =>
        `<div class="goldCard" style="padding:11px 13px;margin-top:8px">` +
        `<div class="fbRow"><span class="fbWho">${clock(it.start)}</span>` +
        `<span class="fbVal">${esc(it.text)}</span>` +
        `<span class="fbWho" style="color:${it.verdict === 'certain' ? 'var(--danger)' : 'var(--warn)'}">` +
        `${it.verdict === 'certain' ? '거의 확실' : '의심'}</span></div>` +
        `<div class="hint" style="margin-top:5px">피크 ${it.db.toFixed(1)} dBFS ` +
        `(사람 말소리는 대개 −5~−12 dBFS) · 실시간과 겹치는 글자 ${it.liveMatch}자` +
        `${it.liveMatch >= r.supportChars ? ' — 진짜 발화일 수 있습니다' : ''}</div>` +
        `<div class="fbBtns">` +
        `<button class="sm" data-qp="${it.start}|${it.end}">` +
        `▶ 이 줄이 주장하는 ${(it.end - it.start).toFixed(0)}초만 듣기</button>` +
        `<button class="sm" data-qw="${it.start}|${it.end}">▶ 앞뒤 3초까지</button>` +
        `<button class="sm danger" data-qd="${it.id}">이 줄 지우기</button></div></div>`
      ).join('');
    // **여유 없이 그 구간만** 들려준다.
    // 앞뒤로 조금만 넓혀도 옆 발화가 들어와 판단이 뒤집힌다 —
    // 실측: 358.0~360.0초는 −78.3dBFS 인데 ±1초만 줘도 −8.5dBFS 가 된다.
    box.querySelectorAll('[data-qp]').forEach(b => b.onclick = () => {
      const [a, z] = b.dataset.qp.split('|').map(Number);
      new Audio(`/api/audio?from=${a.toFixed(2)}&to=${z.toFixed(2)}`).play().catch(() => {});
    });
    // 앞뒤 문맥이 궁금할 때만 따로. 무음 판정의 근거로 쓰면 안 된다.
    box.querySelectorAll('[data-qw]').forEach(b => b.onclick = () => {
      const [a, z] = b.dataset.qw.split('|').map(Number);
      new Audio(`/api/audio?from=${Math.max(0, a - 3).toFixed(2)}&to=${(z + 3).toFixed(2)}`)
        .play().catch(() => {});
    });
    box.querySelectorAll('[data-qd]').forEach(b => b.onclick = async () => {
      const id = +b.dataset.qd;
      const res = await post('/api/quiet/clean', { ids: [id] });
      if (res && res.ok) { removeLine(id); b.closest('.goldCard').remove(); toast('치웠습니다. 되돌릴 수 있습니다.'); }
    });
    const clean = $('#btnQuietClean');
    if (clean) clean.onclick = async () => {
      clean.disabled = true;
      const res = await post('/api/quiet/clean', { ids: certain.map(x => x.id) });
      if (res && res.ok) {
        reloadAll(res.state);
        toast(`${res.dropped}줄을 치웠습니다. 되돌릴 수 있습니다.`);
        $('#btnQuiet').click();
      } else clean.disabled = false;
    };
    wireQuietRestore();
  };

  function wireQuietRestore() {
    const b = $('#btnQuietRestore');
    if (!b) return;
    b.onclick = async () => {
      b.disabled = true;
      const res = await post('/api/quiet/restore');
      if (res && res.ok) {
        reloadAll(res.state);
        toast(`${res.restored}줄을 되돌렸습니다.`);
        $('#btnQuiet').click();
      } else b.disabled = false;
    };
  }

  // ── 관리자 모드 ──
  let administratorProbeRoutes = new Map();
  let administratorProbeProcesses = [];
  let administratorProbePollMilliseconds = 1000;
  let administratorProbeProcessSelect = $('#adminProbeProcess');
  let administratorProbeRouteSelect = $('#adminProbeRoute');
  let administratorProbeResult = $('#adminProbeResult');
  let administratorProbeStartButton = $('#btnAdminProbeStart');
  let administratorProbeStopButton = $('#btnAdminProbeStop');
  let administratorProbeRefreshButton = $('#btnAdminProbeRefresh');
  let administratorProbePoll = { timer: null };

  function renderAdministratorProbeRoutes() {
    const selectedProcessObjectID = Number(administratorProbeProcessSelect.value);
    const selectedProcess = administratorProbeProcesses.find(
      process => Number(process.objectID) === selectedProcessObjectID);
    administratorProbeRoutes.clear();
    administratorProbeRouteSelect.innerHTML = '';
    if (!selectedProcess) {
      administratorProbeRouteSelect.innerHTML = '<option value="">출력 경로 없음</option>';
      return;
    }

    // 프로세스 전체 측정을 항상 첫 후보로 둔다. 장치/스트림 결과가 이 값과 어떻게
    // 다른지를 비교해야 로컬 음성이 어느 단계에서 섞였는지 판단할 수 있다.
    administratorProbeRoutes.set('process-wide', { deviceUID: null, streamIndex: null });
    administratorProbeRouteSelect.insertAdjacentHTML(
      'beforeend', '<option value="process-wide">프로세스 전체 출력</option>');

    (selectedProcess.outputDevices || []).forEach((outputDevice, deviceArrayIndex) => {
      (outputDevice.streams || []).forEach(outputStream => {
        const routeKey = `device-${deviceArrayIndex}-stream-${outputStream.index}`;
        administratorProbeRoutes.set(routeKey, {
          deviceUID: outputDevice.uid,
          streamIndex: outputStream.index,
        });
        administratorProbeRouteSelect.insertAdjacentHTML('beforeend',
          `<option value="${esc(routeKey)}">${esc(outputDevice.name)} · stream ${outputStream.index}</option>`);
      });
    });
  }

  async function loadAdministratorProbeCandidates() {
    administratorProbeRefreshButton.disabled = true;
    try {
      const response = await fetch('/api/admin/audio/probe/candidates').then(result => result.json());
      administratorProbeProcesses.splice(0, administratorProbeProcesses.length,
                                          ...((response && response.processes) || []));
      administratorProbeProcessSelect.innerHTML = administratorProbeProcesses.length
        ? administratorProbeProcesses.map(audioProcess =>
            `<option value="${audioProcess.objectID}">${esc(audioProcess.bundleID)} · pid ${audioProcess.pid}`
            + `${audioProcess.hasActiveOutputIO ? ' · I/O 활성' : ''}</option>`).join('')
        : '<option value="">Zoom 오디오 프로세스 없음</option>';
      renderAdministratorProbeRoutes();
    } catch {
      administratorProbeResult.textContent = 'A/B 후보를 읽지 못했습니다.';
    } finally {
      administratorProbeRefreshButton.disabled = false;
    }
  }

  function renderAdministratorProbeSnapshot(probeSnapshot, isRunning) {
    if (!probeSnapshot) {
      administratorProbeResult.textContent = '측정 대기 중';
      return;
    }
    const bufferAge = probeSnapshot.secondsSinceBuffer == null
      ? '아직 없음'
      : `${Number(probeSnapshot.secondsSinceBuffer).toFixed(2)}초 전`;
    const nonSilentPercent = Number(probeSnapshot.nonSilentBufferRatio || 0) * 100;
    const routeDescription = probeSnapshot.deviceName
      ? `${probeSnapshot.deviceName} · stream ${probeSnapshot.streamIndex}`
      : '프로세스 전체 출력';
    administratorProbeResult.innerHTML =
      `<b>${isRunning ? '측정 중' : '측정 종료'}</b> — ${esc(probeSnapshot.bundleID)}<br>` +
      `${esc(routeDescription)} · ${esc(probeSnapshot.sourceFormat || '-')}<br>` +
      `피크 ${Number(probeSnapshot.peakDBFS ?? -120).toFixed(1)}dBFS · ` +
      `RMS ${Number(probeSnapshot.rms || 0).toFixed(5)} · ` +
      `비무음 버퍼 ${nonSilentPercent.toFixed(1)}%<br>` +
      `콜백 ${probeSnapshot.bufferCount || 0}개 · 최근 버퍼 ${bufferAge}`;
  }

  function stopAdministratorProbePolling() {
    if (administratorProbePoll.timer) clearInterval(administratorProbePoll.timer);
    administratorProbePoll.timer = null;
  }

  function startAdministratorProbePolling() {
    stopAdministratorProbePolling();
    administratorProbePoll.timer = setInterval(async () => {
      const response = await fetch('/api/admin/audio/probe').then(result => result.json())
        .catch(() => null);
      if (!response || !response.running) {
        stopAdministratorProbePolling();
        return;
      }
      renderAdministratorProbeSnapshot(response.probe, true);
    }, administratorProbePollMilliseconds);
  }

  async function loadAdmin() {
    const a = await fetch('/api/admin').then(r => r.json()).catch(() => null);
    if (!a || !a.enabled) return;
    // 무음 점검은 VAD 가 도는지 확인하는 계기판이라 관리자 모드에서만 연다.
    $('#quietBox').style.display = '';
    if (a.clips && a.clips.length) {
      $('#adminClips').innerHTML = '이 수업의 소리 조각: ' + a.clips.map(c =>
        `<a href="#" data-p="${esc(c.path)}">${esc(c.name)}</a>`).join(' · ');
      $('#adminClips').querySelectorAll('a').forEach(el => el.onclick = e => {
        e.preventDefault(); $('#adminPath').value = el.dataset.p;
      });
    }
    if (a.feeding) notice('#adminNote', 'info', `되먹이는 중 — ${a.note}`);
    await loadAdministratorProbeCandidates();
    if (a.audioProbe) {
      renderAdministratorProbeSnapshot(a.audioProbe, true);
      startAdministratorProbePolling();
    }
  }
  $('#btnAdminFeed').onclick = async () => {
    const r = await post('/api/admin/feed', {
      path: $('#adminPath').value.trim(),
      speed: parseFloat($('#adminSpeed').value) || 1,
    });
    notice('#adminNote', r.ok ? 'info' : 'warn',
           r.ok ? `되먹이는 중 — ${r.note}` : r.error);
  };
  $('#btnAdminStop').onclick = async () => {
    await post('/api/admin/feed/stop');
    notice('#adminNote', 'info', '되먹임을 멈췄습니다.');
  };
  es.addEventListener('adminFeed', e => {
    const d = JSON.parse(e.data);
    notice('#adminNote', 'info', `되먹임 ${d.why}. 정지를 누르면 기록이 저장됩니다.`);
  });
  administratorProbeProcessSelect.onchange = renderAdministratorProbeRoutes;
  administratorProbeRefreshButton.onclick = loadAdministratorProbeCandidates;
  administratorProbeStartButton.onclick = async () => {
    const selectedRoute = administratorProbeRoutes.get(administratorProbeRouteSelect.value);
    const selectedProcessObjectID = Number(administratorProbeProcessSelect.value);
    if (!selectedRoute || !selectedProcessObjectID) {
      administratorProbeResult.textContent = '측정할 프로세스와 출력 경로를 선택해 주세요.';
      return;
    }
    administratorProbeStartButton.disabled = true;
    const response = await post('/api/admin/audio/probe/start', {
      processObjectID: selectedProcessObjectID,
      deviceUID: selectedRoute.deviceUID,
      streamIndex: selectedRoute.streamIndex,
    });
    administratorProbeStartButton.disabled = false;
    if (!response.ok) {
      administratorProbeResult.textContent = response.error || 'A/B 측정을 시작하지 못했습니다.';
      return;
    }
    renderAdministratorProbeSnapshot(response.probe, true);
    startAdministratorProbePolling();
  };
  administratorProbeStopButton.onclick = async () => {
    stopAdministratorProbePolling();
    const response = await post('/api/admin/audio/probe/stop');
    if (response && response.probe) {
      renderAdministratorProbeSnapshot(response.probe, false);
    } else {
      administratorProbeResult.textContent = '측정이 종료되었습니다.';
    }
  };

  // 여러 수업의 표본을 합산한 성적. 한 수업만으로는 표본이 모자란다.
  async function loadGoldAll() {
    const a = await fetch('/api/gold/all').then(r => r.json()).catch(() => null);
    if (!a || !a.score || !a.score.judged) { $('#goldAll').innerHTML = ''; return; }
    const s = a.score, n = s.judged;
    $('#goldAll').innerHTML =
      `<b>전체 수업 누적</b> — 표본 ${n}개 (수업 ${a.sessions.length}개). ` +
      `실시간 ${s.live} · Whisper ${s.whisper} · 둘 다 틀림 ${s.both}` +
      (s.stale ? ` · 옛 형식 ${s.stale}개는 집계에서 뺐습니다` : '') +
      `<br>차이를 가리려면 <b>85개</b>쯤 필요합니다 (65:35 을 우연과 구분하는 기준).`;
  }

  $('#search').oninput = applyFilter;

  function applyCaptionSizePreference(requestedPreference, persistSelection = true) {
    const normalizedPreference = Object.hasOwn(captionSizePixelsByPreference, requestedPreference)
      ? requestedPreference : 'medium';
    document.documentElement.style.setProperty(
      '--cap', captionSizePixelsByPreference[normalizedPreference] + 'px');
    document.documentElement.style.setProperty(
      '--caption-line-height', captionLineHeightByPreference[normalizedPreference]);
    document.documentElement.style.setProperty(
      '--caption-row-padding', captionRowPaddingByPreference[normalizedPreference]);
    document.querySelectorAll('[data-caption-size]').forEach(captionSizeButton => {
      captionSizeButton.setAttribute(
        'aria-pressed', captionSizeButton.dataset.captionSize === normalizedPreference ? 'true' : 'false');
    });
    if (persistSelection) localStorage.setItem(captionSizeStorageKey, normalizedPreference);
  }

  const captionSizeButtons = [...document.querySelectorAll('[data-caption-size]')];
  captionSizeButtons.forEach((captionSizeButton, buttonIndex) => {
    captionSizeButton.onclick = () => applyCaptionSizePreference(captionSizeButton.dataset.captionSize);
    captionSizeButton.onkeydown = keyboardEvent => {
      let nextButtonIndex = null;
      if (keyboardEvent.key === 'ArrowRight') nextButtonIndex = (buttonIndex + 1) % captionSizeButtons.length;
      if (keyboardEvent.key === 'ArrowLeft') {
        nextButtonIndex = (buttonIndex - 1 + captionSizeButtons.length) % captionSizeButtons.length;
      }
      if (keyboardEvent.key === 'Home') nextButtonIndex = 0;
      if (keyboardEvent.key === 'End') nextButtonIndex = captionSizeButtons.length - 1;
      if (nextButtonIndex === null) return;
      keyboardEvent.preventDefault();
      const nextCaptionSizeButton = captionSizeButtons[nextButtonIndex];
      applyCaptionSizePreference(nextCaptionSizeButton.dataset.captionSize);
      nextCaptionSizeButton.focus();
    };
  });
  applyCaptionSizePreference(localStorage.getItem(captionSizeStorageKey) || 'medium', false);

  // 이 선택은 오디오 처리를 켜고 끄는 값이 아니다. Whisper는 항상 원본 오디오를
  // 처리하고, 이 값은 성공적으로 전사를 마친 뒤 WAV를 남길지만 결정한다.
  const retainOriginalAudioCheckbox = $('#retainOriginalAudio');
  retainOriginalAudioCheckbox.checked = localStorage.getItem(originalAudioRetentionStorageKey) !== '0';
  retainOriginalAudioCheckbox.onchange = () => {
    localStorage.setItem(originalAudioRetentionStorageKey,
                         retainOriginalAudioCheckbox.checked ? '1' : '0');
  };
  $('#title').onchange = () => post('/api/title', { title: $('#title').value });
  // 메인 화면과 보조 사이드 탭은 서로 다른 계층이다. selector를 분리해 한쪽 탭이
  // 다른 쪽 panel을 모두 숨기는 일을 막는다. 화면 전환은 DOM을 다시 만들지 않으므로
  // 90분 자막의 스크롤·검색·편집 상태도 그대로 남는다.
  function setWorkspaceView(view, focusTab = false) {
    const target = view === 'summary' ? 'summary' : 'whisper';
    document.querySelectorAll('.workspaceTab').forEach(tab => {
      const selected = tab.dataset.view === target;
      tab.classList.toggle('on', selected);
      tab.setAttribute('aria-selected', selected ? 'true' : 'false');
      tab.tabIndex = selected ? 0 : -1;
      if (selected && focusTab) tab.focus();
    });
    document.querySelectorAll('.workspaceView').forEach(panel => {
      panel.hidden = panel.id !== 'view-' + target;
    });
    document.body.classList.toggle('summary-view', target === 'summary');
  }

  const workspaceTabs = [...document.querySelectorAll('.workspaceTab')];
  workspaceTabs.forEach((tab, index) => {
    tab.onclick = () => setWorkspaceView(tab.dataset.view);
    tab.onkeydown = e => {
      let next = null;
      if (e.key === 'ArrowRight') next = (index + 1) % workspaceTabs.length;
      if (e.key === 'ArrowLeft') next = (index - 1 + workspaceTabs.length) % workspaceTabs.length;
      if (e.key === 'Home') next = 0;
      if (e.key === 'End') next = workspaceTabs.length - 1;
      if (next === null) return;
      e.preventDefault();
      setWorkspaceView(workspaceTabs[next].dataset.view, true);
    };
  });
  setWorkspaceView('whisper');

  const visibleSideTabs = [...document.querySelectorAll('aside .tab')]
    .filter(sideTab => !sideTab.classList.contains('administratorOnly') || isAdministratorMode);
  function activateSideTab(selectedSideTab, focusSelectedTab = false) {
    visibleSideTabs.forEach(sideTab => {
      const isSelected = sideTab === selectedSideTab;
      sideTab.classList.toggle('on', isSelected);
      sideTab.setAttribute('aria-selected', isSelected ? 'true' : 'false');
      sideTab.tabIndex = isSelected ? 0 : -1;
    });
    document.querySelectorAll('aside .panel').forEach(sidePanel => {
      sidePanel.classList.toggle('on', sidePanel.id === 'panel-' + selectedSideTab.dataset.tab);
    });
    if (focusSelectedTab) selectedSideTab.focus();
    if (selectedSideTab.dataset.tab === 'ses') loadSessions();
    if (selectedSideTab.dataset.tab === 'cfg') loadDiag();
    if (selectedSideTab.dataset.tab === 'adm') loadAdmin();
    if (selectedSideTab.dataset.tab === 'cmp') { loadCompare(); loadGold(); loadGoldAll(); }
  }
  visibleSideTabs.forEach((sideTab, sideTabIndex) => {
    sideTab.onclick = () => activateSideTab(sideTab);
    sideTab.onkeydown = keyboardEvent => {
      let nextSideTabIndex = null;
      if (keyboardEvent.key === 'ArrowRight') nextSideTabIndex = (sideTabIndex + 1) % visibleSideTabs.length;
      if (keyboardEvent.key === 'ArrowLeft') {
        nextSideTabIndex = (sideTabIndex - 1 + visibleSideTabs.length) % visibleSideTabs.length;
      }
      if (keyboardEvent.key === 'Home') nextSideTabIndex = 0;
      if (keyboardEvent.key === 'End') nextSideTabIndex = visibleSideTabs.length - 1;
      if (nextSideTabIndex === null) return;
      keyboardEvent.preventDefault();
      activateSideTab(visibleSideTabs[nextSideTabIndex], true);
    };
  });

  // ── 사이드 패널 접기 ──
  // 자막에 화면을 더 쓰고 싶을 때(예: 발표 화면 공유와 나란히 두기) 쓰라고 만든다.
  // 상태를 localStorage 에 남겨서, 접어 둔 채 새로고침해도 다시 안 펼쳐진다.
  const SIDE_KEY = 'zoomcaption.sideCollapsed';
  function setSideCollapsed(on) {
    document.body.classList.toggle('side-collapsed', on);
    $('#sideToggle').textContent = on ? '›' : '‹';
    $('#sideToggle').title = on ? '사이드 패널 펼치기' : '사이드 패널 접기';
    $('#sideToggle').setAttribute('aria-label', on ? '사이드 패널 펼치기' : '사이드 패널 접기');
    $('#sideToggle').setAttribute('aria-expanded', on ? 'false' : 'true');
    $('#utilityPanel').setAttribute('aria-hidden', on ? 'true' : 'false');
    localStorage.setItem(SIDE_KEY, on ? '1' : '0');
  }
  $('#sideToggle').onclick = () => setSideCollapsed(!document.body.classList.contains('side-collapsed'));
  setSideCollapsed(localStorage.getItem(SIDE_KEY) === '1');

  $('#btnResumeOK').onclick = () => $('#resumeBar').classList.remove('on');
  $('#btnSilentOK').onclick = () => showSilent('');

  fetch('/api/state').then(r => r.json()).then(s => {
    lastSeq = s.seq || 0; boot = s.boot;
    reloadAll(s);
    // 이 창이 시작한 게 아닌데 이미 녹음 중이면 분명히 알린다.
    // ZoomCaption 은 창을 닫아도 뒤에서 계속 받아쓰기 때문에,
    // 나중에 창을 다시 열면 "저절로 녹음이 켜진" 것처럼 보인다.
    if (s.running) {
      $('#resumeText').innerHTML =
        '<b>이미 녹음 중이던 세션입니다.</b> ' + clock(s.elapsed || 0) + ' 전에 시작해 지금까지 계속 기록하고 있었습니다. ' +
        '이 창을 닫아도 녹음은 멈추지 않습니다 — 끝내려면 <b>정지</b>를 누르세요.';
      $('#resumeBar').classList.add('on');
    }
    if (s.summarizerNote) notice('#sumNotice', 'warn', esc(s.summarizerNote));
    loadSessions();
  });
})();
"""#
}
