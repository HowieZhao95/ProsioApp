import React from 'react';
import {useCurrentFrame} from 'remotion';
import {Frame, SceneHeader, Steps} from '../components';
import {InteractionAction, interactionAt, InteractionCursor} from '../interaction';
import {native, NativeIcon} from '../native-ui';
import {T} from '../theme';

// Points share the native 420 × 510 plane with the pointer.
export const notesActions: readonly InteractionAction[] = [
  {id: 'check-task', frame: 36, x: 32, y: 163, target: {x: 22, y: 149, width: 20, height: 28}},
  {id: 'pin-note', frame: 69, x: 399, y: 17, target: {x: 388, y: 5, width: 22, height: 24}},
  {id: 'open-calendar', frame: 101, x: 91, y: 17, target: {x: 38, y: 5, width: 115, height: 24}},
  {id: 'select-yesterday', frame: 142, x: 159, y: 179, target: {x: 138, y: 159, width: 41, height: 40}},
  {id: 'close-calendar', frame: 176, x: 401, y: 395, target: {x: 382, y: 360, width: 28, height: 90}},
];

// Actual default checkbox paths from Milkdown Crepe's list-item component.
const TaskBox: React.FC<{checked: boolean}> = ({checked}) => <svg width="18" height="18" viewBox="0 0 24 24" fill="#62676B"><path d={checked ? 'M19 3H5C3.9 3 3 3.9 3 5V19C3 20.1 3.9 21 5 21H19C20.1 21 21 20.1 21 19V5C21 3.9 20.1 3 19 3ZM10.71 16.29C10.32 16.68 9.69 16.68 9.3 16.29L5.71 12.7C5.32 12.31 5.32 11.68 5.71 11.29C6.1 10.9 6.73 10.9 7.12 11.29L10 14.17L16.88 7.29C17.27 6.9 17.9 6.9 18.29 7.29C18.68 7.68 18.68 8.31 18.29 8.7L10.71 16.29Z' : 'M18 19H6C5.45 19 5 18.55 5 18V6C5 5.45 5.45 5 6 5H18C18.55 5 19 5.45 19 6V18C19 18.55 18.55 19 18 19ZM19 3H5C3.9 3 3 3.9 3 5V19C3 20.1 3.9 21 5 21H19C20.1 21 21 20.1 21 19V5C21 3.9 20.1 3 19 3Z'} /></svg>;

