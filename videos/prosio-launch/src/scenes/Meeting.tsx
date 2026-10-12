import React from 'react';
import {useCurrentFrame} from 'remotion';
import {Frame, SceneHeader, Steps} from '../components';
import {InteractionAction, interactionAt, InteractionCursor} from '../interaction';
import {native} from '../native-ui';
import {T} from '../theme';

export const meetingActions: readonly InteractionAction[] = [
  {id: 'focus-library', frame: 16, x: 697, y: 59, type: 'move'},
  {id: 'play-recording', frame: 47, x: 765, y: 60, target: {x: 726, y: 48, width: 78, height: 24}},
  {id: 'stop-recording', frame: 88, x: 765, y: 60, target: {x: 726, y: 48, width: 78, height: 24}},
  {id: 'copy-transcript', frame: 112, x: 844, y: 60, target: {x: 812, y: 48, width: 68, height: 24}},
];
const buttonStyle: React.CSSProperties = {position: 'absolute', top: 48, height: 24, boxSizing: 'border-box', background: 'linear-gradient(#FFFFFF, #FAFAFA)', border: '1px solid #CECED1', borderRadius: 5, boxShadow: '0 1px 1px #00000008', display: 'flex', alignItems: 'center', justifyContent: 'center', color: native.text, fontSize: 12};

export const Meeting: React.FC = () => {
  const f = useCurrentFrame();
  const state = interactionAt(f, meetingActions, {x: 610, y: 350});
  const playing = state.done('play-recording') && !state.done('stop-recording');
  const copied = state.done('copy-transcript');
  const camera = state.progress('focus-library', 20);
  const scale = 1.12 + camera * .33;
  return <Frame>
    <SceneHeader eyebrow="录音与转写" title="专心参与。" muted="原话留得住。" detail={'带时间戳的本地文字，\n可以回听，也可以复制整理。'} />
    <div style={{position: 'absolute', left: 800, top: 220, width: 1016, height: 650, overflow: 'hidden', borderRadius: 14}}>
      {/* The native-sized window and its pointer always share a camera plane. */}
      <div style={{position: 'absolute', left: -304.5 * camera, top: 0, width: 900, height: 600, scale, transformOrigin: 'top left', fontFamily: native.font, color: native.text}}>
        <div style={{position: 'absolute', inset: 0, border: '1px solid #CACACD', borderRadius: 10, background: '#FFFFFF', overflow: 'hidden', boxShadow: '0 12px 45px #1C263A20'}}>
          <div style={{height: 28, background: '#F5F5F7', borderBottom: '1px solid #DADADD', position: 'relative', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 13, fontWeight: 500, color: '#55555A'}}><div style={{position: 'absolute', left: 12, display: 'flex', gap: 8}}>{['#FF6059', '#FFBD2E', '#28C840'].map(color => <span key={color} style={{width: 11, height: 11, borderRadius: '50%', background: color, border: '0.5px solid #00000015'}} />)}</div>会议转写</div>
          <aside style={{position: 'absolute', top: 28, bottom: 0, left: 0, width: 210, background: '#F0F0F3', borderRight: '1px solid #DCDCE0', padding: '16px 9px', boxSizing: 'border-box'}}><div style={{fontSize: 13, fontWeight: 600, color: '#707075', margin: '0 8px 13px'}}>会议</div><div style={{padding: '9px 8px', background: '#DCE4F0', borderRadius: 6}}><div style={{fontSize: 13, fontWeight: 600}}>2026年10月8日 10:30</div><div style={{fontSize: 11, color: '#747479', marginTop: 4}}>本地稿已就绪</div></div><div style={{padding: '13px 8px'}}><div style={{fontSize: 13, fontWeight: 600}}>2026年10月7日 14:00</div><div style={{fontSize: 11, color: '#747479', marginTop: 4}}>本地稿已就绪</div></div></aside>
          <main style={{position: 'absolute', left: 230, top: 48, width: 650}}>
            <div style={{fontSize: 17, lineHeight: '21px', fontWeight: 700}}>2026年10月8日 10:30</div><div style={{fontSize: 11, color: native.secondary, lineHeight: '14px', marginTop: 3}}>时长：1122 秒 · 3 段文字</div>
            <div style={{display: 'flex', gap: 8, marginTop: 12, alignItems: 'center'}}><div style={{width: 300, height: 24, padding: 2, boxSizing: 'border-box', borderRadius: 5, background: '#EEEEF0', border: '1px solid #DEDEE1', display: 'flex', color: '#929297', fontSize: 11}}><span style={{width: '50%', display: 'grid', placeItems: 'center', borderRadius: 3, background: '#FAFAFB', boxShadow: '0 1px 2px #00000012', color: '#7E7E83'}}>Apple 本地稿</span><span style={{width: '50%', display: 'grid', placeItems: 'center'}}>Soniox 增强稿</span></div><span style={{height: 24, padding: '0 10px', border: '1px solid #CECED1', borderRadius: 5, background: '#FAFAFA', fontSize: 12, display: 'flex', alignItems: 'center'}}>上传到 Soniox</span></div>
            <div style={{height: 1, background: '#DDDDDF', margin: '12px 0'}} />
            <div style={{paddingTop: 4}}>{[
              {time: '00:00:12', source: '麦克风', text: '先用一句话，说清楚用户得到什么。'},
              {time: '00:00:34', source: '系统声音', text: '再展示从想法到成果的完整过程。'},
              {time: '00:01:05', source: '麦克风', text: '最后，给出一个清晰的行动入口。'},
            ].map(line => <div key={line.time} style={{display: 'flex', gap: 12, alignItems: 'flex-start', marginBottom: 12}}><span style={{width: 58, flexShrink: 0, fontSize: 13, lineHeight: '17px', fontVariantNumeric: 'tabular-nums', color: native.secondary}}>{line.time}</span><div style={{flex: 1}}><div style={{fontSize: 11, lineHeight: '14px', color: native.secondary, marginBottom: 2}}>{line.source}</div><div style={{fontSize: 13, lineHeight: '18px'}}>{line.text}</div></div></div>)}</div>
          </main>
          <div style={{...buttonStyle, left: 602, width: 116}}>打开录音文件夹</div>
          <div data-action-target="play-recording stop-recording" style={{...buttonStyle, left: 726, width: 78, background: state.clickPoint && state.x === 765 && state.click > 0 ? '#E6E6E9' : '#FFFFFF'}}>{playing ? '停止播放' : '播放录音'}</div>
          <div data-action-target="copy-transcript" style={{...buttonStyle, left: 812, width: 68, background: copied && state.since('copy-transcript') < 8 ? '#E6E6E9' : '#FFFFFF'}}>复制全文</div>
        </div>
        <InteractionCursor state={state} scale={.48} />
      </div>
    </div>
    <div style={{position: 'absolute', left: 800, top: 900, fontSize: 30, color: T.blue, opacity: state.progress('play-recording', 8)}}>{copied ? '全文已复制，可以继续整理。' : playing ? '回放原始录音，听清上下文。' : '带着时间戳，保留原话。'}</div>
    <Steps items={['本地转写', '回听', '复制整理']} active={copied ? 2 : state.done('play-recording') ? 1 : 0} />
  </Frame>;
};
