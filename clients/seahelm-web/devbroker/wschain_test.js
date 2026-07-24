const mqtt = require('mqtt');
const URL = 'ws://localhost:28083/mqtt';
const B = 'seahelm/testmac';
const ok = (m)=>console.log('  ✓ '+m);
const die = (m)=>{ console.error('  ✗ '+m); process.exit(1); };
let done=0; const need=2;
const finish=()=>{ if(++done>=need){ console.log('ALL PASS'); process.exit(0); } };

// ---- Test 1: retained delivered to a FRESH subscriber over WS ----
const pub = mqtt.connect(URL, {clientId:'pub'});
pub.on('connect', ()=>{
  pub.publish(`${B}/pane/p1/status`,
    JSON.stringify({pane_id:'p1',status:'running',last_message:'重排卡片间距',seq:1}),
    {qos:1, retain:true}, ()=>{
      ok('retained status published (WS)');
      const sub = mqtt.connect(URL, {clientId:'sub-fresh'});
      sub.on('connect', ()=> sub.subscribe(`${B}/pane/+/status`,{qos:1}));
      sub.on('message', (t,p)=>{
        const m=JSON.parse(p.toString());
        if(t===`${B}/pane/p1/status` && m.status==='running'){ ok('fresh subscriber got RETAINED (上线即得)'); sub.end(); finish(); }
        else die('unexpected retained msg: '+t);
      });
      setTimeout(()=>die('retained not delivered in 3s'),3000);
    });
});

// ---- Test 2: command → reply round-trip (payload reply_to/corr) ----
const seahelm = mqtt.connect(URL, {clientId:'seahelm-mock'});
seahelm.on('connect', ()=>{
  seahelm.subscribe(`${B}/command`,{qos:1});
  seahelm.on('message', (t,p)=>{
    const req=JSON.parse(p.toString());
    if(t===`${B}/command` && req.method==='pane.send_text'){
      ok('Seahelm got command: '+req.method);
      seahelm.publish(req.reply_to, JSON.stringify({ok:true,result:{sent:true},corr:req.corr}),{qos:1});
    }
  });
  // web client side
  const web = mqtt.connect(URL, {clientId:'web'});
  web.on('connect', ()=>{
    const corr='w1', reply_to=`${B}/reply/web/${corr}`;
    web.subscribe(reply_to,{qos:1});
    web.on('message',(t,p)=>{
      const r=JSON.parse(p.toString());
      if(t===reply_to && r.ok && r.corr===corr){ ok('web got reply for corr='+corr+' (payload 式应答)'); web.end(); seahelm.end(); finish(); }
    });
    setTimeout(()=> web.publish(`${B}/command`,
      JSON.stringify({method:'pane.send_text',params:{pane_id:'p1',text:'跑测试',enter:true},reply_to,corr}),{qos:1}), 300);
    setTimeout(()=>die('reply not received in 3s'),3000);
  });
});
