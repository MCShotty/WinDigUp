// Paste into the installed search window's WebView2 DevTools. No files are indexed or modified by this driver.
// Supply >=101 unique queries from the retained evaluation corpus; the first is a separate warm-up.
// await benchmarkDigUpSearch(["warm-up query", ...queries]);
async function benchmarkDigUpSearch(queries) {
  if(isAppsMode()||isCode())throw new Error("Choose All or a file-kind filter before running the file benchmark.");
  if(!Array.isArray(queries)||queries.length<101||queries.length>501||queries.some(q=>typeof q!=="string"||!q.trim()||q.length>4096))
    throw new Error("Provide a warm-up and at least 100 whole queries (maximum 501).");
  if(new Set(queries.map(q=>q.trim())).size!==queries.length)throw new Error("Queries must be unique; cached queries are reported separately.");
  if(queries.some(q=>/^(apps|code):/i.test(q.trim())))throw new Error("Use file queries without apps: or code: prefixes for this run.");
  const before=await invoke("activity_snapshot"),samples=[];
  const stats=values=>{
    if(!values.length)return {samples:0};
    const sorted=values.slice().sort((a,b)=>a-b);
    return {samples:sorted.length,medianMs:sorted[Math.floor(sorted.length/2)],p95Ms:sorted[Math.ceil(sorted.length*.95)-1],maxMs:sorted.at(-1)};
  };
  for(let index=0;index<queries.length;index++){
    const sample=await new Promise((resolve,reject)=>{
      let generation;
      const timer=setTimeout(()=>{window.removeEventListener("digup-search-timing",listener);reject(new Error(`Query ${index} did not finish semantic search within 120 seconds.`));},120000);
      const listener=event=>{
        if(event.detail.generation!==generation||event.detail.phase!=="file_meaning")return;
        clearTimeout(timer);window.removeEventListener("digup-search-timing",listener);
        if(!event.detail.semantic)reject(new Error(`Query ${index} returned keyword-only results; this is not a valid semantic benchmark.`));
        else resolve(event.detail);
      };
      window.addEventListener("digup-search-timing",listener);
      setQuery(queries[index]);generation=state.generation;
    });
    samples.push(sample);
  }
  const after=await invoke("activity_snapshot"),receipt=after.inference.verified;
  if(!receipt?.model?.startsWith("google/embeddinggemma-2")||receipt.executionPolicy!=="accelerator-only")
    throw new Error("A production model execution receipt is required. Synthetic workers do not establish model performance.");
  const measured=samples.slice(1),uncached=measured.filter(s=>!s.cacheHit),cached=measured.filter(s=>s.cacheHit);
  const report={schemaVersion:1,capturedAt:new Date().toISOString(),platform:navigator.platform,viewport:{width:innerWidth,height:innerHeight,scale:devicePixelRatio},
    configured:after.inference.configured,verified:receipt,index:after.search?.index,
    indexing:{before:before.files.phase,after:after.files.phase,searchable:after.files.searchable},
    warmup:samples[0],uncached:stats(uncached.map(s=>s.total)),cached:stats(cached.map(s=>s.total)),samples:measured,
    minimumUncachedSamplesMet:uncached.length>=100,queryTextIncluded:false};
  console.log(JSON.stringify(report,null,2));
  return report;
}
