import {COLORS as C,FONTS as F,SPACING as U,TYPE_SCALE as T} from './_brand.mjs';
export const FONTS=F;
export const FORMAT={width:1280,height:640,name:'hero.png'};
const line=(text,size,color,weight=400)=>({type:'div',props:{style:{display:'flex',fontSize:size,color,fontWeight:weight,whiteSpace:'nowrap'},children:[text]}});
export default()=>({type:'div',props:{style:{display:'flex',flexDirection:'column',width:1280,height:640,padding:8*U,background:C.bg,fontFamily:'Inter',justifyContent:'space-between'},children:[
 line('project-bath',T.support,C.accent,700),
 {type:'div',props:{style:{display:'flex',flexDirection:'column',gap:U},children:[line('Save first.',T.headline,C.text,900),line('Clean carefully.',T.headline,C.text,900)]}},
 line('Bounded cleanup. Preserve user changes.',T.support,C.muted),
 line('Agent Skill / MIT / v0.1.2',T.detail,C.accent,700)
]}});
