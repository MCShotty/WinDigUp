// Integration check for the actual Settings page, with the native Tauri commands mocked.
// Serve shell/ui on localhost:8765; NODE_PATH must expose playwright. No model inference is performed.
const {chromium} = require('playwright');
const assert = require('node:assert/strict');
let browser;
(async()=>{
 browser=await chromium.launch({executablePath:process.env.DIGUP_CHROME || '/usr/bin/chromium',headless:true,args:['--no-sandbox','--disable-dev-shm-usage']});
 const page=await browser.newPage({viewport:{width:720,height:760}});
 const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.addInitScript(()=>{
  window.calls=[];
  const info={acceleration:{backend:'amd-vulkan',gpu:'',python:'',models:''},hotkey:'Ctrl+Shift+Space',shortcut:{method:'grab',command:''},
  folders:[],skipped:[],skipTypes:[],code:{folders:[],skipped:[],editors:[],editor:'default'},state:{model:{state:'ready'}},
  indexHours:{on:false,start:60,end:420},storage:{index:'C:\\DigUp\\index',models:'C:\\DigUp\\Models',indexBytes:0},version:'0.1.0',updateChecks:false};
  window.__TAURI__={core:{invoke:async(command,args)=>{window.calls.push({command,args}); if(command==='settings_info')return info;
   if(command==='accelerator_devices')return {schemaVersion:1,probeOnly:true,devices:[
     {id:'CUDA0',stableID:'GPU-fixture',name:'NVIDIA RTX 2060',backend:'cuda',vendorID:4318,hardware:true,available:true},
     {id:'Vulkan0',stableID:'VK-fixture',name:'AMD RX 7900 XTX',backend:'vulkan',vendorID:4098,hardware:true,available:true}],backends:[]};
   if(command==='set_acceleration' && args.acceleration.backend==='openvino-npu')throw 'Model bundle validation failed';
   if(command==='ask')return {}; return null;}},event:{listen:async()=>()=>{}}};
 });
 await page.goto((process.env.DIGUP_UI_URL || 'http://127.0.0.1:8765') + '/settings.html');
 await page.waitForFunction(()=>document.querySelector('#accelerator').value==='amd-vulkan');
 assert.deepEqual(errors,[]);
 assert.equal(await page.locator('#accelerator option[value="cpu"]').count(),0);
 assert.equal(await page.locator('#accelerator option[value="metal"]').evaluate(n=>n.hidden),true);
 assert.match(await page.locator('#accelerator option[value="amd-vulkan"]').textContent(),/RDNA1/);
 assert.equal(await page.locator('#accelerator option[value="nvidia-vulkan"]').count(),0);
 assert.match(await page.locator('#accelerator option[value="nvidia-cuda"]').textContent(),/RTX 20/);
 await page.selectOption('#accelerator','nvidia-cuda');
 await page.waitForFunction(()=>document.querySelector('#gpu-devices option')?.value==='GPU-fixture');
 assert.match(await page.locator('#gpu-discovery').textContent(),/verified separately/);
 await page.fill('#gpu-device','GPU-fixture');
 await page.evaluate(()=>window.dispatchEvent(new Event('focus')));
 assert.equal(await page.locator('#accelerator').inputValue(),'nvidia-cuda');
 assert.equal(await page.locator('#gpu-device').inputValue(),'GPU-fixture');
 await page.selectOption('#accelerator','amd-vulkan');
 assert.equal(await page.locator('#gpu-device').inputValue(),'');
 await page.selectOption('#accelerator','nvidia-cuda');
 assert.equal(await page.locator('#gpu-device').inputValue(),'GPU-fixture');
 await page.click('#apply-accelerator');
 // The mock records the restart request; release the control for the following independent case.
 await page.evaluate(()=>document.querySelector('#apply-accelerator').disabled=false);
 await page.selectOption('#accelerator','openvino-npu');
 assert.equal(await page.locator('#npu-options').isVisible(),true);
 await page.locator("#openvino-advanced summary").click();
 await page.fill('#npu-python','C:\\DigUpNPU\\.venv\\Scripts\\python.exe');
 await page.fill('#npu-models','C:\\DigUpNPU\\models');
 await page.evaluate(()=>window.dispatchEvent(new Event('focus')));
 await page.waitForFunction(()=>window.calls.filter(x=>x.command==='settings_info').length>=2);
 assert.equal(await page.locator('#accelerator').inputValue(),'openvino-npu');
 assert.equal(await page.locator('#npu-python').inputValue(),'C:\\DigUpNPU\\.venv\\Scripts\\python.exe');
 await page.click('#apply-accelerator');
 await page.waitForFunction(()=>!document.querySelector('#problem').hidden);
 assert.equal(await page.locator('#problem').textContent(),'Model bundle validation failed');
 assert.equal(await page.locator('#apply-accelerator').isEnabled(),true);
 await page.selectOption('#accelerator','amd-vulkan');
 await page.fill('#gpu-device','Vulkan0');
 await page.click('#apply-accelerator');
 const calls=await page.evaluate(()=>window.calls.filter(x=>x.command==='set_acceleration'));
 assert.equal(calls.length,3);assert.equal(calls[0].args.acceleration.backend,'nvidia-cuda');assert.equal(calls[0].args.acceleration.gpu,'GPU-fixture');assert.equal(calls[2].args.acceleration.backend,'amd-vulkan');assert.equal(calls[2].args.acceleration.gpu,'Vulkan0');
 await page.locator('#accelerator').scrollIntoViewIfNeeded();
 if (process.env.DIGUP_UI_SCREENSHOT) await page.screenshot({path:process.env.DIGUP_UI_SCREENSHOT,fullPage:true});
 assert.deepEqual(errors,[]);
 console.log('PASS: CUDA-only NVIDIA choice, discovered stable devices, backend drafts, RDNA1/NPU settings, focus preservation and apply payloads');
 await browser.close();
})().catch(async e=>{console.error(e);if(browser)await browser.close();process.exit(1)});
