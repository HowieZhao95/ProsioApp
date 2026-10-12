import {Player, type PlayerRef} from '@remotion/player';
import {useEffect, useRef, useState} from 'react';
import {createRoot} from 'react-dom/client';
import {Film} from './Film';

const FPS = 30;
const requestedFrame = Number(new URLSearchParams(window.location.search).get('frame') ?? 0);
const initialFrame = Number.isFinite(requestedFrame) ? Math.max(0, Math.min(1799, Math.round(requestedFrame))) : 0;
const chapters = [
  {seconds: 0, title: '开场'},
  {seconds: 7, title: '语音输入'},
  {seconds: 17, title: '截图翻译'},
  {seconds: 27, title: '每日便签'},
  {seconds: 34, title: '录屏演示'},
  {seconds: 40, title: '会议记录'},
  {seconds: 45, title: 'Agent 协作'},
  {seconds: 49, title: '价格'},
  {seconds: 56, title: '品牌'},
];

function Preview() {
  const player = useRef<PlayerRef>(null);
  const [frame, setFrame] = useState(initialFrame);

  useEffect(() => {
    const current = player.current;
    if (!current) return;
    const update = ({detail}: {detail: {frame: number}}) => setFrame(detail.frame);
    current.addEventListener('timeupdate', update);
    current.addEventListener('seeked', update);
    return () => {
      current.removeEventListener('timeupdate', update);
      current.removeEventListener('seeked', update);
    };
  }, []);

  const seek = (seconds: number) => {
    const current = player.current;
    if (!current) return;
    const wasPlaying = current.isPlaying();
    current.seekTo(seconds * FPS);
    // Preserve the viewer's choice even if Player's seeking behavior changes.
    if (wasPlaying && !current.isPlaying()) current.play();
    if (!wasPlaying && current.isPlaying()) current.pause();
    setFrame(seconds * FPS);
  };
  const activeChapter = chapters.reduce(
    (active, chapter, index) => (frame >= chapter.seconds * FPS ? index : active),
    0,
  );

  return (
    <main className="preview-shell" data-preview-frame={frame}>
      <header className="preview-header">
        <div>
          <p className="eyebrow">PROSIO</p>
          <h1>Prosio <span aria-hidden="true">·</span> 60秒品牌片</h1>
        </div>
        <a className="studio-link" href="http://localhost:3210/ProsioLaunch" target="_blank" rel="noreferrer">
          打开 Studio <span aria-hidden="true">↗</span>
        </a>
      </header>

      <section className="player-surface" aria-label="品牌片播放器">
        <Player
          ref={player}
          component={Film}
          durationInFrames={1800}
          fps={FPS}
          compositionWidth={1920}
          compositionHeight={1080}
          controls
          showVolumeControls
          allowFullscreen
          clickToPlay
          doubleClickToFullscreen
          spaceKeyToPlayOrPause
          autoPlay={false}
          initiallyMuted={false}
          initialVolume={1}
          initialFrame={initialFrame}
          loop={false}
          moveToBeginningWhenEnded={false}
          initiallyShowControls
          style={{width: '100%', aspectRatio: '16 / 9'}}
          errorFallback={({error}) => (
            <div className="player-error" role="alert">
              <strong>预览暂时无法播放</strong>
              <p>请刷新页面，或在 Studio 中查看。</p>
              <small>{error.message}</small>
            </div>
          )}
        />
      </section>

      <nav className="chapters" aria-label="视频章节">
        {chapters.map((chapter, index) => (
          <button
            key={chapter.seconds}
            type="button"
            onClick={() => seek(chapter.seconds)}
            className={index === activeChapter ? 'chapter is-active' : 'chapter'}
            aria-current={index === activeChapter ? 'true' : undefined}
            aria-label={`跳转至 0:${String(chapter.seconds).padStart(2, '0')} ${chapter.title}`}
          >
            <span className="chapter-time">0:{String(chapter.seconds).padStart(2, '0')}</span>
            <span className="chapter-title">{chapter.title}</span>
          </button>
        ))}
      </nav>

      <footer className="preview-footer">
        <p>Typeless 风格参考 <span>·</span> 原创画面与配乐 <span>·</span> 界面演示</p>
        <span className="format-note">60s / 16:9 / 30fps</span>
      </footer>
    </main>
  );
}

const root = document.getElementById('root');
if (!root) throw new Error('Preview root element is missing');
createRoot(root).render(<Preview />);
