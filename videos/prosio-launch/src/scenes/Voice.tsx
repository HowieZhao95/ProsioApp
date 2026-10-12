import React from 'react';
import {useCurrentFrame, useVideoConfig} from 'remotion';
import {Frame, Keycap, SceneHeader, Steps} from '../components';
import {InteractionAction, InteractionCursor, interactionAt} from '../interaction';
import {native} from '../native-ui';
import {T} from '../theme';
import {NativeVoiceHUD} from './voice-capture-native';

const bodyRect = {x: 24, y: 110, width: 512, height: 154};
const original = ['新版方案已经整理好了。', '明天下午四点，我们一起评审，', '确认下一步的安排。'];
const originalText = original.join('');
const shortText = ['新版方案已就绪，', '明天下午四点评审。'];
const initial = {x: 488, y: 211};

/** Native-point coordinates inside the same 1.8× plane as the controls and pointer. */
export const voiceActions: readonly InteractionAction[] = [
  {id: 'focus-editor', frame: 20, x: 28, y: 121, type: 'click', target: bodyRect},
  {id: 'fn-start', frame: 35, x: 28, y: 121, type: 'key'},
  {id: 'fn-stop', frame: 93, x: 28, y: 121, type: 'key'},
  {id: 'select-start', frame: 158, x: 24, y: 121, type: 'down', travel: 10, target: bodyRect},
  {id: 'select-end', frame: 181, x: 213, y: 173, type: 'up', target: bodyRect},
  {id: 'fn-rewrite-start', frame: 193, x: 213, y: 173, type: 'key'},
  {id: 'fn-rewrite-stop', frame: 222, x: 213, y: 173, type: 'key'},
  {id: 'rest-pointer', frame: 265, x: 509, y: 273, type: 'move', travel: 14},
];

