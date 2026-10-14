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
  const content = el('div');
  root.append(el('div', { className: 'api' }, el('div', {}, search, nav), content));

  for (const p of pkgs) nav.append(el('a', { href: '#' + p.path, textContent: p.path.replace(/^mjolnir\/?/, '') || 'mjolnir' }));

  function show() {
    const path = decodeURIComponent(location.hash.slice(1)) || pkgs[0].path;
    const pkg = pkgs.find((p) => p.path === path) ?? pkgs[0];
    document.title = pkg.path + ' - Mjolnir';
    for (const a of nav.children) a.classList.toggle('on', a.getAttribute('href') === '#' + pkg.path);
    content.replaceChildren(el('h1', { textContent: pkg.path }));
    if (pkg.doc) content.append(el('p', { textContent: pkg.doc, style: 'white-space: pre-line' }));
    for (const s of pkg.sections) {
      content.append(el('h2', { textContent: s.name }));
      for (const sym of s.syms) {
        const d = el('div', { className: 'sym' }, el('code', { textContent: sym.sig }));
        if (sym.doc) d.append(el('p', { textContent: sym.doc }));
        content.append(d);
      }
    }
    filter();
  }

  function filter() {
    const q = search.value.trim().toLowerCase();
    for (const d of content.querySelectorAll('.sym')) d.classList.toggle('hidden', !!q && !d.textContent.toLowerCase().includes(q));
  }

  search.addEventListener('input', filter);
  addEventListener('hashchange', show);
  show();
}

function renderExamples(root) {
  const grid = el('div', { className: 'grid' });
  for (const e of window.EXAMPLES) {
    const media = e.video
      ? el('video', { src: `videos/${e.name}.mp4`, autoplay: true, muted: true, loop: true, playsInline: true, preload: 'metadata' })
      : el('div', { className: 'missing', textContent: 'video not yet recorded' });
    media.muted = true; // the muted attribute must be set for autoplay to be allowed
    grid.append(
      el('div', { className: 'card', id: e.name },
        el('figure', {}, media, el('figcaption', {}, el('code', { textContent: e.name }), el('small', { textContent: e.desc }))),
        el('details', {}, el('summary', { textContent: 'Show code' }), el('pre', {}, el('code', { textContent: e.source })))
      )
    );
  }
  root.append(grid);
  if (location.hash) document.getElementById(location.hash.slice(1))?.scrollIntoView();
}

const page = document.body.dataset.page;
const root = document.getElementById('app');
if (page === 'api') renderApi(root);
else if (page === 'examples') renderExamples(root);
