import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {T, progress} from './theme';
import {NativeIcon} from './native-ui';

export const Brand: React.FC<{size?: number; color?: string; style?: React.CSSProperties}> = ({size = 34, color = T.ink, style}) => (
  <div style={{display: 'flex', alignItems: 'center', gap: size * .28, color, fontWeight: 650, letterSpacing: '-.045em', fontSize: size, lineHeight: 1, ...style}}>
    <NativeIcon name="waveform" size={size * 1.1} color={color} /><span>Prosio</span>
  </div>
);

export const Frame: React.FC<{children: React.ReactNode; dark?: boolean; demo?: boolean}> = ({children, dark = false, demo = true}) => (
  <AbsoluteFill style={{background: dark ? T.ink : T.paper, color: dark ? T.white : T.ink, fontFamily: T.font, overflow: 'hidden'}}>
    <Brand color={dark ? T.white : T.ink} style={{position: 'absolute', left: 104, top: 70, zIndex: 20}} />
    <div style={{position: 'absolute', right: 104, top: 73, fontSize: 23, letterSpacing: '.12em', color: dark ? '#A9A9A4' : T.muted}}>让工作顺着想法走</div>
    {children}
    {demo && <div style={{position: 'absolute', right: 104, bottom: 48, fontSize: 23, color: dark ? '#999994' : '#A4A49F'}}>界面演示 · 过程节选</div>}
  </AbsoluteFill>
);

export const SceneHeader: React.FC<{eyebrow: string; title: string; muted?: string; detail?: string}> = ({eyebrow, title, muted, detail}) => {
  const f = useCurrentFrame(); const p = progress(f, 0, 28);
  return <div style={{position: 'absolute', left: 104, top: 244, width: 660, opacity: p, translate: `0 ${(1-p)*30}px`}}>
    <div style={{fontSize: 24, color: T.blue, letterSpacing: '.14em', marginBottom: 34}}>{eyebrow}</div>
    <div style={{fontSize: 106, fontWeight: 600, letterSpacing: '-.055em', lineHeight: 1.22, whiteSpace: 'pre-line'}}>{title}<span style={{display: 'block', color: T.muted}}>{muted}</span></div>
    {detail && <div style={{fontSize: 32, lineHeight: 1.7, color: '#757570', marginTop: 34, whiteSpace: 'pre-line', maxWidth: 610}}>{detail}</div>}
  </div>;
};

export const MacWindow: React.FC<{title?: string; children: React.ReactNode; style?: React.CSSProperties}> = ({title = 'Prosio', children, style}) => (
  <div style={{borderRadius: 24, background: T.white, border: `1px solid ${T.border}`, boxShadow: '0 28px 80px rgba(30,30,25,.085), 0 3px 12px rgba(30,30,25,.035)', overflow: 'hidden', ...style}}>
    <div style={{height: 58, display: 'flex', alignItems: 'center', justifyContent: 'center', background: '#FBFBFA', borderBottom: `1px solid ${T.border}`, position: 'relative', color: '#767671', fontSize: 21}}>
      <div style={{position: 'absolute', left: 24, display: 'flex', gap: 10}}>{['#ECA5A0', '#E7CF91', '#A8C9A2'].map(c => <div key={c} style={{width: 12, height: 12, borderRadius: 99, background: c}} />)}</div>{title}
    </div>{children}
  </div>
);

export const Keycap: React.FC<{children: React.ReactNode; active?: boolean; style?: React.CSSProperties}> = ({children, active = false, style}) => <span style={{display: 'inline-flex', justifyContent: 'center', alignItems: 'center', minWidth: 76, height: 70, padding: '0 22px', border: `1px solid ${active ? T.blue : '#D9D9D4'}`, borderBottomWidth: active ? 2 : 5, borderRadius: 16, fontSize: 31, background: active ? T.blue : T.white, color: active ? T.white : T.ink, boxShadow: active ? '0 0 0 8px #52699110' : '0 5px 12px #19191907', ...style}}>{children}</span>;

export const Cursor: React.FC<{x: number; y: number; click?: number; scale?: number}> = ({x, y, click = 0, scale = 1}) => <div style={{position: 'absolute', left: x, top: y, pointerEvents: 'none', zIndex: 60, scale, transformOrigin: 'top left'}}>
  {click > 0 && <div style={{position: 'absolute', width: 70, height: 70, left: -25, top: -23, border: `2px solid ${T.blue}`, borderRadius: '50%', scale: 1 + click*.6, opacity: 1-click}} />}
  <svg width="39" height="47" viewBox="0 0 39 47" style={{filter: 'drop-shadow(0 3px 3px #0003)'}}><path d="M4 3L5 35L14 27L21 42L28 38L20 24L33 22Z" fill={T.ink} stroke="white" strokeWidth="2.5" strokeLinejoin="round" /></svg>
</div>;

export const Steps: React.FC<{items: string[]; active: number; style?: React.CSSProperties}> = ({items, active, style}) => <div style={{position: 'absolute', left: 104, bottom: 117, display: 'flex', gap: 20, alignItems: 'center', ...style}}>{items.map((item, i) => <React.Fragment key={item}><div style={{display: 'flex', alignItems: 'center', gap: 12, opacity: i > active ? .32 : 1}}><span style={{width: 30, height: 30, display: 'inline-flex', alignItems: 'center', justifyContent: 'center', borderRadius: '50%', background: i <= active ? T.ink : 'transparent', border: `1px solid ${T.ink}`, color: i <= active ? 'white' : T.ink, fontSize: 17}}>{i+1}</span><span style={{fontSize: 26, color: T.ink}}>{item}</span></div>{i < items.length - 1 && <span style={{color: '#B9B9B3', fontSize: 24}}>›</span>}</React.Fragment>)}</div>;
