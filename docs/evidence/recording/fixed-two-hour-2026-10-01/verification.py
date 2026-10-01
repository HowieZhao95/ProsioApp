from pathlib import Path
import json,hashlib,datetime,statistics,shutil,subprocess,gzip
repo=Path('/Users/guest01/projectCodeMac2/ProsioApp')
run=Path('/var/folders/r4/9y_xrg_d1hv5pf36ld4frjv00000gn/T/prosio-recording-perf-fixed-2h-20261001.eafgcb_e')
media=run/'media-run'
out=repo/'docs/evidence/recording/fixed-two-hour-2026-10-01';out.mkdir(parents=True,exist_ok=True)
inputs={'report':media/'report.json','fullDecode':run/'live-full-decode.json','mediaAudit':Path('/tmp/prosio-recording-fixed-2h-final-media-audit-20261001.json'),'aacMetadata':Path('/tmp/prosio-recording-fixed-2h-final-aac-valid-20261001.json'),'performance':run/'performance.json'}
raw={k:p.read_bytes() for k,p in inputs.items()};data={k:json.loads(v) for k,v in raw.items()}
r,d,m,a,p=(data[k] for k in ['report','fullDecode','mediaAudit','aacMetadata','performance'])
assert r['completed'] and not r['failures'] and not r['warnings'] and r['durationSeconds']==7200
assert p['runnerExitCode']==0 and d['completed'] and d['passed'] and d['failedCount']==0
assert m['inputCompleted'] and not m['snapshotIsPartial'] and m['failedCount']==m['timelineErrorCount']==m['informationalGapCount']==0
assert a['writerReportCompleted'] and not a['snapshotIsPartial'] and a['failedCount']==0
segments={s['relativePath']:s for s in r['segments']};decoded={s['path']:s for s in d['segments']};aac={s['path']:s for s in a['segments']}
assert len(segments)==600 and set(segments)==set(decoded)
assert set(aac)=={s for s in segments if s.endswith('.m4a')}
files={str(f.relative_to(media)) for f in (media/'media').iterdir()}
sidecarPaths={'media/'+s['id']+'.segment.json' for s in r['segments']}
assert files==set(segments)|sidecarPaths
for s in r['segments']:
 assert json.loads((media/('media/'+s['id']+'.segment.json')).read_text())==s
assert not (media/'recording-losses.json').exists()
stats=r['snapshots'][-1]['statistics']
assert all(stats[k]==0 for k in ['droppedAdmissionEvents','droppedCaptureFrames','droppedEncoderSamples'])
assert stats['lossCountsBySourceAndReason']=={} and stats['recentLosses']==[]
assert stats['writtenSamples']==r['videoFramesPerSource']*3-r['fixtureSkippedFrames']+r['audioBuffersPerSource']*2
sources={};audioJoin=[]
for path,s in decoded.items():
 assert s['status']=='passed' and s['exitCode']==0 and not s['stderr']
 f=media/path;fs=f.stat();assert fs.st_size==s['sizeBytes'] and fs.st_mtime_ns==s['mtimeNs']
 t=sources.setdefault(s['sourceID'],{'segments':0,'videoFrames':0,'rawPCMFrames':0,'validAudioFrames':0,'trailingPaddingFrames':0});t['segments']+=1;t['videoFrames']+=s.get('videoFrames',0);t['rawPCMFrames']+=s.get('audioSampleFrames',0)
 if path in aac:
  row=aac[path];tag=row['iTunSMPB'];assert row['status']=='passed' and not row['errors']
  assert row['actualSampleRate']==48000 and row['actualChannels']==2
  assert tag['validSampleCount']*1000000==segments[path]['durationMicroseconds']*48000
  delta=s['audioSampleFrames']-tag['validSampleCount'];assert delta==tag['trailingPaddingSamples']==448 and tag['encoderPrimingSamples']==2112
  t['validAudioFrames']+=tag['validSampleCount'];t['trailingPaddingFrames']+=delta
  audioJoin.append({'path':path,'sourceID':s['sourceID'],'rawPCMFrames':s['audioSampleFrames'],'validAudioFrames':tag['validSampleCount'],'trailingPaddingFrames':delta,'encoderPrimingFrames':tag['encoderPrimingSamples'],'declaredDurationMicroseconds':segments[path]['durationMicroseconds'],'declaredDurationExact':True})
assert set(sources)=={'screen','camera-1','camera-2','microphone','systemAudio'} and all(s['segments']==120 for s in sources.values())
assert sum(s['videoFrames'] for s in sources.values())==r['videoFramesPerSource']*3-r['fixtureSkippedFrames']
assert len(audioJoin)==240 and all(sources[s]['validAudioFrames']==r['audioBuffersPerSource']*480==7200*48000 for s in ['microphone','systemAudio'])
assert all(span==[0,7200000000] for span in m['crossSourceSpansMicroseconds'].values())
startRevision='3d2bec8f90977835fcacfcd8c1b38123ac5c1ffc'
sourceFiles=list((repo/'Apps/macOS/Prosio/Recording/Domain').glob('*.swift'))+[repo/'Apps/macOS/Prosio/Recording/Platform/RecordingMediaWriter.swift',repo/'Apps/macOS/Prosio/Recording/Platform/RecordingTimeline.swift',repo/'tools/recording-stress/RecordingStress.swift']
sourceProof=[]
for f in sourceFiles:
 name=str(f.relative_to(repo));b=f.read_bytes();old=subprocess.check_output(['git','show',startRevision+':'+name],cwd=repo);assert old==b
 sourceProof.append({'path':name,'sha256':hashlib.sha256(b).hexdigest(),'matchesStartRevision':True})
