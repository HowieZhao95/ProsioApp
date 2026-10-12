import React from 'react';
import {Series, staticFile, useVideoConfig} from 'remotion';
import {Audio} from '@remotion/media';
import {Opening} from './scenes/Opening';
import {Voice} from './scenes/Voice';
import {Capture} from './scenes/Capture';
import {Notes} from './scenes/Notes';
import {Recording} from './scenes/Recording';
import {Meeting} from './scenes/Meeting';
import {Agent} from './scenes/Agent';
import {Pricing} from './scenes/Pricing';
import {End} from './scenes/End';

export const Film: React.FC = () => {
  const {fps} = useVideoConfig();
  return <>
    <Audio src={staticFile('audio/soundtrack.wav')} name="Original score and interaction sounds" volume={1} premountFor={fps} />
    <Series>
      <Series.Sequence name="01 · 让工作顺着想法走" durationInFrames={7 * fps} premountFor={fps}><Opening /></Series.Sequence>
      <Series.Sequence name="02 · 开口就能写" durationInFrames={10 * fps} premountFor={fps}><Voice /></Series.Sequence>
      <Series.Sequence name="03 · 截图原位翻译" durationInFrames={10 * fps} premountFor={fps}><Capture /></Series.Sequence>
      <Series.Sequence name="04 · 每日便签" durationInFrames={7 * fps} premountFor={fps}><Notes /></Series.Sequence>
      <Series.Sequence name="05 · 录屏与演示" durationInFrames={6 * fps} premountFor={fps}><Recording /></Series.Sequence>
      <Series.Sequence name="06 · 会议转写" durationInFrames={5 * fps} premountFor={fps}><Meeting /></Series.Sequence>
      <Series.Sequence name="07 · Agent 任务" durationInFrames={4 * fps} premountFor={fps}><Agent /></Series.Sequence>
      <Series.Sequence name="08 · 月付方案" durationInFrames={7 * fps} premountFor={fps}><Pricing /></Series.Sequence>
      <Series.Sequence name="09 · 品牌收束" durationInFrames={4 * fps} premountFor={fps}><End /></Series.Sequence>
    </Series>
  </>;
};
