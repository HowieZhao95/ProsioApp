import React from 'react';
import {Easing, interpolate, Series, staticFile, useVideoConfig} from 'remotion';
import {Audio} from '@remotion/media';
import {Opening} from './scenes/Opening';
import {Voice} from './scenes/Voice';
import {Capture} from './scenes/Capture';
import {Notes} from './scenes/Notes';
import {Recording} from './scenes/Recording';
import {Meeting} from './scenes/Meeting';
import {End, endFadeFrames} from './scenes/End';
import {clamp} from './theme';

export const Film: React.FC = () => {
  const {fps, durationInFrames} = useVideoConfig();
  const fadeStart = durationInFrames - 4 * fps + endFadeFrames.start;
  const fadeEnd = durationInFrames - 4 * fps + endFadeFrames.end;
  return <>
    <Audio src={staticFile('audio/soundtrack.wav')} name="Original score and interaction sounds" premountFor={fps} volume={(frame) => interpolate(frame, [fadeStart, fadeEnd], [1, 0], {...clamp, easing: Easing.inOut(Easing.sin)})} />
    <Series>
      <Series.Sequence name="01 · 让工作顺着想法走" durationInFrames={7 * fps} premountFor={fps}><Opening /></Series.Sequence>
      <Series.Sequence name="02 · 开口就能写" durationInFrames={10 * fps} premountFor={fps}><Voice /></Series.Sequence>
      <Series.Sequence name="03 · 截图原位翻译" durationInFrames={10 * fps} premountFor={fps}><Capture /></Series.Sequence>
      <Series.Sequence name="04 · 每日便签" durationInFrames={7 * fps} premountFor={fps}><Notes /></Series.Sequence>
      <Series.Sequence name="05 · 录屏与演示" durationInFrames={6 * fps} premountFor={fps}><Recording /></Series.Sequence>
      <Series.Sequence name="06 · 会议转写" durationInFrames={5 * fps} premountFor={fps}><Meeting /></Series.Sequence>
      <Series.Sequence name="07 · 品牌收束" durationInFrames={4 * fps} premountFor={fps}><End /></Series.Sequence>
    </Series>
  </>;
};
