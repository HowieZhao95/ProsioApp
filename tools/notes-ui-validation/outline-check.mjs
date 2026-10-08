// Configure globalThis.outlineCheckConfig = { repo, spaceId? }, then import in ego-browser nodejs.
const { default: assert } = await import('node:assert/strict');
const { pathToFileURL } = await import('node:url');
const { resolve } = await import('node:path');
const config = globalThis.outlineCheckConfig;
assert(config?.repo, 'Set outlineCheckConfig.repo to the repository root.');
const task = await taskSpace(config.spaceId ?? '便签章节导航验证');
console.log({ spaceId: task.spaceId });
const page = task.page('p1');
await page.goto(pathToFileURL(resolve(config.repo, 'Apps/macOS/Prosio/Notes/Editor/NotesEditor/index.html')).href);
await page.cdp('Page.bringToFront', {});
await page.waitForFunction(() => window.__ready);
await page.cdp('Emulation.setDeviceMetricsOverride', { width: 420, height: 476, deviceScaleFactor: 1, mobile: false });
// Simulate reduced motion so scroll assertions do not depend on a background tab's animation clock.
await page.evaluate(() => {
  const matchMedia = window.matchMedia.bind(window);
  window.matchMedia = query => query === '(prefers-reduced-motion: reduce)' ? { matches: true } : matchMedia(query);
});
const checks = [];
const check = (name, actual, expected = true) => { assert.deepEqual(actual, expected, name); checks.push(name); console.log(`PASS ${name}`); };
const items = () => page.evaluate(() => [...document.querySelectorAll('.note-outline-item')].map(el => el.textContent));
const openDirectory = async () => {
  // Mode/document switches deliberately collapse the card, even if the pointer stayed over the rail.
  await page.mouse.move(30, 8);
  await page.hover('.note-outline-trigger');
  await page.waitForFunction(() => document.querySelector('.note-outline').classList.contains('is-open'));
};
const load = async (text, source = false) => {
  await page.evaluate(async ({ text, source }) => {
    await window.notes.load({ text, document: 'outline-check', source });
    window.scrollTo(0, 0);
  }, { text, source });
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
};
await load('只有正文，没有章节。');
check('No headings: hide navigation and release its gutter', await page.evaluate(() => document.querySelector('.note-outline').hidden && !document.body.classList.contains('has-note-outline')));

const sample = '# 项目随记\n\n开头保留原文。\n\n## **今天**的重点\n\n### 设计细节\n\n'
  + '段落里的笔记。\n\n'.repeat(24)
  + '```md\n# 代码里的假标题\n```\n\n## 接下来\n\n'
  + '继续记录。\n\n'.repeat(18)
  + '最后一章\n--------\n\n' + '结尾。\n\n'.repeat(14);
await load(sample);
check('ATX/setext headings, formatting, and fenced-code exclusion', await items(), ['项目随记', '今天的重点', '设计细节', '接下来', '最后一章']);
check('Default collapsed and inaccessible panel', await page.evaluate(() => !document.querySelector('.note-outline').classList.contains('is-open') && document.querySelector('.note-outline-panel').inert));
check('Hierarchy is indented', await page.evaluate(() => document.querySelector('.note-outline-item[data-index="2"]').style.getPropertyValue('--outline-depth')), '2');
console.log(await page.snapshot());
await openDirectory();
check('Pointer hover expands', await page.evaluate(() => document.querySelector('.note-outline-trigger').getAttribute('aria-expanded')), 'true');
await page.hover('.note-outline-item[data-index="3"]');
check('Crossing the hover bridge keeps the card open', await page.evaluate(() => document.querySelector('.note-outline').classList.contains('is-open')));
await page.click('.note-outline-item[data-index="3"]');
await page.waitForFunction(() => document.querySelector('.note-outline-item[aria-current]')?.textContent === '接下来');
check('Rich heading is brought into view', await page.evaluate(() => {
  const top = [...document.querySelectorAll('.ProseMirror h2')].find(el => el.textContent === '接下来').getBoundingClientRect().top;
  return top >= 0 && top < 80;
}));
check('Rich heading jump updates reading position', await page.evaluate(() => document.querySelector('.note-outline-item[aria-current]').textContent), '接下来');
check('Navigation preserves original Markdown', await page.evaluate(() => window.notes.snapshot().text), sample);
await page.mouse.move(30, 30);
check('Pointer leaves: card collapses', await page.evaluate(() => document.querySelector('.note-outline-trigger').getAttribute('aria-expanded')), 'false');
await page.focus('.ProseMirror');
await openDirectory();
await page.keyboard.press('Escape');
check('Escape also closes hovered directory while editor has focus', await page.evaluate(() => !document.querySelector('.note-outline').classList.contains('is-open')));
await page.evaluate(() => window.scrollTo(0, document.scrollingElement.scrollHeight));
await page.waitForFunction(() => document.querySelector('.note-outline-item[aria-current]').textContent === '最后一章');
check('Scrolling to the end highlights the final chapter', true);

