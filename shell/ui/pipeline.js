"use strict";
window.PipelineUI = (() => {
  const count = value => Number.isFinite(value) ? value.toLocaleString() : "Not reported";
  const text = (element, value) => { if (element.textContent !== value) element.textContent = value; };
  const create = (tag, className, value) => {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (value != null) element.textContent = value;
    return element;
  };
  const phases = {
    waiting: "Waiting for disk capacity", enumerating: "Discovering executables", resolving: "Resolving application paths",
    metadata: "Reading application details", reconciling: "Checking changes", watching: "Watching for changes",
    failed: "Refresh needs attention", unavailable: "Volume unavailable", paused: "Paused", disabled: "Off",
  };
  function entries(discovery) {
    const volumes = discovery.volumes || [], rows = discovery.byVolume || {};
    const ids = discovery.options?.volumes || Object.keys(rows);
    return ids.map(id => {
      const volume = volumes.find(value => value.id === id);
      const progress = rows[id] || (discovery.progress?.volume === id ? discovery.progress : {});
      return { id, volume, progress };
    });
  }
  function label(volume) {
    return [(volume?.paths || []).join(", "), volume?.name].filter(Boolean).join(" · ") || "Disconnected volume";
  }
  function phase(discovery, progress) {
    if (discovery.catalogEnabled === false) return "Application search is off";
    if (!discovery.options?.enabled) return "Off";
    if (discovery.options?.paused) return "Paused";
    if (!discovery.running && discovery.progress?.phase === "failed" && !["watching","failed","unavailable"].includes(progress.phase))
      return "Refresh needs attention";
    return phases[progress.phase] || "Waiting to scan";
  }
  function metrics(progress) {
    return [
      Number.isFinite(progress.records) ? count(progress.records) + " entries checked" : "",
      Number.isFinite(progress.candidates) ? count(progress.candidates) + " executable candidates" : "",
      Number.isFinite(progress.accepted) ? count(progress.accepted) + " accepted candidates" : "",
    ].filter(Boolean).join(" · ") || "Counts appear as discovery progresses.";
  }
  function addTimings(list, title, timings) {
    if (!timings?.stages) return;
    const names = { enumeration:"Enumeration", pathResolution:"Path resolution", permissionChecks:"Access checks",
      metadataReads:"Metadata reads", metadataQueue:"Metadata waiting", databaseCommit:"Database commits",
      catalogPublication:"Catalog publication (shared)", directoryMetadata:"Directory metadata" };
    const heading = create("p", "pipeline-timing-owner", title);
    const table = create("dl", "pipeline-timings");
    for (const [key, value] of Object.entries(timings.stages)) {
      if (!Number.isFinite(value.milliseconds)) continue;
      const row = create("div");
      row.append(create("dt", "", names[key] || key),
        create("dd", "", Math.round(value.milliseconds).toLocaleString() + " ms"));
      table.append(row);
    }
    if (table.children.length) list.append(heading, table);
  }
  class DriveList {
    constructor(host) { this.host = host; this.rows = new Map(); host.classList.add("pipeline-drives"); }
    update(discovery = {}) {
      const items = entries(discovery), present = new Set();
      for (const item of items) {
        present.add(item.id);
        let row = this.rows.get(item.id);
        if (!row) {
          const root = create("article", "pipeline-drive");
          root.dataset.volumeId = item.id;
          const name = create("h4", "pipeline-drive-name");
          const state = create("p", "pipeline-drive-phase");
          const numbers = create("p", "pipeline-drive-counts");
          const explanation = create("p", "pipeline-drive-note");
          const error = create("p", "pipeline-drive-error");
          const details = create("details", "pipeline-drive-details");
          const timing = create("div");
          details.append(create("summary", "", "Stage measurements"), timing);
          root.append(name, state, numbers, explanation, error, details);
          row = { root, name, state, numbers, explanation, error, details, timing };
          this.rows.set(item.id, row);
        }
        const p = item.progress;
        text(row.name, label(item.volume)); row.name.title = item.id;
        text(row.state, phase(discovery, p));
        text(row.numbers, metrics(p));
        const topology = item.volume?.topology || p.topology;
        const storage = topology?.known ? topology.media === "ssd" ? "SSD" : topology.media === "hdd" ? "Hard disk" : "Storage type not reported" : "Disk relationship unknown; scanning conservatively";
        const mode = p.mode === "ntfs" ? "NTFS records" : p.mode === "directory" ? "Directory scan" : "";
        text(row.explanation, [mode, storage, p.partial ? "Some locations were unreadable; previous applications were retained." : "",
          p.message && !["failed","unavailable"].includes(p.phase) ? p.message : ""].filter(Boolean).join(" · "));
        const error = discovery.sourceErrors?.[item.id] || (["failed","unavailable"].includes(p.phase) ? p.message : "");
        row.error.hidden = !error; text(row.error, error || "");
        const signature = JSON.stringify([p.serviceTimings, p.timings]);
        if (signature !== row.timingSignature) {
          row.timingSignature = signature; row.timing.replaceChildren();
          addTimings(row.timing, p.mode === "directory" ? "Directory discovery" : "NTFS inventory", p.serviceTimings);
          addTimings(row.timing, "Application catalog", p.timings);
          if (row.timing.children.length) row.timing.append(create("p", "pipeline-drive-note",
            "Cumulative stage durations. Overlapping stages do not add up to elapsed time."));
        }
        row.details.hidden = !row.timing.children.length;
      }
      for (const [id, row] of this.rows) if (!present.has(id)) { row.root.remove(); this.rows.delete(id); }
      for (let index = 0; index < items.length; index++) {
        const row = this.rows.get(items[index].id).root;
        if (this.host.children[index] !== row) this.host.insertBefore(row, this.host.children[index] || null);
      }
      let empty = this.host.querySelector(".pipeline-drive-empty");
      if (!items.length) {
        if (!empty) { empty = create("p", "pipeline-drive-empty"); this.host.append(empty); }
        text(empty, discovery.catalogEnabled === false ? "Application search is off. Enable installed applications to resume drive discovery." : discovery.options?.enabled ? "Choose drives in Settings → Drives to start discovery." : "Drive discovery is off. Installed applications remain available.");
      } else empty?.remove();
    }
  }
  class InferenceView {
    constructor(host) {
      this.host = host;
      this.title = create("h3", "", "GPU work");
      this.state = create("p", "pipeline-inference-state");
      this.detail = create("p", "pipeline-drive-note");
      this.jobs = create("dl", "pipeline-jobs");
      this.capacity = create("p", "pipeline-drive-note");
      this.telemetry=create("section","pipeline-device-measurements");
      this.telemetryState=create("p","pipeline-drive-note");
      this.telemetryValues=create("p","pipeline-drive-counts");
      this.telemetrySource=create("p","pipeline-drive-note");
      this.telemetry.append(create("h4","","Measured device activity"),this.telemetryState,this.telemetryValues,this.telemetrySource);
      host.append(this.title, this.state, this.detail, this.jobs, this.capacity, this.telemetry);
    }
    update(inference = {}) {
      const backend = inference.configured?.backend;
      this.host.hidden = !["amd-vulkan", "nvidia-cuda", "vulkan"].includes(backend);
      if (this.host.hidden) return;
      const jobs = Object.values(inference.jobs || {});
      const running = jobs.filter(job => job.phase === "running");
      const waiting = jobs.filter(job => job.phase === "waiting");
      const configured = inference.configured?.jobs || 3;
      const limit = configured;
      text(this.state, jobs.length ? running.length + " running · " + waiting.length + " waiting" : "Worker activity has not been reported.");
      text(this.detail, "Up to " + limit + " concurrent GPU jobs. Foreground search receives the next available slot." +
        (inference.configured?.resourceProfile === "quiet" ? " Quiet limits background preparation to one model owner." : ""));
      this.jobs.replaceChildren();
      for (const job of jobs.filter(job => ["running","waiting"].includes(job.phase)).slice(0, 4)) {
        const row = create("div");
        const name = job.profile === "text512" ? "Search and purpose matching" : "File and code preparation";
        row.append(create("dt", "", name), create("dd", "", job.phase === "running" ? "Running" : "Waiting"));
        this.jobs.append(row);
      }
      const measured=inference.telemetry;
      const supported=measured?.schemaVersion===1;
      const utilization=supported&&Number.isFinite(measured.utilizationPercent)&&measured.utilizationPercent>=0&&measured.utilizationPercent<=100
        ? measured.utilizationPercent.toFixed(0)+"% device utilization" : "Device utilization not reported";
      const memory=supported&&Number.isFinite(measured.memoryUsedBytes)&&measured.memoryUsedBytes>=0
        ? (measured.memoryUsedBytes/1073741824).toFixed(2)+" GiB device memory used"+
          (Number.isFinite(measured.memoryTotalBytes)&&measured.memoryTotalBytes>0?" of "+(measured.memoryTotalBytes/1073741824).toFixed(2)+" GiB":"")
        : "Device memory not reported";
      text(this.telemetryState,supported ? measured.state==="ready" ? "Measured by the device provider." :
        measured.state==="stale" ? "Last device sample is stale." : measured.message||"Device measurements are unavailable."
        : "Device measurements have not been reported.");
      text(this.telemetryValues,utilization+" · "+memory);
      text(this.telemetrySource,supported ? [measured.source?"Source: "+measured.source:"",
        measured.deviceId?"Device: "+measured.deviceId:"",Number.isFinite(measured.ageMs)?"Sample age "+Math.round(measured.ageMs/1000)+" s":"",Number.isFinite(measured.intervalMs)?"Sample interval "+measured.intervalMs+" ms":"",
        "Device-wide counters include other applications."].filter(Boolean).join(" · ") :
        "Worker request counts do not measure GPU utilization.");
      this.capacity.hidden = !inference.capacity?.reason;
      text(this.capacity, (inference.capacity?.backgroundWorkers ? "Background preparation: " + inference.capacity.backgroundWorkers + " workers. " : "") + (inference.capacity?.reason || "").replace(/^(?:worker error:\s*)?capacity_limited:\s*/i,""));
    }
  }
  const indexingReasons = {
    waiting_for_input:"Waiting for prepared input", preparing:"Preparing file contents", running:"Inference requests in progress",
    publication_backpressure:"Waiting for earlier results to be saved", cancelled:"Indexing stopped at a safe boundary",
    failed:"Indexing needs attention", idle:"Queue completed",
  };
  function indexingSample(files = {}) {
    return Object.values(files.pipeline || {}).filter(value => value?.schemaVersion === 2)
      .sort((a,b) => (b.receivedAt || b.capturedAt || 0) - (a.receivedAt || a.capturedAt || 0))[0];
  }
  function heldSummary(files = {}) {
    return [[files.heldPending,"pending files"],[files.heldUnfinished,"long files"]]
      .filter(([value]) => Number.isFinite(value) && value > 0)
      .map(([value,label]) => count(value)+" "+label+" held until folders are checked").join(" · ");
  }
  function heldFiles(files = {}) {
    return files.phase === "waiting" && Boolean(heldSummary(files))
      && files.runnablePending === 0 && files.runnableUnfinished === 0;
  }
  const stoppedPipeline = {
    failed:"Indexing failed",stopped:"File worker stopped",unavailable:"File inference unavailable",
    not_configured:"File search is not configured",preparing_model:"Waiting for model files",
    checking_accelerator:"Checking the accelerator",starting:"Waiting for a pipeline update",
    idle:"No active file indexing reported",waiting:"No active file operation reported",
  };
  function indexSummary(files = {}) {
    const sample = indexingSample(files);
    if (!sample) return "";
    return "Indexing pipeline: " + (heldFiles(files) ? "Queued work held until folders are checked" : stoppedPipeline[files.phase] || indexingReasons[sample.blockedBy] || sample.blockedBy || "Unknown") +
      "; last reported " + count(sample.readyJobs) + " ready; " + count(sample.runningJobs) + " inference requests; " +
      count(sample.completedJobs) + " awaiting publication; admission capacity " + count(sample.capacity);
  }
  class IndexingView {
    constructor(host) {
      this.host = host;
      this.state = create("p");
      this.counts = create("p", "pipeline-drive-counts");
      this.note = create("p", "pipeline-drive-note");
      this.details = create("details", "pipeline-drive-details");
      this.table = create("dl", "pipeline-timings");
      this.details.append(create("summary", "", "Indexing stage measurements"), this.table,
        create("p", "pipeline-drive-note", "Worker durations overlap. Inference requests include admission and runtime waits."));
      this.fields = new Map();
      for (const [key,label] of [
        ["queueBuildMs","Queue preparation"],["queueFetchMs","Metadata pages"],["preparationMs","File preparation"],
        ["inferenceInputWaitMs","Inference lanes waiting for input"],["inferenceMs","Inference calls"],
        ["commitMs","Publication"],["cleanupMs","Scratch cleanup"],["notificationMs","Progress notifications"],
        ["queueRows","Metadata records loaded"],["peakBufferedRecords","Peak buffered metadata records"],
        ["peakResidentJobs","Peak retained jobs"],["peakPreparedBytes","Peak prepared text/path payload"],
        ["peakScratchBytes","Peak prepared scratch files"],
      ]) {
        const row=create("div"),value=create("dd");
        row.append(create("dt","",label),value);this.table.append(row);this.fields.set(key,value);
      }
      host.append(create("h3","","Indexing pipeline"),this.state,this.counts,this.note,this.details);
    }
    update(files = {}, inference = {}) {
      const sample=indexingSample(files);this.host.hidden=!sample;
      if(!sample)return;
      const phase=files.paused?"Indexing paused":files.phase==="scheduled"?"Waiting for the indexing schedule":
        heldFiles(files)?"Queued work held until folders are checked":
        stoppedPipeline[files.phase] || "Latest pipeline report: "+(indexingReasons[sample.blockedBy] || "Status unavailable");
      text(this.state,phase);
      text(this.counts,"Last reported: "+count(sample.readyJobs)+" ready · "+count(sample.runningJobs)+" inference requests · "+
        count(sample.completedJobs)+" awaiting publication");
      text(this.note,(stoppedPipeline[files.phase] ? "Historical counters; current worker state is reported above. " : "")+
        "Last reported admission capacity "+count(sample.capacity)+" jobs · "+count(sample.preparationWorkers)+
        " preparation workers · Up to "+count(sample.inferenceWorkers)+" inference requests. "+
        (inference.error ? "See the inference error below." : ""));
      for(const [key,element] of this.fields){
        const value=sample[key];
        const label=!Number.isFinite(value)?"Not reported":key.endsWith("Ms")?
          (value<1000?Math.round(value)+" ms":(value/1000).toFixed(2)+" s"):
          key.endsWith("Bytes")?(value/1048576).toFixed(1)+" MiB":value.toLocaleString();
        text(element,label);
      }
    }
  }
  function summary(discovery = {}) {
    return entries(discovery).map(({ volume, progress }) =>
      "Volume: " + label(volume) + "\nActivity: " + phase(discovery, progress) + "; " + metrics(progress)).join("\n");
  }
  return { DriveList, InferenceView, IndexingView, indexSummary, summary, entries, phase, metrics, heldFiles, heldSummary };
})();
