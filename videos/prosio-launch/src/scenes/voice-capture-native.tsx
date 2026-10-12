import React from 'react';
import {NativeIcon, native} from '../native-ui';

// Native point sizes and colors from HUDCapsuleView / CaptureEditingToolbar.
export const captureNative = {ink: '#5E5952', surface: '#FCFAF5', blue: '#007AFF', red: '#E3333D', orange: '#F28F24'};

export const NativeVoiceHUD: React.FC<{listening: boolean; finished: boolean; edit: boolean; text: string; phaseFrame: number}> = ({listening, finished, edit, text, phaseFrame}) => <div style={{position: 'absolute', left: '50%', top: 375, translate: '-50% 0', display: 'flex', alignItems: 'center', gap: 8, boxSizing: 'border-box', height: 36, padding: '0 14px', maxWidth: 450, borderRadius: 99, background: '#F0F0F0F2', border: '0.5px solid #00000014', boxShadow: '0 2px 6px #0000002E', fontFamily: native.font}}>
  {finished ? <NativeIcon name="checkmark" size={13} color="#202020" /> : <>
    {edit && <span style={{fontSize: 11, lineHeight: '15px', padding: '3px 6px', borderRadius: 99, background: '#0000001A'}}>✏️</span>}
    {listening && <div style={{display: 'flex', alignItems: 'center', gap: 2.5, width: 37.5, height: 16, flexShrink: 0}}>{[0, 1, 2, 3, 4, 5, 6, 7].map(i => <span key={i} style={{width: 2.5, height: 3 + 13 * Math.abs(Math.sin(phaseFrame * .24 - i * .43)), borderRadius: 9, background: '#1C1C1EF2'}} />)}</div>}
    {text && <div style={{fontSize: 13, lineHeight: '18px', maxWidth: 360, color: listening ? '#7B7B80' : '#56565B', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', direction: 'rtl', textAlign: 'left'}}><span dir="ltr">{text}</span></div>}
  </>}
</div>;

const toolPositions = [18, 48, 78, 108, 138, 168, 198];
const toolSymbols = ['cursorarrow', 'rectangle', 'oval', 'line.diagonal', 'pencil.tip', 'T', 'square.grid.3x3.fill'];

export const NativeCaptureToolbar: React.FC<{lineActive: boolean; translating: boolean; canUndo: boolean; translationFrame: number}> = ({lineActive, translating, canUndo, translationFrame}) => <div style={{position: 'absolute', left: 136, top: 255, width: 404, height: 42, borderRadius: 99, background: captureNative.surface, boxSizing: 'border-box', boxShadow: 'inset 0 0 0 1px #5E59521F, 0 5px 15px #00000024', color: captureNative.ink}}>
  <div style={{position: 'absolute', left: 5, top: 5, width: 244, height: 32, overflow: 'hidden'}}>
    {toolSymbols.map((symbol, i) => <div key={symbol} data-action-target={i === 3 ? 'line-tool' : undefined} style={{position: 'absolute', left: toolPositions[i]-19, top: 0, width: 28, height: 30, display: 'flex', alignItems: 'center', justifyContent: 'center', borderRadius: '50%', background: (lineActive ? i === 3 : i === 0) ? '#5E59521C' : 'transparent', outline: (lineActive ? i === 3 : i === 0) ? '1.5px solid #5E5952CC' : 'none'}}>{symbol === 'T' ? <span style={{fontFamily: 'Georgia, serif', fontSize: 15, fontWeight: 500}}>T</span> : <NativeIcon name={symbol} size={13} />}</div>)}
    <div style={{position: 'absolute', left: 213, top: 5, height: 20, width: 1, background: '#5E595229'}} />
    <div style={{position: 'absolute', left: 221, top: 0, height: 30, width: 28, display: 'flex', alignItems: 'center', justifyContent: 'center', opacity: canUndo ? 1 : .35}}><NativeIcon name="arrow.uturn.backward" size={13} /></div>
  </div>
  {[
    {x: 266, name: 'translate', action: 'translate'},
    {x: 296, name: 'xmark'},
    {x: 326, name: 'pin'},
    {x: 356, name: 'square.and.arrow.down'},
    {x: 386, name: 'doc.on.doc', action: 'copy-exit'},
  ].map(item => <div key={item.name} data-action-target={item.action} style={{position: 'absolute', left: item.x-14, top: 6, width: 28, height: 30, display: 'flex', alignItems: 'center', justifyContent: 'center', borderRadius: '50%', color: item.action === 'copy-exit' ? 'white' : captureNative.ink, background: item.action === 'copy-exit' ? captureNative.ink : 'transparent', opacity: translating && item.x > 296 ? .4 : 1}}>
    {item.action === 'translate' && translating ? <svg width="13" height="13" viewBox="0 0 16 16" style={{rotate: `${translationFrame * 12}deg`}}><circle cx="8" cy="8" r="5.8" fill="none" stroke="#5E59524D" strokeWidth="1.6" /><path d="M8 2.2A5.8 5.8 0 0 1 13.8 8" fill="none" stroke={captureNative.ink} strokeWidth="1.6" strokeLinecap="round" /></svg> : <NativeIcon name={item.name} size={13} />}
  </div>)}
</div>;

const colors = ['#E3333D', '#F28F24', '#FFE23D', '#1AAD8F', '#498DE8', '#9166CC', '#FFFFFF', '#0A0A0F', '#E3333D'];

export const NativeLinePalette: React.FC<{orange: boolean; selected: boolean}> = ({orange, selected}) => <div style={{position: 'absolute', left: 163, top: 304, width: 350, height: 118, boxSizing: 'border-box', background: captureNative.surface, borderRadius: 13, boxShadow: 'inset 0 0 0 1px #5E59521F, 0 5px 15px #00000024', color: captureNative.ink, fontFamily: native.font}}>
  <div style={{position: 'absolute', left: 37, top: 23, fontSize: 11, opacity: .7}}>{selected ? '已选中' : '新图形'}</div>
  {colors.map((color, i) => <div key={i} data-action-target={i === 1 ? 'orange-color' : undefined} style={{position: 'absolute', left: 79+i*27, top: 22, width: 18, height: 18, borderRadius: '50%', background: i === 8 && orange ? captureNative.orange : color, boxSizing: 'border-box', border: '0.5px solid #5E595240', outline: (orange ? i === 1 : i === 0) ? `1.5px solid ${captureNative.ink}` : undefined, outlineOffset: 3}} />)}
  <div style={{position: 'absolute', left: 12, top: 52, height: 24, display: 'flex', alignItems: 'center', fontSize: 12, gap: 8, right: 12}}><span>端点</span><div style={{display: 'flex', flex: 1, height: 22, borderRadius: 5, background: '#0000000B', padding: 1, boxSizing: 'border-box'}}>{['无', '箭头', '刻度'].map(label => <span key={label} data-action-target={label === '箭头' ? 'arrow-endpoint' : undefined} style={{flex: 1, display: 'flex', justifyContent: 'center', alignItems: 'center', borderRadius: 4, background: label === '箭头' ? '#FFFFFF' : 'transparent', boxShadow: label === '箭头' ? '0 1px 3px #00000020' : 'none'}}>{label}</span>)}</div></div>
  <div style={{position: 'absolute', left: 12, right: 12, top: 88, display: 'flex', alignItems: 'center', gap: 6, height: 15, fontSize: 11}}>
    <span>粗细</span><div style={{height: 4, width: 86, background: '#0000001A', borderRadius: 9, position: 'relative'}}><i style={{position: 'absolute', left: 11, top: -6, height: 16, width: 16, background: 'white', borderRadius: 9, boxShadow: '0 1px 4px #0003'}} /></div><span style={{width: 20, textAlign: 'center'}}>3</span>
    <span style={{marginLeft: 4}}>不透明度</span><div style={{height: 4, flex: 1, background: '#00000024', borderRadius: 9, position: 'relative'}}><i style={{position: 'absolute', right: -1, top: -6, height: 16, width: 16, background: 'white', borderRadius: 9, boxShadow: '0 1px 4px #0003'}} /></div><span style={{width: 34, textAlign: 'right'}}>100%</span>
  </div>
</div>;

export const NativeSelection: React.FC<{x: number; y: number; width: number; height: number; handles: boolean}> = ({x,y,width,height,handles}) => <div style={{position: 'absolute', left: x, top: y, width, height, boxSizing: 'border-box', border: '2px solid #007AFFF2', pointerEvents: 'none'}}>
  {handles && [[0,0],[.5,0],[1,0],[0,.5],[1,.5],[0,1],[.5,1],[1,1]].map(([px,py], i) => <span key={i} style={{position: 'absolute', left: px*width-3.5-2, top: py*height-3.5-2, width: 7, height: 7, boxSizing: 'border-box', borderRadius: 2, background: '#007AFF', border: '1px solid #0000004D'}} />)}
</div>;