await page.focus('.note-outline-trigger');
await page.keyboard.press('ArrowDown');
check('Keyboard can enter chapter list', await page.evaluate(() => document.activeElement.dataset.index), '0');
await page.keyboard.press('End');
check('Keyboard End reaches final chapter', await page.evaluate(() => document.activeElement.dataset.index), '4');
await page.keyboard.press('Escape');
check('Escape closes directory without hiding the note', await page.evaluate(() => !document.querySelector('.note-outline').classList.contains('is-open') && document.activeElement.classList.contains('note-outline-trigger')));

await page.evaluate(async () => { await window.notes.setSource(true); document.querySelector('#source').scrollTop = 0; });
await page.waitForFunction(() => !document.querySelector('#source').hidden);
await openDirectory();
await page.click('.note-outline-item[data-index="3"]');
check('Source jump selects the correct Markdown offset', await page.evaluate(() => document.querySelector('#source').selectionStart), sample.indexOf('## 接下来'));
check('Source heading position is aligned', await page.evaluate(() => document.querySelector('#source').scrollTop > 300));
check('Source navigation preserves original Markdown', await page.evaluate(() => window.notes.snapshot().text), sample);
await page.fill('#source', '# 新标题\n\n## 下一节');
await page.waitForFunction(() => document.querySelector('.note-outline-item')?.textContent === '新标题');
check('Source edits rebuild headings immediately', await items(), ['新标题', '下一节']);
await page.evaluate(async () => window.notes.setSource(false));
await page.waitForFunction(() => !document.querySelector('#editor').hidden);
check('Source/rich mode switch refreshes outline', await items(), ['新标题', '下一节']);
await page.fill('.ProseMirror', '删掉标题，保留正文。');
await page.keyboard.press('Meta+Alt+0');
await page.waitForFunction(() => document.querySelector('.note-outline').hidden);
check('Removing rich headings hides directory', true);

await load('# 重复标题\n\n'+ '正文。\n\n'.repeat(20) + '# 重复标题\n\n' + '尾部。\n\n'.repeat(14));
await openDirectory();
await page.click('.note-outline-item[data-index="1"]');
await page.waitForFunction(() => Math.abs(document.querySelectorAll('.ProseMirror h1')[1].getBoundingClientRect().top - 24) < 2);
check('Duplicate titles navigate to distinct positions', true);

await load('# <img src=x onerror=alert(1)>\n\n![附件](image.png)\n\n## 保留的章节', true);
check('Unsupported syntax still has safe source navigation', await page.evaluate(() => !document.querySelector('#source').hidden && !document.querySelector('.note-outline-list img')));
await load(Array.from({ length: 40 }, (_, i) => `## 章节 ${i + 1}\n\n记录。\n\n`).join(''));
check('Long document has a compact rail', await page.evaluate(() => document.querySelectorAll('.note-outline-marks>span').length <= 12));
await openDirectory();
check('Long directory scrolls independently', await page.evaluate(() => { const list = document.querySelector('.note-outline-list'); return list.scrollHeight > list.clientHeight; }));

for (const dark of [false, true]) {
  await page.evaluate(dark => window.notes.configure({ dark, fontSize: 20, readonly: true }), dark);
  await page.cdp('Emulation.setDeviceMetricsOverride', { width: 320, height: 206, deviceScaleFactor: 1, mobile: false });
  await openDirectory();
  check(`${dark ? 'Dark' : 'Light'} card fits minimum window`, await page.evaluate(() => {
    const rect = document.querySelector('.note-outline-panel').getBoundingClientRect();
    return rect.left >= 0 && rect.right <= innerWidth && rect.top >= 0 && rect.bottom <= innerHeight;
  }));
  check(`${dark ? 'Dark' : 'Light'} navigation works in readonly mode`, await page.evaluate(() => !document.querySelector('.note-outline-panel').inert && document.querySelector('#source').readOnly));
}
await load('日期切换后的空白笔记。');
check('Switching documents clears old chapters', await items(), []);
console.log(JSON.stringify({ passed: checks.length, checks }, null, 2));
await task.finish({ keep: [] });
