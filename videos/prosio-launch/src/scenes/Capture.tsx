import React from 'react';
import {useCurrentFrame, useVideoConfig} from 'remotion';
import {Frame, Keycap, SceneHeader, Steps} from '../components';
import {InteractionAction, InteractionCursor, interactionAt} from '../interaction';
import {native} from '../native-ui';
import {T} from '../theme';
import {captureNative, NativeCaptureToolbar, NativeLinePalette, NativeSelection} from './voice-capture-native';

const viewport = {x: 0, y: 0, width: 676, height: 450};
const initial = {x: 552, y: 346};
const selectionStart = {x: 25, y: 36};
const selectionEnd = {x: 651, y: 243};
const arrowStart = {x: 530, y: 212};
const arrowEnd = {x: 269, y: 154};

/** One native-point action table drives the complete capture transaction. */
export const captureActions: readonly InteractionAction[] = [
  {id: 'option-open', frame: 24, x: 552, y: 346, type: 'key'},
  {id: 'selection-start', frame: 45, ...selectionStart, type: 'down', travel: 18, target: viewport},
  {id: 'selection-end', frame: 76, ...selectionEnd, type: 'up', target: viewport},
  {id: 'translate-hover', frame: 92, x: 402, y: 276, type: 'move', travel: 12},
  {id: 'translate', frame: 99, x: 402, y: 276, type: 'click', target: {x: 388, y: 261, width: 28, height: 30}},
  {id: 'line-hover', frame: 160, x: 244, y: 275, type: 'move', travel: 12},
  {id: 'line-tool', frame: 173, x: 244, y: 275, type: 'click', target: {x: 230, y: 260, width: 28, height: 30}},
  {id: 'arrow-endpoint', frame: 183, x: 355, y: 368, type: 'click', travel: 8, target: {x: 306.333, y: 358, width: 97.333, height: 20}},
  {id: 'orange-color', frame: 196, x: 278, y: 335, type: 'click', travel: 10, target: {x: 269, y: 326, width: 18, height: 18}},
  {id: 'arrow-start', frame: 212, ...arrowStart, type: 'down', travel: 12, target: viewport},
  {id: 'arrow-end', frame: 234, ...arrowEnd, type: 'up', target: viewport},
  {id: 'copy-hover', frame: 273, x: 522, y: 276, type: 'move', travel: 14},
  {id: 'copy-exit', frame: 280, x: 522, y: 276, type: 'click', target: {x: 508, y: 261, width: 28, height: 30}},
];

