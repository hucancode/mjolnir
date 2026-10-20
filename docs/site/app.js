// Renders the API reference and examples pages from data/api.js and data/examples.js (built by docs/gen).
const el = (tag, props = {}, ...kids) => {
  const e = Object.assign(document.createElement(tag), props);
  e.append(...kids);
  return e;
};

function renderApi(root) {
  const pkgs = window.API;
  const nav = el('nav');
  const search = el('input', { type: 'search', placeholder: 'Filter symbols…' });
  const content = el('article');
  root.append(el('div', {}, el('search', {}, search, nav), content));

  for (const p of pkgs) nav.append(el('a', { href: '#' + p.path, textContent: p.path.replace(/^mjolnir\/?/, '') || 'mjolnir' }));

  function show() {
    const path = decodeURIComponent(location.hash.slice(1)) || pkgs[0].path;
    const pkg = pkgs.find((p) => p.path === path) ?? pkgs[0];
    document.title = pkg.path + ' - Mjolnir';
    for (const a of nav.querySelectorAll('a')) a.toggleAttribute('aria-current', a.getAttribute('href') === '#' + pkg.path);
    content.replaceChildren(el('h1', { textContent: pkg.path }));
    if (pkg.doc) content.append(el('p', { textContent: pkg.doc }));
    for (const s of pkg.sections) {
      content.append(el('h2', { textContent: s.name }));
      const dl = el('dl');
      for (const sym of s.syms) {
        const d = el('div', {}, el('dt', {}, el('code', { textContent: sym.sig })));
        if (sym.doc) d.append(el('dd', { textContent: sym.doc }));
        dl.append(d);
      }
      content.append(dl);
    }
    filter();
  }

  function filter() {
    const q = search.value.trim().toLowerCase();
    for (const d of content.querySelectorAll('dl > div')) d.hidden = !!q && !d.textContent.toLowerCase().includes(q);
  }

  search.addEventListener('input', filter);
  addEventListener('hashchange', show);
  show();
}

