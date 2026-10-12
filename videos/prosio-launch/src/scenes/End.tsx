import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {Brand} from '../components';
import {T, progress} from '../theme';

export const End: React.FC = () => {
  const f=useCurrentFrame(); const p=progress(f,0,24);
  return <AbsoluteFill style={{background:T.ink,color:T.white,fontFamily:T.font,alignItems:'center',justifyContent:'center'}}>
    <div style={{opacity:p,translate:`0 ${(1-p)*28}px`,display:'flex',flexDirection:'column',alignItems:'center',scale:1 + f*.000045}}>
      <Brand size={70} color={T.white} style={{marginBottom:68}} />
      <div style={{fontSize:126,fontWeight:550,letterSpacing:'-.065em',lineHeight:1.32,textAlign:'center'}}>少一点打断。<br/><span style={{color:'#999995'}}>多一点完成。</span></div>
      <div style={{marginTop:65,background:T.paper,color:T.ink,fontSize:29,borderRadius:60,padding:'23px 48px',display:'flex',alignItems:'center',gap:48,opacity:progress(f,20,22)}}>了解 Prosio <span style={{fontSize:30}}>↗</span></div>
    </div>
    <div style={{position:'absolute',bottom:53,fontSize:24,color:'#979792',letterSpacing:'.07em'}}>让工作顺着想法走</div>
  </AbsoluteFill>;
};