export const Notes: React.FC = () => {
  const f = useCurrentFrame();
  const state = interactionAt(f, notesActions, {x: 310, y: 280});
  const checked = state.done('check-task');
  const pinned = state.done('pin-note');
  const previous = state.done('select-yesterday');
  const calendar = state.done('open-calendar') && !state.done('close-calendar');
  const tasks = previous ? ['整理访谈记录', '完成首页文案'] : ['确定发布主题', '录制产品演示'];
  return <Frame>
    <SceneHeader eyebrow="每日便签" title="想法记下来。" muted="事情做下去。" detail={'Markdown、待办与每日记录，\n都留在手边。'} />
    <div style={{position: 'absolute', left: 1035, top: 185, width: 420, height: 510, scale: 1.45, transformOrigin: 'top left', fontFamily: native.font, color: '#242629'}}>
      <div style={{position: 'absolute', inset: 0, borderRadius: 14, background: 'white', border: '1px solid #D9DBDC', boxShadow: '0 16px 48px #1F28351B', overflow: 'hidden'}}>
        {/* DailyNotesView hides system traffic lights and has no date sidebar. */}
        <div style={{height: 34, background: '#FAFAFA', borderBottom: '1px solid #DEDEDE', position: 'relative', boxSizing: 'border-box'}}>
          <span style={{position: 'absolute', left: 10, top: 5, width: 22, height: 24, display: 'grid', placeItems: 'center'}}><NativeIcon name="xmark" size={11} color="#5C5C60" /></span>
          <div data-action-target="open-calendar" style={{position: 'absolute', left: 38, top: 5, width: 115, height: 24, display: 'flex', alignItems: 'center', gap: 5, fontSize: 12, fontWeight: 600}}>{previous ? '10月7日' : '10月8日 · 今天'}<NativeIcon name="chevron.down" size={8} color={native.secondary} /></div>
          <div style={{position: 'absolute', right: previous ? 56 : 34, top: 8, padding: '3px 7px', borderRadius: 20, background: '#1C1C1E0B', fontSize: 10, fontWeight: 500, lineHeight: '12px', color: '#79797C'}}>今天 {checked ? 1 : 2} 项待办</div>
          {previous && <span style={{position: 'absolute', right: 34, top: 5, width: 22, height: 24, display: 'grid', placeItems: 'center'}}><NativeIcon name="arrow.uturn.backward" size={11} /></span>}
          <span data-action-target="pin-note" style={{position: 'absolute', left: 388, top: 5, width: 22, height: 24, display: 'grid', placeItems: 'center'}}><NativeIcon name={pinned ? 'pin.fill' : 'pin'} size={12} color={pinned ? native.accent : native.secondary} /></span>
        </div>
        <div style={{padding: '20px 22px 28px', fontSize: 18, lineHeight: 1.7}}>
          <h1 style={{fontSize: 22, lineHeight: 1.45, letterSpacing: '-.025em', fontWeight: 600, margin: '0 0 12px'}}>{previous ? '昨天的进展' : '发布准备'}</h1>
          <p style={{margin: '0 0 12px', lineHeight: 1.7}}>{previous ? '写下的每一步，都找得到。' : '把想法，变成下一步。'}</p>
          <div style={{marginTop: 8, marginBottom: 16}}>{tasks.map((task, i) => <div key={task} style={{height: 28, marginBottom: 8, display: 'flex', gap: 10, alignItems: 'flex-start'}}><span data-action-target={!previous && i === 0 ? 'check-task' : undefined} style={{width: 20, height: 28, flexShrink: 0, display: 'grid', placeItems: 'center'}}><TaskBox checked={previous || (checked && i === 0)} /></span><span style={{lineHeight: '28px'}}>{task}</span></div>)}</div>
          <h2 style={{fontSize: 17, lineHeight: 1.5, fontWeight: 600, margin: '22px 0 10px'}}>接下来</h2>
          <p style={{margin: '0 0 12px'}}>{previous ? '准备真实场景，把用法讲清楚。' : '让每个好想法，都有下一步。'}</p>
          <blockquote style={{margin: '18px 0', paddingLeft: 12, borderLeft: '2px solid #C9CED2', color: '#62676B'}}>先记下来，再接着做。</blockquote>
        </div>
        <div style={{position: 'absolute', right: 8, top: 82, width: 28, padding: '10px 5px 12px', display: 'flex', flexDirection: 'column', alignItems: 'end', gap: 13, boxSizing: 'border-box'}}><div style={{display: 'flex', flexDirection: 'column', gap: 3, opacity: .6}}>{[14, 9, 14].map((width, i) => <i key={i} style={{width, height: 1.5, background: '#62676B'}} />)}</div><div style={{display: 'flex', flexDirection: 'column', alignItems: 'end', gap: 7}}><i style={{width: 16, height: 2, background: '#3174BC'}} /><i style={{width: 11, height: 2, background: '#62676B', opacity: .24}} /></div></div>
        <div data-action-target="close-calendar" style={{position: 'absolute', left: 382, top: 360, width: 28, height: 90}} />
      </div>
      {calendar && <div style={{position: 'absolute', left: 30, top: 39, width: 348, padding: 18, boxSizing: 'border-box', border: '1px solid #D9D9DC', borderRadius: 12, background: '#FAFAFC', boxShadow: '0 10px 34px #1524392E', zIndex: 25, opacity: state.progress('open-calendar', 5)}}>
        <div style={{position: 'absolute', top: -6, left: 48, width: 12, height: 12, rotate: '45deg', background: '#FAFAFC', borderLeft: '1px solid #D9D9DC', borderTop: '1px solid #D9D9DC'}} />
        <div style={{height: 24, display: 'flex', alignItems: 'center', marginBottom: 12, fontSize: 15, fontWeight: 600}}><span style={{flex: 1}}>2026年10月</span><NativeIcon name="chevron.left" size={11} style={{marginRight: 25}} /><NativeIcon name="chevron.right" size={11} color="#C0C0C4" style={{marginRight: 6}} /></div>
        <div style={{display: 'grid', gridTemplateColumns: 'repeat(7, 1fr)', gap: 4}}>
          {['一', '二', '三', '四', '五', '六', '日'].map(day => <span key={day} style={{height: 18, textAlign: 'center', fontSize: 10, fontWeight: 500, color: '#A4A4A8'}}>{day}</span>)}
          {Array.from({length: 35}, (_, i) => { const day = i - 2; const chosen = day === (previous ? 7 : 8); const hasTasks = day === 7 || day === 8; const completed = day === 7 ? 2 : checked ? 1 : 0; return <div key={i} data-action-target={day === 7 ? 'select-yesterday' : undefined} style={{height: 40, borderRadius: 8, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 4, background: chosen ? '#007AFF24' : 'transparent', color: chosen || day === 8 ? native.accent : day > 8 ? '#B5B5B9' : native.text, border: day === 8 && !chosen ? '1px solid #007AFF66' : '1px solid transparent', boxSizing: 'border-box'}}>{day > 0 && day <= 31 && <><span style={{fontSize: 13, fontWeight: chosen ? 600 : 400, lineHeight: '15px'}}>{day}</span>{hasTasks ? <span style={{fontSize: 9, lineHeight: '10px', opacity: chosen ? .9 : .55}}>✓{completed} · ○{2 - completed}</span> : <span style={{height: 4, width: 4}} />}</>}</div>; })}
        </div>
        <div style={{borderTop: '1px solid #DDDDDF', marginTop: 12, paddingTop: 12, display: 'flex', alignItems: 'center', justifyContent: 'space-between', height: 19, fontSize: 10, color: native.secondary, boxSizing: 'content-box'}}><span>✓ 完成   ○ 待办</span><span style={{fontSize: 12, color: native.accent}}>回到今天</span></div>
        <div style={{marginTop: 12}}><div style={{display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', marginBottom: 12}}><b style={{fontSize: 13}}>{previous ? '10月7日' : '10月8日'}的任务</b><span style={{fontSize: 11, color: native.secondary}}>已完成 {previous ? 2 : 1} · 未完成 {previous ? 0 : 1}</span></div>{tasks.map((task, i) => { const complete = previous || i === 0; return <div key={task} style={{height: 34, display: 'flex', gap: 10, alignItems: 'center', fontSize: 13, color: complete ? native.secondary : native.text}}><NativeIcon name={complete ? 'checkmark.circle.fill' : 'circle'} size={13} color={complete ? native.secondary : native.accent} style={{width: 16}} /><span style={{textDecoration: complete ? 'line-through' : 'none'}}>{task}</span></div>; })}</div>
      </div>}
      <InteractionCursor state={state} scale={.48} />
    </div>
    <div style={{position: 'absolute', left: 104, top: 770, color: T.blue, fontSize: 28, opacity: state.progress('check-task', 10)}}>{previous ? '按日期，回看昨天的进展。' : pinned ? '置顶在手边，想法随手记。' : '勾选待办，今天还有几件事一眼可见。'}</div>
    <Steps items={['记录', '完成', '回看']} active={previous ? 2 : checked ? 1 : 0} />
  </Frame>;
};
