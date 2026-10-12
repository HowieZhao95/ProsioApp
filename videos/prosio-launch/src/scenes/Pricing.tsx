import React from 'react';
import {useCurrentFrame, useVideoConfig} from 'remotion';
import {Frame} from '../components';
import {T, progress} from '../theme';

export const Pricing: React.FC = () => {
  const f=useCurrentFrame(); const {fps}=useVideoConfig(); const p=progress(f, 0, 30);
  return <Frame demo={false}>
    <div style={{position:'absolute',left:104,top:222,width:1712,textAlign:'center',opacity:p,translate:`0 ${(1-p)*30}px`}}>
      <div style={{fontSize:38,color:T.muted,letterSpacing:'.03em'}}>顺手的日常，一个月付方案。</div>
      <div style={{display:'flex',alignItems:'baseline',justifyContent:'center',gap:23,marginTop:26}}>
        <span style={{fontSize:46,fontWeight:500,color:T.muted}}>US$</span>
        <span style={{fontSize:238,fontWeight:550,letterSpacing:'-.075em',lineHeight:1.12,fontVariantNumeric:'tabular-nums'}}>9.90</span>
        <span style={{fontSize:45,color:T.muted}}>／月</span>
      </div>
      <div style={{fontSize:26,color:'#81817B',marginTop:18}}>云端转录月付方案</div>
    </div>
    <div style={{position:'absolute',left:420,right:420,top:682,height:1,background:T.border,scale:`${progress(f, .5*fps, 30)} 1`}} />
    <div style={{position:'absolute',left:414,top:735,width:1092,display:'flex',justifyContent:'space-between',opacity:progress(f,.6*fps,30),translate:`0 ${(1-progress(f,.6*fps,30))*20}px`}}>
      <div style={{width:480,textAlign:'center'}}><div style={{fontSize:67,fontWeight:550,letterSpacing:'-.035em'}}>600 <span style={{fontSize:32,fontWeight:400}}>分钟</span></div><div style={{fontSize:28,color:'#777771',marginTop:12}}>每订阅月 · 云端转录</div></div>
      <div style={{height:112,width:1,background:T.border,marginTop:10}} />
      <div style={{width:480,textAlign:'center'}}><div style={{fontSize:67,fontWeight:550,letterSpacing:'-.035em'}}>不限量</div><div style={{fontSize:28,color:'#777771',marginTop:12}}>本地听写</div></div>
    </div>
    <div style={{position:'absolute',bottom:52,width:'100%',textAlign:'center',fontSize:22,color:'#9A9A94',opacity:progress(f,fps,25)}}>云端额度按订阅账期重置，不结转。税费以结账为准。</div>
  </Frame>;
};
