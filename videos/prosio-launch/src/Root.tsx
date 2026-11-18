import {Composition, Folder} from 'remotion';
import {Opening} from './scenes/Opening';
import {End} from './scenes/End';
import {Film} from './Film';
import {Voice} from './scenes/Voice';
import {Capture} from './scenes/Capture';
import {Notes} from './scenes/Notes';
import {Recording} from './scenes/Recording';
import {Meeting} from './scenes/Meeting';

export const RemotionRoot: React.FC = () => {
  return (
    <>
      <Composition id="ProsioLaunch" component={Film} durationInFrames={1470} fps={30} width={1920} height={1080} />
      <Folder name="Scenes">
        <Composition id="Opening" component={Opening} durationInFrames={210} fps={30} width={1920} height={1080} />
        <Composition id="Voice" component={Voice} durationInFrames={300} fps={30} width={1920} height={1080} />
        <Composition id="Capture" component={Capture} durationInFrames={300} fps={30} width={1920} height={1080} />
        <Composition id="Notes" component={Notes} durationInFrames={210} fps={30} width={1920} height={1080} />
        <Composition id="Recording" component={Recording} durationInFrames={180} fps={30} width={1920} height={1080} />
        <Composition id="Meeting" component={Meeting} durationInFrames={150} fps={30} width={1920} height={1080} />
        <Composition id="End" component={End} durationInFrames={120} fps={30} width={1920} height={1080} />
      </Folder>
    </>
  );
};
