// Build-time data from `odin doc` (API) and examples/ (examples). Server-only; prerendered into static pages.
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

const docs = process.cwd();
const root = resolve(docs, '..');
const sh = (cmd, args) => execFileSync(cmd, args, { cwd: root, encoding: 'utf8', maxBuffer: 1 << 26 });

const SECTIONS = ['constants', 'variables', 'procedures', 'types', 'procedure groups'];
const isTestFile = (f) => /^(test|bench)_/.test(f);
const declNames = (path) =>
  new Set([...readFileSync(join(root, path), 'utf8').matchAll(/^([A-Za-z_]\w*)\s*(?:::|:=)/gm)].map((m) => m[1]));

function parse(text) {
  const out = { doc: [], sections: {} };
  let cur = null;
  let sym = null;
  for (const line of text.split('\n').slice(1)) {
    const t = /^\t*/.exec(line)[0].length;
    const body = line.trim();
    if (!body) continue;
    if (t === 1) {
      if (body === 'fullpath:' || body === 'files:') { cur = null; sym = null; continue; }
      if (SECTIONS.includes(body)) { cur = out.sections[body] = []; sym = null; continue; }
      if (!cur) out.doc.push(body);
    } else if (cur && t === 2) {
      const m = /^(.*?)\s*\/\* \S+:([^!*]+)!\d+ \*\/$/.exec(body);
      sym = { sig: m ? m[1] : body, file: m ? m[2] : '', doc: [] };
      cur.push(sym);
    } else if (cur && sym && t > 2) sym.doc.push(body);
  }
  return out;
}

let apiCache;
export function getApi() {
  return (apiCache ??= loadApi());
}

function loadApi() {
  const dirs = [...new Set(sh('git', ['ls-files', 'mjolnir']).split('\n').filter((f) => f.endsWith('.odin')).map(dirname))].sort();
  return dirs.map((path) => {
    const files = readdirSync(join(root, path)).filter((f) => f.endsWith('.odin'));
    const tests = new Set(files.filter(isTestFile).flatMap((f) => [...declNames(join(path, f))]));
    for (const f of files.filter((f) => !isTestFile(f))) for (const n of declNames(join(path, f))) tests.delete(n);
    const p = parse(sh('odin', ['doc', path]));
    const sections = Object.entries(p.sections)
      .map(([name, syms]) => [
        name,
        syms
          .filter((s) => !isTestFile(s.file) && !tests.has(/^[\w$]+/.exec(s.sig)?.[0]))
          .map((s) => ({ sig: s.sig, doc: s.doc.join('\n') })),
      ])
      .filter(([, syms]) => syms.length);
    return { path, doc: p.doc.join('\n'), sections };
  });
}

export function getExamples() {
  return readdirSync(join(root, 'examples'), { withFileTypes: true })
    .filter((d) => d.isDirectory() && existsSync(join(root, 'examples', d.name, 'main.odin')))
    .map((d) => {
      const source = readFileSync(join(root, 'examples', d.name, 'main.odin'), 'utf8');
      const desc = source.split('\n').filter((l, i, a) => l.startsWith('//') && a.slice(0, i).every((x) => x.startsWith('//')))
        .map((l) => l.replace(/^\/\/\s?/, '')).join(' ');
      return { name: d.name, desc, source, video: existsSync(join(docs, 'static/videos', d.name + '.mp4')) };
    })
    .sort((a, b) => (b.name === 'cube') - (a.name === 'cube') || a.name.localeCompare(b.name));
}
