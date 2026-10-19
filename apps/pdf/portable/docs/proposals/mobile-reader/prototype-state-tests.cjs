/* Pure fixture-state regressions. No browser, app launch, or native behavior is involved. */
const fs = require('fs');
const vm = require('vm');
const path = require('path');
const assert = require('assert/strict');
const context = {document:{querySelector:()=>null},location:{search:'?scene=recovery'},URLSearchParams};
vm.createContext(context);
for (const file of ['prototype-data.js','prototype-reading.js','prototype-search.js','prototype-screens.js']) {
  vm.runInContext(fs.readFileSync(path.join(__dirname,file),'utf8'),context);
}
vm.runInContext(`function render(){};function escapeHtml(s){return s.replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]))}`,context);
const checks = vm.runInContext(`(()=>{
 const result=[];
 initReadingFixtures();
 handleReadingAction('opencapture');
 result.push(['open newer unverified',state.unverified&&state.revisionDate==='24 Sep 2026']);
 result.push(['verified return label',revisionReturnControl().includes('Return to latest verified')]);
 handleReadingAction('latest');
 result.push(['return to preferred verified revision',!state.unverified&&state.older&&state.revisionDate==='18 Sep 2026'&&state.missing]);
 result.push(['verified badge after return',revisionReturnControl().includes('Latest verified')]);
 state.doc=1;state.older=false;
 const original=JSON.stringify({doc:state.doc,older:state.older,revisionDate:state.revisionDate,unverified:state.unverified});
 handleReadingAction('export','18');
 result.push(['explicit history export',exportTargetDescription().includes('18 Sep 2026 version')&&exportTargetDescription().includes('The art of noticing.epub')]);
 result.push(['history export preserves reader',original===JSON.stringify({doc:state.doc,older:state.older,revisionDate:state.revisionDate,unverified:state.unverified})]);
 state.onlyUnverified=true;
 handleReadingAction('export','captured-24');
 result.push(['unopened capture export date',state.exportTarget.revisionDate==='24 Sep 2026']);
 result.push(['unopened capture export warning',state.exportTarget.unverified&&exportTargetDescription().includes('source consistency unverified')]);
 result.push(['unopened capture export preserves reader',original===JSON.stringify({doc:state.doc,older:state.older,revisionDate:state.revisionDate,unverified:state.unverified})]);
 handleReadingAction('export');
 result.push(['reader export replaces previous target',state.exportTarget.revisionDate===null&&!state.exportTarget.unverified]);
 state.query='quiet';
 result.push(['two matching documents',collectionMatches().length===2]);
 result.push(['query-aware count',collectionCount()==='2 matches']);
 result.push(['matching highlight',collectionRows().includes('<mark>quiet</mark>')]);
 state.query='';
 result.push(['blank-query count',collectionCount()==='7 documents']);
 result.push(['blank-query has no highlights',!collectionRows().includes('<mark>')]);
 result.push(['global sample count',globalResults('quiet').includes('2 sample results')]);
 result.push(['global groups included',globalResults('space').includes('Groups')]);
 result.push(['Collection scope excludes groups',!globalResults('col:space').includes('<h2>Groups</h2>')]);
 return result;
})()`,context);
for(const [name,passed] of checks) assert.equal(passed,true,name);
console.log(JSON.stringify({passed:checks.length,scope:'Pure browser-prototype state only',checks:checks.map(([name])=>name)},null,2));
