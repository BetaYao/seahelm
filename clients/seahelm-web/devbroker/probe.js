const mqtt=require('mqtt');
setTimeout(()=>{ console.error('HARD TIMEOUT 8s'); process.exit(2); }, 8000);
function probe(name,url){
  return new Promise(res=>{
    const c=mqtt.connect(url,{clientId:name,connectTimeout:4000,reconnectPeriod:0});
    c.on('connect',()=>{ console.log(`  ✓ ${name} connected (${url})`); c.end(); res(true); });
    c.on('error',e=>{ console.log(`  ✗ ${name} error: ${e.message}`); res(false); });
    c.on('close',()=>{});
  });
}
(async()=>{
  await probe('tcp','mqtt://localhost:2883');
  await probe('ws','ws://localhost:28083/mqtt');
  await probe('ws-nopath','ws://localhost:28083');
  process.exit(0);
})();
