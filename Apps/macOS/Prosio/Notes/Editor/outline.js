// A reading aid outside ProseMirror: navigation never edits the note or its undo history.
export function createOutline({ headings, navigate, layout = () => {}, atEnd = () => false }) {
  const nav = document.createElement('nav');
  nav.className = 'note-outline';
  nav.hidden = true;
  nav.setAttribute('aria-label', '章节导航');
  nav.innerHTML = `<button class="note-outline-trigger" type="button" aria-label="展开章节目录" aria-expanded="false" aria-controls="note-outline-panel" title="章节目录">
    <span class="note-outline-icon" aria-hidden="true"><i></i><i></i><i></i></span>
    <span class="note-outline-marks" aria-hidden="true"></span>
  </button>
  <div class="note-outline-panel" id="note-outline-panel" inert>
    <div class="note-outline-header"><span>目录</span><span class="note-outline-count"></span></div>
    <div class="note-outline-list"></div>
    <div class="note-outline-footer">点击标题，跳转到章节</div>
  </div>`;
  document.body.append(nav);
  const trigger = nav.querySelector('.note-outline-trigger');
  const panel = nav.querySelector('.note-outline-panel');
  const list = nav.querySelector('.note-outline-list');
  const marks = nav.querySelector('.note-outline-marks');
  const count = nav.querySelector('.note-outline-count');
  let entries = [], signature = '', active = -1, frame = 0, refreshPending = false, hovered = false, keyboardNavigation = false;
  let scrollFrame = 0;
  const setOpen = open => {
    nav.classList.toggle('is-open', open);
    trigger.setAttribute('aria-expanded', String(open));
    panel.inert = !open;
  };
  nav.addEventListener('pointerenter', () => { hovered = true; setOpen(true); });
  nav.addEventListener('pointerleave', () => {
    hovered = false;
    if (!keyboardNavigation || !nav.contains(document.activeElement)) setOpen(false);
  });
  nav.addEventListener('pointerdown', () => { keyboardNavigation = false; });
  trigger.addEventListener('click', () => setOpen(true));
  nav.addEventListener('focusin', () => setOpen(true));
  nav.addEventListener('focusout', () => {
    queueMicrotask(() => { if (!hovered && !nav.contains(document.activeElement)) setOpen(false); });
  });
  nav.addEventListener('keydown', event => {
    keyboardNavigation = true;
    const buttons = [...list.children];
    const index = buttons.indexOf(document.activeElement);
    let next;
    if (event.key === 'ArrowDown') next = index < 0 ? 0 : Math.min(index + 1, buttons.length - 1);
    if (event.key === 'ArrowUp') next = index < 0 ? buttons.length - 1 : Math.max(index - 1, 0);
    if (event.key === 'Home') next = 0;
    if (event.key === 'End') next = buttons.length - 1;
    if (next !== undefined && buttons[next]) { event.preventDefault(); buttons[next].focus(); }
  });
  list.addEventListener('click', event => {
    const button = event.target.closest('button[data-index]');
    if (!button) return;
    const index = Number(button.dataset.index);
    if (entries[index]) {
      navigate(entries[index]);
      updateActive(index);
    }
  });
  function updateActive(index) {
    if (active === index) return;
    active = index;
    [...list.children].forEach((button, i) => {
      if (i === index) button.setAttribute('aria-current', 'location');
      else button.removeAttribute('aria-current');
    });
    [...marks.children].forEach(mark => mark.classList.toggle('is-active', index >= Number(mark.dataset.index) && index <= Number(mark.dataset.end)));
    const current = entries[index]?.text;
    trigger.title = current ? `章节目录 · ${current}` : '章节目录';
  }
  function track() {
    if (!entries.length) return;
    let index = 0;
    for (let i = 0; i < entries.length; i++) {
      if (entries[i].top() <= 48) index = i;
    }
    if (atEnd()) index = entries.length - 1;
    updateActive(index);
  }
  function refresh() {
    entries = headings();
    nav.hidden = !entries.length;
    document.body.classList.toggle('has-note-outline', entries.length > 0);
    layout(entries);
    if (!entries.length) setOpen(false);
    const nextSignature = JSON.stringify(entries.map(({ text, level }) => [text, level]));
    if (signature !== nextSignature) {
      signature = nextSignature;
      list.replaceChildren(); marks.replaceChildren(); active = -1;
      count.textContent = `${entries.length} 个章节`;
      const base = Math.min(...entries.map(entry => entry.level));
      const buttons = document.createDocumentFragment(), ticks = document.createDocumentFragment();
      entries.forEach((entry, index) => {
        const button = document.createElement('button');
        button.type = 'button'; button.className = 'note-outline-item';
        button.dataset.index = String(index);
        button.style.setProperty('--outline-depth', String(entry.level - base));
        button.dataset.level = String(entry.level);
        button.textContent = entry.text; button.title = entry.text;
        buttons.append(button);
      });
      // Keep the collapsed rail compact even in long notes, while showing reading progress.
      const step = Math.ceil(entries.length / 12);
      for (let index = 0; index < entries.length; index += step) {
        const mark = document.createElement('span');
        mark.dataset.index = String(index); mark.dataset.end = String(Math.min(index + step - 1, entries.length - 1));
        mark.dataset.level = String(entries[index].level); ticks.append(mark);
      }
      list.append(buttons); marks.append(ticks);
    }
    track();
  }
  function scheduleRefresh() {
    refreshPending = true;
    if (frame) return;
    frame = requestAnimationFrame(() => { frame = 0; if (refreshPending) { refreshPending = false; refresh(); } });
  }
  function scheduleTrack() {
    if (scrollFrame) return;
    scrollFrame = requestAnimationFrame(() => { scrollFrame = 0; track(); });
  }
  document.addEventListener('scroll', scheduleTrack, { capture: true, passive: true });
  window.addEventListener('resize', scheduleTrack, { passive: true });
  return {
    refresh: scheduleRefresh,
    dismiss() {
      if (!nav.classList.contains('is-open')) return false;
      if (nav.contains(document.activeElement)) trigger.focus({ preventScroll: true });
      setOpen(false); return true;
    },
    reset() { setOpen(false); hovered = false; keyboardNavigation = false; active = -1; scheduleRefresh(); }
  };
}
