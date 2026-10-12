import React from 'react';
import {Cursor} from './components';

export type Point = {x: number; y: number};
export type InteractionAction = Point & {
  id: string;
  frame: number;
  type?: 'click' | 'move' | 'down' | 'up' | 'key';
  travel?: number;
  target?: {x: number; y: number; width: number; height: number};
};
export type InteractionState = Point & {
  down: boolean;
  click: number;
  clickPoint: Point | null;
  done: (id: string) => boolean;
  since: (id: string) => number;
  progress: (id: string, duration: number) => number;
};

const bounded = (value: number) => Math.max(0, Math.min(1, value));
const smooth = (value: number) => value * value * (3 - 2 * value);

/** One action table drives pointer positions, presses, drags and UI state.
 * Coordinates refer to the arrow's tip in the same local plane as the controls.
 * Ordinary moves settle before the click; held drags continuously track the tip.
 */
export function interactionAt(frame: number, actions: readonly InteractionAction[], initial: Point = {x: 0, y: 0}): InteractionState {
  let point = initial;
  let previousFrame = 0;
  let down = false;
  let latestClick: InteractionAction | undefined;
  for (const action of actions) {
    if (action.frame > frame) {
      if (action.type !== 'key') {
        const movingFrom = down ? previousFrame : Math.max(previousFrame, action.frame - (action.travel ?? 18));
        const arrivesAt = down || action.type === 'move' ? action.frame : Math.max(movingFrom+1, action.frame-3);
        const raw = bounded((frame - movingFrom) / Math.max(1, arrivesAt - movingFrom));
        const p = down ? raw : smooth(raw);
        point = {x: point.x + (action.x - point.x) * p, y: point.y + (action.y - point.y) * p};
      }
      break;
    }
    if (action.type !== 'key') point = {x: action.x, y: action.y};
    if ((action.type ?? 'click') === 'click' || action.type === 'down') latestClick = action;
    if (action.type === 'down') down = true;
    if (action.type === 'up') down = false;
    previousFrame = action.frame;
  }
  const actionFor = (id: string) => {
    const result = actions.find(action => action.id === id);
    if (!result) throw new Error(`Unknown interaction action: ${id}`);
    return result;
  };
  const age = latestClick ? frame - latestClick.frame : Infinity;
  return {
    ...point,
    down,
    click: age >= 0 && age < 12 ? (age + 1) / 13 : 0,
    clickPoint: latestClick && age < 12 ? {x: latestClick.x, y: latestClick.y} : null,
    done: id => frame >= actionFor(id).frame,
    since: id => frame - actionFor(id).frame,
    progress: (id, duration) => smooth(bounded((frame - actionFor(id).frame) / Math.max(1, duration))),
  };
}

export const InteractionCursor: React.FC<{state: InteractionState; scale?: number; visible?: boolean}> = ({state, scale = 1, visible = true}) => {
  if (!visible) return null;
  const pointerScale = scale * (state.down ? .94 : 1);
  return <>
    <span data-pointer-tip data-pointer-down={state.down} style={{position:'absolute',left:state.x,top:state.y,width:1,height:1,opacity:0,pointerEvents:'none'}} />
    {state.clickPoint && <div style={{position: 'absolute', left: state.clickPoint.x - 18, top: state.clickPoint.y - 18, width: 36, height: 36, border: '1.5px solid #191919', borderRadius: '50%', opacity: (1-state.click)*.34, scale: .6+state.click*.8, pointerEvents: 'none', zIndex: 59}} />}
    <Cursor x={state.x - 4 * pointerScale} y={state.y - 3 * pointerScale} scale={pointerScale} />
  </>;
};
