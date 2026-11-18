import {bundle} from '@remotion/bundler';
import {openBrowser, selectComposition, renderStill} from '@remotion/renderer';
import {mkdir, writeFile} from 'node:fs/promises';
import path from 'node:path';

const id = process.argv[2] || 'ProsioLaunch';
const frames = (process.argv[3] || '0,60,165,260,430,590,740,890,990,1100,1170,1270,1355,1415,1455').split(',').map(Number);
const out = path.resolve(process.env.STILL_OUTPUT || 'out/stills');
await mkdir(out, {recursive:true});
const serveUrl = await bundle({entryPoint:path.resolve('src/index.ts'), webpackOverride:config=>config});
const browser = await openBrowser('chrome', {browserExecutable:process.env.REMOTION_BROWSER_EXECUTABLE || undefined});
try {
  const composition = await selectComposition({serveUrl, id, puppeteerInstance:browser});
  for (const frame of frames) {
    if(frame < 0 || frame >= composition.durationInFrames) throw new Error(`Frame ${frame} is outside ${id}`);
    await renderStill({serveUrl, composition, frame, output:path.join(out,`${id}-${String(frame).padStart(4,'0')}.png`), puppeteerInstance:browser, scale:.75, imageFormat:'png'});
    console.log(`Rendered ${id} frame ${frame}`);
  }
  await writeFile(path.join(out,'manifest.json'),JSON.stringify({id,frames,fps:composition.fps,durationInFrames:composition.durationInFrames,width:composition.width,height:composition.height},null,2));
} finally {await browser.close({silent:true});}