function renderExamples(root) {
  const list = window.EXAMPLES;
  const hasGpu = !!navigator.gpu;
  const nav = el('nav');
  const thumbBtn = el('button', { type: 'button', className: 'thumb-toggle' });
  const stage = el('div', { className: 'stage' });
  const loader = el('div', { className: 'loader', hidden: true }, el('span', { className: 'spinner' }), el('span', { textContent: 'Loading…' }));
  const modeBtn = el('button', { type: 'button' });
  const desc = el('p', { className: 'desc' });
  const codeBtn = el('button', { type: 'button', textContent: 'Code' });
  const logBtn = el('button', { type: 'button', textContent: 'Log' });
  const panel = el('div', { className: 'help-panel', hidden: true }, desc, el('p', { className: 'toolbar' }, modeBtn, codeBtn, logBtn));
  const helpBtn = el('button', { type: 'button', className: 'overlay help', textContent: '?', title: 'About this example' });
  const frame = el('div', { className: 'frame' }, stage, loader, panel, helpBtn);
  const code = el('code');
  const pre = el('pre', {}, code);
  const closeBtn = el('button', { type: 'button', textContent: 'Close' });
  const dialogTitle = el('strong');
  const dialog = el('dialog', { className: 'code-dialog' }, el('header', {}, dialogTitle, closeBtn), pre);
  const logPre = el('pre');
  const logCloseBtn = el('button', { type: 'button', textContent: 'Close' });
  const logDialog = el('dialog', { className: 'code-dialog' }, el('header', {}, el('strong', { textContent: 'Log' }), logCloseBtn), logPre);
  const view = el('section', {}, frame, dialog, logDialog);
  root.append(el('div', { className: 'examples' }, el('search', {}, thumbBtn, nav), view));

  // picker: section headers, optional video-frame thumbnails
  let thumbs = localStorage.getItem('examples-thumbs') !== '0';
  const setThumbs = () => {
    nav.classList.toggle('thumbs', thumbs);
    thumbBtn.textContent = thumbs ? 'Hide thumbnails' : 'Show thumbnails';
    localStorage.setItem('examples-thumbs', thumbs ? '1' : '0');
    for (const v of nav.querySelectorAll('video')) {
      if (thumbs && !v.src) v.src = v.dataset.src;
    }
  };
  thumbBtn.addEventListener('click', () => { thumbs = !thumbs; setThumbs(); });
  let category;
  for (const e of list) {
    if (e.category !== category) {
      category = e.category;
      nav.append(el('h2', { textContent: category }));
    }
    const link = el('a', { href: '#' + e.name }, el('span', { textContent: e.name }));
    if (e.video) {
      // a still frame of the clip; the source is attached lazily, only while thumbnails are shown
      const v = el('video', { muted: true, preload: 'metadata', playsInline: true, tabIndex: -1 });
      v.muted = true;
      v.dataset.src = `videos/${e.name}.mp4#t=1`;
      link.prepend(v);
    } else {
      link.prepend(el('div', { className: 'no-thumb' }));
    }
    nav.append(link);
  }
  setThumbs();

  helpBtn.addEventListener('click', () => { panel.hidden = !panel.hidden; });
  codeBtn.addEventListener('click', () => { panel.hidden = true; dialog.showModal(); });
  logBtn.addEventListener('click', () => { panel.hidden = true; });

  let current, live; // live: whether the current example runs as a WebGPU build rather than a video

  function mount() {
    const e = current;
    modeBtn.hidden = !(e.wasm && e.video && hasGpu);
    logBtn.hidden = !live;
    loader.hidden = false;
    const ready = () => { if (current === e) loader.hidden = true; };
    modeBtn.textContent = live ? 'Video' : 'Run live';
    if (live) {
      const f = el('iframe', { src: `live/index.html?example=${encodeURIComponent(e.name)}`, title: e.name, allow: 'fullscreen; gamepad' });
      f.addEventListener('load', ready);
      stage.replaceChildren(f);
    } else if (e.video) {
      const v = el('video', { src: `videos/${e.name}.mp4`, autoplay: true, muted: true, loop: true, playsInline: true, controls: true });
      v.addEventListener('loadeddata', ready);
      v.muted = true; // the muted attribute must be set for autoplay to be allowed
      stage.replaceChildren(v);
    } else {
      stage.replaceChildren(el('p', { textContent: 'No live build or video for this example yet.' }));
      ready();
    }
  }

  function show() {
    const name = decodeURIComponent(location.hash.slice(1));
    const e = list.find((x) => x.name === name) ?? list[0];
    if (e === current) return;
    current = e;
    live = hasGpu && e.wasm; // fall back to the video without WebGPU or a wasm build
    document.title = e.name + ' - Examples - Mjolnir';
    for (const a of nav.querySelectorAll('a')) a.toggleAttribute('aria-current', a.getAttribute('href') === '#' + e.name);
    nav.querySelector('a[aria-current]')?.scrollIntoView({ block: 'nearest' });
    panel.hidden = true;
    desc.textContent = e.desc;
    code.textContent = e.source;
    dialogTitle.textContent = e.name + ' source';
    pre.scrollTop = 0;
    mount();
  }

  modeBtn.addEventListener('click', () => { live = !live; mount(); });
  codeBtn.addEventListener('click', () => dialog.showModal());
  closeBtn.addEventListener('click', () => dialog.close());
  dialog.addEventListener('click', (ev) => { if (ev.target === dialog) dialog.close(); }); // backdrop click
  // logs live in the (same-origin) iframe's #console; mirror them while the dialog is open
  let logObserver;
  logBtn.addEventListener('click', () => {
    const src = stage.querySelector('iframe')?.contentDocument?.getElementById('console');
    const sync = () => { logPre.textContent = src ? src.textContent : 'No logs available.'; logPre.scrollTop = logPre.scrollHeight; };
    sync();
    if (src) {
      logObserver = new MutationObserver(sync);
      logObserver.observe(src, { childList: true, characterData: true, subtree: true });
    }
    logDialog.showModal();
  });
  logDialog.addEventListener('close', () => logObserver?.disconnect());
  logCloseBtn.addEventListener('click', () => logDialog.close());
  logDialog.addEventListener('click', (ev) => { if (ev.target === logDialog) logDialog.close(); });
  addEventListener('hashchange', show);
  show();
}

const page = document.body.dataset.page;
const root = document.querySelector('main');
if (page === 'api') renderApi(root);
else if (page === 'examples') renderExamples(root);
