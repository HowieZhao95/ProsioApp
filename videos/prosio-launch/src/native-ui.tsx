import React from 'react';
import {staticFile} from 'remotion';

/** Native SF Symbols exported with AppKit, matching symbols referenced by Prosio. */
export const NativeIcon: React.FC<{name: string; size?: number; color?: string; style?: React.CSSProperties}> = ({name, size = 16, color = 'currentColor', style}) => <span aria-hidden="true" style={{display:'inline-block', width:size, height:size, flexShrink:0, verticalAlign:'middle', backgroundColor:color, maskImage:`url("${staticFile(`ui-symbols/${name}.png`)}")`, maskSize:'contain', maskPosition:'center', maskRepeat:'no-repeat', WebkitMaskImage:`url("${staticFile(`ui-symbols/${name}.png`)}")`, WebkitMaskSize:'contain', WebkitMaskPosition:'center', WebkitMaskRepeat:'no-repeat', ...style}} />;

export const native = {
  font: '-apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif',
  text: '#1C1C1E', secondary: '#7B7B80', border: '#DADADA', accent: '#007AFF',
  control: '#FFFFFF', surface: '#F5F5F5', separator: '#DDDDDD',
};
