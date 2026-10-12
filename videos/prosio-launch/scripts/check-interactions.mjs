import {build} from 'esbuild';
import {mkdir, writeFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import path from 'node:path';
import assert from 'node:assert/strict';

await mkdir('out', {recursive:true});
const entry = `
import {interactionAt} from './src/interaction';
import {voiceActions} from './src/scenes/Voice';
import {captureActions} from './src/scenes/Capture';
import {notesActions} from './src/scenes/Notes';
import {recordingActions} from './src/scenes/Recording';
import {meetingActions} from './src/scenes/Meeting';
import {agentActions} from './src/scenes/Agent';
export {interactionAt};
export const scenes = [
 {id:'Voice',start:210,duration:300,actions:voiceActions},
 {id:'Capture',start:510,duration:300,actions:captureActions},
 {id:'Notes',start:810,duration:210,actions:notesActions},
 {id:'Recording',start:1020,duration:180,actions:recordingActions},
 {id:'Meeting',start:1200,duration:150,actions:meetingActions},
 {id:'Agent',start:1350,duration:120,actions:agentActions}
];`;
const output = path.resolve('out/check-interactions.cjs');
await build({stdin:{contents:entry,resolveDir:process.cwd(),loader:'ts'},outfile:output,bundle:true,packages:'external',platform:'node',format:'cjs',logLevel:'silent'});
const {interactionAt,scenes} = createRequire(import.meta.url)(output);
let checked = 0;
const events = [];
for (const scene of scenes) {
  const ids = new Set();
  let last = -1;
  let held = false;
  for (const action of scene.actions) {
    assert(!ids.has(action.id),`${scene.id}: duplicate action ${action.id}`);
    ids.add(action.id);
    assert(Number.isInteger(action.frame) && action.frame > last,`${scene.id}/${action.id}: frames must increase strictly`);
    assert(action.frame >= 0 && action.frame < scene.duration,`${scene.id}/${action.id}: outside scene`);
    const state = interactionAt(action.frame,scene.actions);
    assert(state.done(action.id),`${scene.id}/${action.id}: event did not fire`);
    assert(!interactionAt(action.frame-1,scene.actions).done(action.id),`${scene.id}/${action.id}: event fired early`);
    assert.equal(state.progress(action.id,12),0,'Result must begin from zero on its triggering frame');
    if (action.type !== 'key') {
      assert.equal(state.x,action.x,`${scene.id}/${action.id}: pointer x misses on action frame`);
      assert.equal(state.y,action.y,`${scene.id}/${action.id}: pointer y misses on action frame`);
      if (action.target) {
        const t=action.target;
        assert(action.x >= t.x && action.x <= t.x+t.width && action.y >= t.y && action.y <= t.y+t.height,`${scene.id}/${action.id}: pointer misses control bounds`);
      }
    }
    if (action.type === 'down') { assert(!held,`${scene.id}: duplicate pointer down`); held=true; }
    if (action.type === 'up') { assert(held,`${scene.id}: pointer up without drag`); held=false; }
    assert.equal(state.down,held,`${scene.id}: drag state differs from input`);
    last=action.frame;
    checked++;
    events.push({scene:scene.id,id:action.id,frame:scene.start+action.frame,localFrame:action.frame,type:action.type??'click',x:action.x,y:action.y,target:action.target??null});
  }
  assert(!held,`${scene.id}: scene ends with held mouse`);
}
// A nontrivial drag must follow the pointer continuously, not snap at release.
const drag=[{id:'press',frame:10,x:20,y:30,type:'down'},{id:'release',frame:30,x:100,y:150,type:'up'}];
assert.deepEqual([interactionAt(20,drag).x,interactionAt(20,drag).y],[60,90]);
const report={revision:'native-ui-and-synchronized-input',fps:30,actionCount:checked,events};
await writeFile('design/interaction-events.json',JSON.stringify(report,null,2)+'\n');
console.log(`Verified ${checked} action boundaries, pointer destinations, control bounds and drag states.`);