export const Capture: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const f = frame * 30 / fps;
  const state = interactionAt(f, captureActions, initial);
  // Output is asynchronous in CaptureEditingSession; keep its clicked control
  // visible during the short write, then close the editor and restore the source.
  const copied = state.done('copy-exit') && state.since('copy-exit') >= 4;
  const captureOpen = state.done('option-open') && !copied;
  const selected = state.done('selection-start');
  const selectionCommitted = state.done('selection-end');
  const translated = state.done('translate') && state.since('translate') >= 21;
  const translating = state.done('translate') && !translated;
  const lineActive = state.done('line-tool');
  const orange = state.done('orange-color');
  const selectionEndFrame = captureActions.find(action => action.id === 'selection-end')!.frame;
  const selectionPointer = interactionAt(Math.min(f, selectionEndFrame), captureActions, initial);
  const crop = {x: selectionStart.x, y: selectionStart.y, width: Math.max(0, selectionPointer.x-selectionStart.x), height: Math.max(0, selectionPointer.y-selectionStart.y)};
  const arrowEndFrame = captureActions.find(action => action.id === 'arrow-end')!.frame;
  const arrowPointer = interactionAt(Math.min(f, arrowEndFrame), captureActions, initial);
  const dx = arrowPointer.x-arrowStart.x;
  const dy = arrowPointer.y-arrowStart.y;
  const angle = Math.atan2(dy,dx);
  const arrowHead = [1,-1].map(side => ({x: arrowPointer.x-12*Math.cos(angle)+side*5*Math.sin(angle), y: arrowPointer.y-12*Math.sin(angle)-side*5*Math.cos(angle)}));
  const hero = state.progress('translate', 16) * (1-state.progress('line-hover', 13));

  return <Frame>
    <div style={{opacity: 1-hero}}><SceneHeader eyebrow="02 / 截图与翻译" title="截下来。" muted="说明白。" detail={'原位翻译，顺手标注。\n重点，放在同一张图里。'} /></div>
    <div style={{position: 'absolute', left: 800-hero*348, top: 221-hero*67, width: 676, height: 450, scale: 1.5*(1+hero*.25), transformOrigin: 'top left', fontFamily: native.font}}>
      <div style={{position: 'absolute', inset: 0, overflow: 'hidden', borderRadius: 2, background: '#F8F8F6', boxShadow: '0 16px 46px #19191916'}}>
        <div style={{position: 'absolute', inset: 0, background: '#1E1E1E'}} />
        <div style={{position: 'absolute', left: 41, top: 58, right: 40, color: '#FFFFFF'}}>
          <div style={{fontSize: 11, letterSpacing: '.09em', color: '#A5A5A5'}}>PROJECT UPDATE</div>
          <div style={{fontSize: 31, fontWeight: 700, lineHeight: '42px', marginTop: 11}}>{translated && !copied ? '上线方案评审' : 'Launch review'}</div>
          <div style={{fontSize: 23, lineHeight: '34px', marginTop: 13}}>{translated && !copied ? '明天下午四点评审。' : 'Review tomorrow at 4 PM.'}</div>
          <div style={{fontSize: 20, lineHeight: '31px', marginTop: 5, color: '#D2D2D2'}}>{translated && !copied ? '下一步，保持清晰。' : 'Keep the next step clear.'}</div>
        </div>
        {captureOpen && <svg width={676} height={450} style={{position: 'absolute', inset: 0, pointerEvents: 'none'}}><path d={selected ? `M0 0H676V450H0Z M${crop.x} ${crop.y}h${crop.width}v${crop.height}h${-crop.width}Z` : 'M0 0H676V450H0Z'} fill="#00000047" fillRule="evenodd" /></svg>}
        {captureOpen && !selected && <div style={{position: 'absolute', left: 16, top: 16, padding: '6px 8px', borderRadius: 8, background: '#000000AD', color: 'white', fontSize: 15, fontWeight: 500}}>单击选中 · 双击复制 · 拖动框选 · Esc 退出</div>}
        {captureOpen && selected && <NativeSelection {...crop} handles={selectionCommitted} />}
        {captureOpen && state.done('arrow-endpoint') && state.done('arrow-start') && <svg width={676} height={450} style={{position: 'absolute', inset: 0, pointerEvents: 'none'}}><path d={`M${arrowStart.x} ${arrowStart.y}L${arrowPointer.x} ${arrowPointer.y}M${arrowHead[0].x} ${arrowHead[0].y}L${arrowPointer.x} ${arrowPointer.y}L${arrowHead[1].x} ${arrowHead[1].y}`} fill="none" stroke={orange ? captureNative.orange : captureNative.red} strokeWidth={3} strokeLinecap="round" strokeLinejoin="round" />{state.done('arrow-end') && [arrowStart, arrowPointer].map((point,i) => <rect key={i} x={point.x-4} y={point.y-4} width={8} height={8} rx={1} fill="white" stroke={captureNative.blue} strokeWidth={1.5} />)}</svg>}
        <div data-action-target="selection-start selection-end arrow-start arrow-end" style={{position: 'absolute', inset: 0, pointerEvents: 'none'}} />
        {captureOpen && selectionCommitted && <NativeCaptureToolbar lineActive={lineActive} translating={translating} canUndo={translated} translationFrame={state.since('translate')} />}
        {captureOpen && lineActive && <NativeLinePalette orange={orange} selected={state.done('arrow-end')} />}
      </div>
      <InteractionCursor state={state} scale={.68} />
    </div>
    <div style={{position: 'absolute', left: 104, top: 775, display: 'flex', alignItems: 'center', gap: 22, opacity: 1-hero}}><Keycap active={state.done('option-open') && state.since('option-open') < 8}>⌥ Option</Keycap><div style={{fontSize: 25, color: T.muted, lineHeight: 1.55}}>{copied ? '已复制，返回原应用' : state.done('arrow-end') ? '标注完成，复制分享' : lineActive ? '线条 → 箭头' : translated ? '译文覆盖原图' : selectionCommitted ? '点击翻译按钮' : '轻按释放，拖动框选'}</div></div>
    <div style={{opacity: 1-hero}}><Steps items={['框选', '翻译', '标注', '复制']} active={copied ? 3 : state.done('arrow-end') ? 2 : translated ? 1 : 0} /></div>
  </Frame>;
};
