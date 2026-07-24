const mqtt=require('mqtt');
const B='seahelm/testmac';
setTimeout(()=>{ console.error('TIMEOUT (reply/message not received)'); process.exit(2); }, 9000);
const got={status:0,focus:0,reply:false,message:false};
const c=mqtt.connect('ws://localhost:28083/mqtt',{clientId:'simweb'});
c.on('connect',()=>{ c.subscribe(`${B}/#`,{qos:1}); });
c.on('message',(t,p)=>{
  const s=t.split('/').slice(2);
  if(s[0]==='pane'&&s[2]==='status') got.status++;
  if(s[0]==='focus') got.focus++;
  if(s[0]==='reply'){ const r=JSON.parse(p.toString()); if(r.ok&&r.corr==='sw1'){got.reply=true; console.log('  ← reply ok corr=sw1'); check();} }
  if(s[0]==='pane'&&s[2]==='message'){ got.message=true; console.log('  ← message '+t+' : '+p.toString().slice(0,60)); check(); }
});
setTimeout(()=>{
  console.log(`  snapshot: status=${got.status} focus=${got.focus} (event not retained → not expected for late sub)`);
  const corr='sw1', reply_to=`${B}/reply/simweb/${corr}`;
  c.publish(`${B}/command`, JSON.stringify({method:'pane.send_text',params:{pane_id:'p1',text:'跑测试'},reply_to,corr}),{qos:1});
  console.log('  → sent pane.send_text {p1}');
},1500);
function check(){
  if(got.status>=3 && got.focus>=1 && got.reply && got.message){
    console.log('  ✓ retained snapshot (3 panes + focus)');
    console.log('  ✓ command reply (ok, corr matched)');
    console.log('  ✓ echoed pane message');
    console.log('ALL PASS'); process.exit(0);
  }
}
