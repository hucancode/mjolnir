---
title: Examples
---

<style>
#examples {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(320px, 1fr));
  gap: 1rem;
  margin: 1.5rem 0;
}
#examples figure {
  margin: 0;
  border: 1px solid var(--border);
  background: var(--code-bg);
}
#examples video, #examples .missing {
  display: block;
  width: 100%;
  aspect-ratio: 16 / 9;
  background: #000;
  object-fit: cover;
}
#examples .missing {
  display: flex;
  align-items: center;
  justify-content: center;
  color: var(--muted);
  font: 0.85rem monospace;
}
#examples figcaption {
  padding: 0.5rem 0.75rem;
  font: 0.9rem monospace;
  border-top: 1px solid var(--border);
}
#examples figcaption span {
  display: block;
  margin-top: 0.25rem;
  font: 0.85rem sans-serif;
  color: var(--muted);
  line-height: 1.3;
}
#examples details {
  border-top: 1px solid var(--border);
  font: 0.85rem sans-serif;
}
#examples summary {
  padding: 0.4rem 0.75rem;
  cursor: pointer;
  color: var(--muted);
}
#examples details ul {
  margin: 0;
  padding: 0.4rem 0.75rem 0.6rem 1.75rem;
  line-height: 1.4;
}
#examples details li { margin: 0.15rem 0; }
#examples details pre {
  margin: 0;
  max-height: 24rem;
  overflow: auto;
  border-top: 1px solid var(--border);
  font-size: 0.78rem;
  line-height: 1.4;
}
#examples details pre code {
  white-space: pre;
  padding: 0.5rem 0.75rem;
  display: block;
}
</style>

<div id="examples"></div>

<script>
const SRC_BASE = 'https://raw.githubusercontent.com/hucancode/mjolnir/master/examples/';

fetch('examples.json').then(r => r.json()).then(items => {
  const root = document.getElementById('examples');
  for (const e of items) {
    const fig = document.createElement('figure');
    fig.dataset.example = e.name;

    const v = document.createElement('video');
    v.src = `videos/${e.name}.mp4`;
    v.autoplay = v.muted = v.loop = v.playsInline = true;
    v.preload = 'metadata';
    v.addEventListener('error', () => {
      const ph = document.createElement('div');
      ph.className = 'missing';
      ph.textContent = 'video not yet recorded';
      v.replaceWith(ph);
    });
    fig.appendChild(v);

    const cap = document.createElement('figcaption');
    cap.append(e.name, Object.assign(document.createElement('span'), { textContent: e.desc }));
    fig.appendChild(cap);
    if (e.notes && e.notes.length > 0) {
        const notes = document.createElement('details');
        notes.innerHTML = `<summary>Notes</summary><ul>${e.notes.map(n => `<li>${n}</li>`).join('')}</ul>`;
        fig.appendChild(notes);
    }

    const code = document.createElement('details');
    code.innerHTML = `<summary>Show code</summary><pre><code class="language-odin">Loading…</code></pre>`;
    code.addEventListener('toggle', async () => {
      if (!code.open || code.dataset.loaded) return;
      const c = code.querySelector('code');
      try {
        const r = await fetch(`${SRC_BASE}${e.name}/main.odin`);
        c.textContent = r.ok ? await r.text() : `failed to load: ${r.status}`;
      } catch (err) { c.textContent = `failed to load: ${err.message}`; }
      code.dataset.loaded = '1';
    });
    fig.appendChild(code);

    root.appendChild(fig);
  }
});
</script>