binary=Path('/tmp/prosio-recording-stress-build.x57VdE/build/Build/Products/Release/ProsioRecordingStress')
correctedPerformance={**p,'rawSamplerOtherUIAndBuildWorkMayOverlap':p['otherUIAndBuildWorkMayOverlap'],'otherUIAndBuildWorkMayOverlap':True,'interpretationCorrection':'The running sampler loaded false by default, but regression builds, device-tool rebuild, and full ffmpeg decoding did overlap; treat this as background-load soak, not an idle benchmark.'}
(out/'performance.json').write_text(json.dumps(correctedPerformance,indent=2)+'\n')
archiveNames={'report':'writer-report.json.gz','fullDecode':'full-decode.json.gz','mediaAudit':'media-audit.json.gz','aacMetadata':'aac-valid-metadata.json.gz','performance':'performance-sampler-raw.json.gz'}
for key,name in archiveNames.items(): (out/name).write_bytes(gzip.compress(raw[key],mtime=0))
shutil.copyfile('/tmp/prosio-recording-committed-entry-review-20261001.json',out/'committed-entry-source-proof.json')
shutil.copyfile('/tmp/prosio-recording-editor-readiness-final-20261001.json',out/'editor-readiness.json')
now=datetime.datetime.now(datetime.timezone.utc).isoformat();snapshots=r['snapshots']
proof={'checkedAtUTC':now,'acceptance':'PASS for fixed writer two-hour synthetic encoding, finalized metadata and complete decode only','fullObjectiveComplete':False,'terminalProcesses':[{'sessionId':75996,'exitCode':0,'kind':'encoding and performance sampler'},{'sessionId':40876,'exitCode':0,'kind':'full decode watcher'},{'sessionId':56557,'exitCode':0,'kind':'final AVFoundation metadata audit'},{'sessionId':50733,'exitCode':0,'kind':'AAC valid sample metadata audit'}],'sourceRevisionAtStart':startRevision,'sourceProof':sourceProof,'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),'binaryPath':str(binary),'rawInputs':{k:{'path':str(inputs[k]),'sha256':hashlib.sha256(raw[k]).hexdigest(),'archive':archiveNames[k]} for k in inputs},'scope':{'videoSources':3,'width':1920,'height':1080,'fps':30,'audioSources':2,'sampleRate':48000,'channels':2,'durationSeconds':7200,'actualElapsedSeconds':r['actualElapsedSeconds'],'physicalCapture':False,'liveCameraPreview':False,'mouthSyncProven':False,'thermalOrWirelessProven':False},'finalizedMediaCount':600,'sidecarCount':600,'sidecarsExactlyMatchManifest':True,'unmanifestedOrUnfinishedFiles':[],'fullDecodeCount':d['decodedCount'],'fullDecodeFailedCount':d['failedCount'],'mediaAuditFailedCount':m['failedCount'],'timelineErrorCount':m['timelineErrorCount'],'timelineGapCount':m['informationalGapCount'],'crossSourceSpansMicroseconds':m['crossSourceSpansMicroseconds'],'aacJoinCount':len(audioJoin),'sources':sources,'writerStatistics':stats,'fixtureSkippedFrames':r['fixtureSkippedFrames'],'fixtureSkipInterpretation':'Seven frames were never generated by the synthetic video pool; decoded frame totals match the remaining generated frames. Distinct from writer admission/capture/encoder loss, all zero. This is not a zero-total-video-loss claim.','lossFileInterpretation':'No recording-losses.json is expected when recentLosses is empty; current persistLosses implementation returns early in that case. Statistics and decoded frame/audio counts were checked independently.','maximumSchedulingLagSeconds':r['maximumSchedulingLagSeconds'],'performance':{'sampleCount':len(p['samples']),'samplingSeconds':p['samplingSeconds'],'peakRSSBytes':p['peakRSSBytes'],'meanCPUPercent':p['meanCPUPercent'],'peakCPUPercent':p['peakCPUPercent'],'concurrentBuildsAndDecoding':True,'machine':{'model':'MacBookPro17,1','chip':'Apple M1','memoryBytes':8589934592,'logicalCPUCount':8,'macOS':'26.3.1'},'nativeSampleCount':len(snapshots),'nativePeakRSSBytes':max(s['residentBytes'] for s in snapshots),'first10MinuteNativeMedianRSSBytes':statistics.median(s['residentBytes'] for s in snapshots if s['elapsedSeconds']<600),'last10MinuteNativeMedianRSSBytes':statistics.median(s['residentBytes'] for s in snapshots if s['elapsedSeconds']>6600),'finalNativeRSSBytes':snapshots[-1]['residentBytes'],'mediaDiskBytesAtStop':snapshots[-1]['diskBytes'],'diskFreeBytesAtReview':shutil.disk_usage(media).free,'limitations':'Process ps estimates; no total hardware encoder utilization, device capture overhead, UI responsiveness, temperature, Continuity transfer or isolated idle-machine comparison.'},'realDeviceReadiness':{'refreshedAtUTC':now,'screenPermission':'not authorized','cameraPermission':'not requested','microphonePermission':'not requested','state':'idle 00:00; no capture started','selectedSources':['built-in camera','one iPhone Continuity camera','built-in microphone','system audio'],'pendingUserPrivacyRequest':True},'remainingGates':['real screen + two camera + microphone + system audio recording and mouth-sync','USB/capture-card/Continuity physical disconnection and recovery','real-device two-hour capture with camera preview, thermal and wireless load','actual four editor imports and native multicam behavior on supplied macOS versions'],'audioJoin':audioJoin}
(out/'proof.json').write_text(json.dumps(proof,indent=2)+'\n')
print(json.dumps({k:v for k,v in proof.items() if k in ['finalizedMediaCount','fullDecodeCount','aacJoinCount','sources','writerStatistics','performance','remainingGates']},indent=2))
