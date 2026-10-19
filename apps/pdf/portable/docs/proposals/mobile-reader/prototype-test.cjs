/* Development-only headless browser evidence. Requires Playwright through NODE_PATH. */
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
(async () => {
 const browser = await chromium.launch({ headless: true });
 const page = await browser.newPage({viewport:{width:390,height:844},deviceScaleFactor:1});
 const errors=[];page.on('pageerror',e=>errors.push(e.message));
 const dir=path.join(__dirname,'prototype-evidence');fs.mkdirSync(dir,{recursive:true});
 const base=process.env.PROTOTYPE_URL||'http://127.0.0.1:61206/prototype.html';
 const results=[];
 for(const scene of ['reader','epub','markdown','groups','documents','collection','history','storage','wheel','missing','consent']){
  await page.goto(base+'?scene='+scene);await page.waitForSelector('.top,.heading');
  await page.screenshot({path:path.join(dir,scene+'-390.png')});
  const size=await page.evaluate(()=>({width:document.documentElement.scrollWidth,viewport:innerWidth}));
  if(size.width>size.viewport)throw Error(scene+' horizontal overflow');
  results.push({scene,width:390,overflow:false});
 }
 await page.goto(base+'?scene=reader');await page.getByRole('button',{name:'Switch',exact:true}).click();
 await page.getByRole('button',{name:/The art of noticing EPUB/}).click();
 await page.getByText('The small things').waitFor();results.push({interaction:'tap switch PDF to EPUB',passed:true});
 await page.goto(base+'?scene=reader');const trigger=await page.locator('#switch-control').boundingBox();
 await page.mouse.move(trigger.x+trigger.width/2,trigger.y+trigger.height/2);await page.mouse.down();
 await page.waitForSelector('#wheel');const wheel=await page.locator('#wheel').boundingBox();
 await page.mouse.move(wheel.x+wheel.width/2,wheel.y+wheel.height/2);
 await page.mouse.move(wheel.x+wheel.width/2+87,wheel.y+wheel.height/2-51);await page.mouse.up();
 await page.getByText('The small things').waitFor();results.push({interaction:'hold, center, direction, release to EPUB',passed:true});
 await page.goto(base+'?scene=reader');const t=await page.locator('#switch-control').boundingBox();
 await page.mouse.move(t.x+t.width/2,t.y+t.height/2);await page.mouse.down();await page.waitForSelector('#wheel');await page.mouse.up();
 if(await page.locator('#wheel').count())throw Error('unarmed release did not dismiss');
 await page.getByText('A room for thought',{exact:true}).first().waitFor();results.push({interaction:'unarmed release cancels',passed:true});
 await page.goto(base+'?scene=collection');await page.getByRole('textbox').fill('quiet');
 if(await page.locator('.doc-row').count()!==2)throw Error('Collection search incorrect');results.push({interaction:'Collection text filter',passed:true});
 await page.goto(base+'?scene=history');await page.getByRole('button',{name:'Open this version'}).last().click();
 await page.getByText('Older version · 12 Sep 2026').waitFor();await page.getByRole('button',{name:'Return to latest'}).click();
 results.push({interaction:'dated revision and Return to latest',passed:true});
 await page.goto(base+'?scene=storage');await page.getByRole('button',{name:'Review cleanup'}).click();await page.getByRole('button',{name:'Clean up sample data'}).click();
 await page.getByText('298 MiB',{exact:true}).waitFor();results.push({interaction:'cleanup accounting',passed:true});
 for(const scene of ['groups','collection','wheel','consent']){
  await page.setViewportSize({width:360,height:800});await page.goto(base+'?scene='+scene+'&large=1');
  await page.screenshot({path:path.join(dir,scene+'-360-large.png')});
  if(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth))throw Error('large text overflow');
  results.push({scene,width:360,large:true,overflow:false});
 }
 await page.setViewportSize({width:844,height:390});await page.goto(base+'?scene=wheel');
 await page.screenshot({path:path.join(dir,'wheel-landscape.png')});
 if(errors.length)throw Error(errors.join('\n'));
 fs.writeFileSync(path.join(dir,'results.json'),JSON.stringify({testedAt:new Date().toISOString(),scope:'Browser prototype only; no native claims',results,errors},null,2));
 console.log(JSON.stringify({passed:results.length,errors,screenshots:dir}));await browser.close();
})().catch(e=>{console.error(e);process.exit(1)});
