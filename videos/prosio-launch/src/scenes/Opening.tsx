import React from 'react';
import {interpolate, useCurrentFrame, useVideoConfig} from 'remotion';
import {Brand, Frame, Keycap} from '../components';
import {T, clamp, progress} from '../theme';

export const Opening: React.FC = () => {
  const f = useCurrentFrame(); const {fps} = useVideoConfig();
  const gather = progress(f, 3.25 * fps, .8 * fps);
  const reveal = progress(f, 4.0 * fps, .9 * fps);
  const fragments = [
    {label: '写一句', x: 248, y: 640, rot: -7, key: 'Fn'},
    {label: '说明白', x: 670, y: 734, rot: 3, key: '⌥'},
    {label: '记下来', x: 1096, y: 636, rot: -3, key: '✓'},
    {label: '录一段', x: 1490, y: 728, rot: 7, key: '●'},
  ];
  return <Frame demo={false}>
    <div style={{position: 'absolute', top: 246, width: '100%', textAlign: 'center', opacity: 1 - gather, translate: `0 ${-gather * 40}px`}}>
      <div style={{fontSize: 137, fontWeight: 600, letterSpacing: '-.065em', lineHeight: 1.3}}>想法很多。</div>
      <div style={{fontSize: 137, fontWeight: 600, letterSpacing: '-.065em', color: T.muted, lineHeight: 1.3}}>操作，少一点。</div>
    </div>
    {fragments.map((item, i) => {
      const appear = progress(f, i * 9, 26);
      const drift = Math.sin(f / 38 + i) * 5;
      return <div key={item.label} style={{position: 'absolute', left: item.x + (875 - item.x) * gather, top: item.y + (520 - item.y) * gather + drift * (1-gather), display: 'flex', alignItems: 'center', gap: 18, background: T.white, border: `1px solid ${T.border}`, borderRadius: 22, padding: '20px 28px', boxShadow: '0 14px 40px #19191908', rotate: `${item.rot * (1-gather)}deg`, opacity: appear * (1 - gather), scale: 1 - gather * .45, translate: `0 ${(1-appear)*35}px`}}>
        <Keycap style={{height: 50, minWidth: 50, padding: '0 10px', fontSize: 23, borderRadius: 10}}>{item.key}</Keycap><span style={{fontSize: 31}}>{item.label}</span>
      </div>;
    })}
    <div style={{position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', opacity: reveal, translate: `0 ${(1-reveal)*28}px`, scale: interpolate(f, [120, 210], [.99, 1.015], clamp)}}>
      <Brand size={62} style={{marginBottom: 58}} />
      <div style={{fontSize: 142, fontWeight: 600, letterSpacing: '-.065em', lineHeight: 1.3}}>让工作，<span style={{color: T.muted}}>顺着想法走。</span></div>
      <div style={{fontSize: 34, color: '#777771', marginTop: 38, letterSpacing: '.07em'}}>开源免费 · 为 Mac 日常而来</div>
    </div>
  </Frame>;
};
