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
        text(empty, discovery.options?.enabled ? "Choose drives in Apps settings to start discovery." : "Drive discovery is off. Installed applications remain available.");
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
      host.append(this.title, this.state, this.detail, this.jobs, this.capacity);
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
      text(this.detail, "Up to " + limit + " concurrent GPU jobs. Foreground search receives the next available slot.");
      this.jobs.replaceChildren();
      for (const job of jobs.filter(job => ["running","waiting"].includes(job.phase)).slice(0, 4)) {
        const row = create("div");
        const name = job.profile === "text512" ? "Search and purpose matching" : "File and code preparation";
        row.append(create("dt", "", name), create("dd", "", job.phase === "running" ? "Running" : "Waiting"));
        this.jobs.append(row);
      }
      this.capacity.hidden = !inference.capacity?.reason;
      text(this.capacity, (inference.capacity?.backgroundWorkers ? "Background preparation: " + inference.capacity.backgroundWorkers + " workers. " : "") + (inference.capacity?.reason || "").replace(/^(?:worker error:\s*)?capacity_limited:\s*/i,""));
    }
  }
  function summary(discovery = {}) {
    return entries(discovery).map(({ volume, progress }) =>
      "Volume: " + label(volume) + "\nActivity: " + phase(discovery, progress) + "; " + metrics(progress)).join("\n");
  }
  return { DriveList, InferenceView, summary, entries, phase, metrics };
})();