export const Voice: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const f = frame * 30 / fps;
  const state = interactionAt(f, voiceActions, initial);
  const edit = state.done('fn-rewrite-start');
  const stop = edit ? 'fn-rewrite-stop' : 'fn-stop';
  const start = edit ? 'fn-rewrite-start' : 'fn-start';
  const started = state.done(start);
  const stopped = state.done(stop);
  const latency = edit ? 12 : 14;
  const finished = stopped && state.since(stop) >= latency;
  const listening = started && !stopped;
  const processing = stopped && !finished;
  const hasText = state.done('fn-stop') && state.since('fn-stop') >= 14;
  const shortened = state.done('fn-rewrite-stop') && state.since('fn-rewrite-stop') >= 12;
  const previewText = edit ? '简短一点。'.slice(0, Math.floor(state.progress(start, 20) * 5)) : originalText.slice(0, Math.floor(state.progress(start, 51) * originalText.length));
  const hudVisible = started && (!finished || state.since(stop) < latency + 17);
  const keyActive = ['fn-start','fn-stop','fn-rewrite-start','fn-rewrite-stop'].some(id => state.done(id) && state.since(id) < 8);
  const selectEnd = voiceActions.find(action => action.id === 'select-end')!;
  const selecting = state.done('select-start') && !shortened;
  const selectedPointer = interactionAt(Math.min(f, selectEnd.frame), voiceActions, initial);
  const selectionLine = Math.max(0, Math.min(2, Math.floor((selectedPointer.y - bodyRect.y) / 25.2)));
  const status = !started ? '练习区' : listening ? previewText || '正在聆听…' : processing ? '正在处理…' : '已写入';

  return <Frame>
    <SceneHeader eyebrow="01 / 语音输入" title="说出来。" muted="就写好了。" detail={'输入、翻译、改写，\n都从一句话开始。'} />
    <div style={{position: 'absolute', left: 800, top: 185, color: T.muted, fontSize: 22}}>Prosio · 语音练习区（局部放大）</div>
    <div style={{position: 'absolute', left: 800, top: 230, width: 560, height: 414, scale: 1.8, transformOrigin: 'top left', fontFamily: native.font, color: native.text}}>
      <div style={{height: 31, borderBottom: '1px solid #00000016', display: 'flex', gap: 24, fontSize: 14, alignItems: 'flex-start'}}>
        {['输入', '翻译', '改写'].map((tab,i) => <div key={tab} style={{height: 31, boxSizing: 'border-box', borderBottom: i === 0 ? '2px solid #4A5C85' : '2px solid transparent', fontWeight: i === 0 ? 600 : 400, color: i === 0 ? native.text : native.secondary}}>{tab}</div>)}
      </div>
      <div style={{position: 'absolute', top: 53, left: 0, width: 560, height: 252, borderRadius: 14, border: '1px solid #00000016', boxSizing: 'border-box', background: 'white', overflow: 'hidden'}}>
        <div style={{position: 'absolute', top: 21, left: 24, right: 24, display: 'flex', alignItems: 'center', height: 17, fontSize: 14, color: native.secondary}}>
          <span>试着说：明天下午四点见。</span>
          {listening && <div style={{marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 3, height: 22}}>{[0,1,2,3,4,5,6,7,8,9,10,11].map(i => <span key={i} style={{width: 3, height: 3 + 19 * Math.abs(Math.sin(state.since(start)*.2-i*.32)), background: '#4A5C85', borderRadius: 9}} />)}</div>}
        </div>
        <div style={{position: 'absolute', top: 212, left: 0, right: 0, height: 40, background: '#00000006', display: 'flex', alignItems: 'center', padding: '0 24px', gap: 8, fontSize: 12, color: native.secondary}}><span style={{overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap'}}>{status}</span>{hasText && !listening && !processing && <span style={{marginLeft: 'auto', flexShrink: 0}}>清空</span>}</div>
      </div>
      <div data-action-target="focus-editor select-start select-end" style={{position: 'absolute', ...{left: bodyRect.x, top: bodyRect.y, width: bodyRect.width, height: bodyRect.height}, fontSize: 21, lineHeight: '25.2px', whiteSpace: 'pre', color: native.text}}>
        {!hasText && <div style={{color: '#C4C4C6'}}>文字会出现在这里{state.done('focus-editor') && <span style={{position: 'absolute', left: 0, top: 1, width: 1, height: 25, background: '#1C1C1E'}} />}</div>}
        {hasText && (shortened ? shortText : original).map((line, i) => <div key={line} style={{position: 'relative', width: 'fit-content'}}>
          {selecting && <span style={{position: 'absolute', left: 0, top: 0, height: 25.2, width: i < selectionLine ? '100%' : i === selectionLine ? Math.min(line.length*21, Math.max(0, selectedPointer.x-bodyRect.x)) : 0, background: '#B4D5FE'}} />}
          <span style={{position: 'relative'}}>{line}</span>
        </div>)}
      </div>
      <div style={{position: 'absolute', left: 0, right: 0, top: 327, height: 40, display: 'flex', alignItems: 'center', gap: 16, fontSize: 14}}>
        <div style={{height: 40, padding: '0 20px', display: 'flex', alignItems: 'center', background: processing ? '#4A5C8559' : '#4A5C85', color: 'white', borderRadius: 8, fontWeight: 500}}>{listening ? '结束说话' : processing ? '处理中…' : '试着说一句'}</div>
        <span style={{color: native.secondary}}>设置</span><span style={{marginLeft: 'auto', color: native.secondary, fontSize: 12}}>Fn 开始 · 再按结束</span>
      </div>
      {hudVisible && <NativeVoiceHUD listening={listening} finished={finished} edit={edit} text={previewText} phaseFrame={state.since(start)} />}
      <InteractionCursor state={state} scale={.62} />
    </div>
    <div style={{position: 'absolute', left: 104, top: 775, display: 'flex', alignItems: 'center', gap: 22}}><Keycap active={keyActive}>Fn</Keycap><div style={{fontSize: 25, lineHeight: 1.55, color: T.muted}}>{shortened ? '改写完成' : edit ? stopped ? '再按一次，完成改写' : '说「简短一点」' : state.done('select-start') ? '拖动选中文字' : stopped ? '再按一次，结束说话' : '按一次，开始说话'}</div></div>
    <Steps items={['开口', '写入', '改写']} active={shortened ? 2 : hasText ? 1 : 0} />
  </Frame>;
};
