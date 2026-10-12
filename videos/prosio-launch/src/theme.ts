import {Easing, interpolate} from 'remotion';

export const T = {
  paper: '#F7F7F5', white: '#FFFFFF', ink: '#191919', muted: '#93938E',
  blue: '#526991', paleBlue: '#EDF1F7', border: '#E5E5E1', green: '#55856D',
  font: '"PingFang SC", "Hiragino Sans GB", -apple-system, BlinkMacSystemFont, sans-serif',
};
export const clamp = {extrapolateLeft: 'clamp' as const, extrapolateRight: 'clamp' as const};
export const ease = Easing.bezier(0.22, 1, 0.36, 1);
export const progress = (frame: number, start: number, duration = 24) =>
  interpolate(frame, [start, start + duration], [0, 1], {...clamp, easing: ease});
export const fade = (frame: number, start: number, end: number) =>
  interpolate(frame, [start, start + 12, end - 12, end], [0, 1, 1, 0], clamp);
