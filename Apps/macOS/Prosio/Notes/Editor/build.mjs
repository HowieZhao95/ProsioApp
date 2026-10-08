import {build} from 'esbuild';
import {mkdir,writeFile,readFile,readdir} from 'node:fs/promises';
import path from 'node:path';
await mkdir('NotesEditor',{recursive:true});
const result = await build({metafile:true,entryPoints:['editor.js'],bundle:true,minify:true,outfile:'NotesEditor/editor.js',format:'iife',platform:'browser',target:['safari18'],legalComments:'external',logLevel:'info'});
await writeFile('NotesEditor/index.html',`<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src data: blob:; connect-src 'none'; font-src 'none';"><link rel="stylesheet" href="editor.css"><title>每日便签编辑器</title></head><body><main id="editor"></main><textarea id="source" hidden aria-label="Markdown 源码" spellcheck="false"></textarea><script src="editor.js"></script></body></html>`);

const packages = new Map();
for (const input of Object.keys(result.metafile.inputs)) {
  if (!input.includes('node_modules/')) continue;
  let dir = path.dirname(path.resolve(input));
  while (dir !== path.dirname(dir)) {
    try {
      const info = JSON.parse(await readFile(path.join(dir,'package.json'),'utf8'));
      if (info.name) { packages.set(info.name,{dir,info}); break; }
    } catch {}
    dir = path.dirname(dir);
  }
}
let notices = 'Prosio daily notes editor — bundled dependency licenses\n\n';
for (const [name,{dir,info}] of [...packages.entries()].sort(([a],[b])=>a.localeCompare(b))) {
  const files = (await readdir(dir)).filter(file=>/^(licen[cs]e|copying|notice)(\.|$)/i.test(file));
  notices += `\n=== ${name}@${info.version} (${info.license ?? 'see license'}) ===\n`;
  for (const file of files) notices += `\n${file}\n${await readFile(path.join(dir,file),'utf8')}\n`;
  if (!files.length) throw new Error(`Missing license for bundled package ${name}`);
}
await writeFile('NotesEditor/THIRD_PARTY_LICENSES.txt',notices);
