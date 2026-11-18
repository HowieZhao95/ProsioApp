import React from 'react';
import {AbsoluteFill, Easing, interpolate, useCurrentFrame} from 'remotion';
import {Brand} from '../components';
import {T, clamp, progress} from '../theme';

/** Local frames of the end card. Picture and score fade across this span. */
export const endFadeFrames = {start: 48, end: 116};

const Couplet: React.FC<{text: string; color: string}> = ({text, color}) => (
  <div style={{position: 'relative', fontSize: 126, fontWeight: 550, letterSpacing: '-.055em', lineHeight: 1.05, color, paddingLeft: '.055em'}}>
    {text.replace('。', '')}
    <span style={{position: 'absolute', left: '100%', top: 0, letterSpacing: 0}}>。</span>
  </div>
);

export const End: React.FC = () => {
  const f = useCurrentFrame();
  const enter = progress(f, 0, 24);
  const dim = interpolate(f, [endFadeFrames.start, endFadeFrames.end], [0, 1], {...clamp, easing: Easing.inOut(Easing.sin)});
  return <AbsoluteFill style={{background: T.ink, color: T.white, fontFamily: T.font}}>
    <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', opacity: enter}}>
      <div style={{display: 'flex', flexDirection: 'column', alignItems: 'center', scale: 1 + Math.min(f, endFadeFrames.start) * 0.000045}}>
        <Brand size={70} color={T.white} style={{marginBottom: 64}} />
        <Couplet text="少一点打断。" color={T.white} />
        <div style={{height: 22}} />
        <Couplet text="多一点完成。" color="#999995" />
        <div style={{marginTop: 62, background: T.paper, color: T.ink, fontSize: 29, borderRadius: 60, padding: '23px 48px', opacity: progress(f, 20, 22)}}>开源免费</div>
      </div>
      <div style={{position: 'absolute', left: 0, right: 0, bottom: 53, textAlign: 'center', fontSize: 24, color: '#979792', letterSpacing: '.07em', paddingLeft: '.07em'}}>让工作顺着想法走</div>
    </AbsoluteFill>
    <AbsoluteFill style={{background: '#000', opacity: dim}} />
  </AbsoluteFill>;
};
