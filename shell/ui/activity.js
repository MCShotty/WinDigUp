// Shared Activity UI. Snapshots use only native memory; helper requests and log tails are never polled here.
"use strict";
window.ActivityUI = (() => {
  const invoke = (command, args) => window.__TAURI__.core.invoke(command, args);
  const listeners = new Set();
  let latest = null, unavailable = "", pending = false, refreshTimer = null, poll = null;
  let viewId = 0;
  const node = (tag, cls, text) => {
    const el = document.createElement(tag); if (cls) el.className = cls;
    if (text != null) el.textContent = text; return el;
  };
  const number = value => typeof value === "number" ? value.toLocaleString() : "Not known yet";
  const shortPath = path => String(path || "").split(/[\\/]/).filter(Boolean).slice(-2).join(" > ");
  const ago = time => {
    if (!Number.isFinite(time)) return "Not reported yet";
    const seconds = Math.max(0, Math.floor(Date.now() / 1000 - time));
    return seconds < 3 ? "Just now" : seconds < 60 ? `${seconds}s ago` : `${Math.floor(seconds / 60)}m ago`;
  };
  const phases = {
    not_configured: "Choose folders to search", starting: "Preparing file indexing", discovering: "Discovering files",
    preparing_queue: "Preparing the indexing queue", indexing: "Indexing files", finishing: "Finishing long files",
    idle: "File index ready", waiting: "Files waiting to be indexed", stopped: "File worker stopped", scheduled: "Indexing is scheduled", pausing: "Pausing indexing…", paused: "Indexing paused",
    failed: "File indexing needs attention", unavailable: "File inference unavailable", checking_accelerator: "Checking the accelerator",
    preparing_model: "Preparing the model",
  };

  async function refresh() {
    if (pending) return;
    pending = true;
    try {
      const next = await invoke("activity_snapshot");
      if (next?.schemaVersion !== 1) throw new Error("Activity information is unavailable for this build.");
      latest = next; unavailable = "";
    } catch (error) { unavailable = error?.message || String(error); }
    finally { pending = false; for (const callback of listeners) callback(latest, unavailable); }
  }
  function schedule() {
    if (!listeners.size || refreshTimer) return;
    refreshTimer = setTimeout(() => { refreshTimer = null; refresh(); }, 400);
  }
  for (const event of ["state", "applications", "applications-progress", "model", "speed", "helper"]) {
    window.__TAURI__.event.listen(event, schedule);
  }
  function subscribe(callback) {
    listeners.add(callback);
    callback(latest, unavailable);
    if (!poll) poll = setInterval(refresh, 2000);
    schedule();
    return () => {
      listeners.delete(callback);
      if (!listeners.size) { clearInterval(poll); poll = null; clearTimeout(refreshTimer); refreshTimer = null; }
    };
  }

  // Redact structured path values first (including spaces/Unicode), then paths inside free-form log text.
  // Native export writes exactly this preview; it never accepts a frontend-selected filesystem destination.
  function redact(text) {
    const hide = value => value
      .replace(/(?:[A-Za-z]:[\\/]|\\\\|\/\/)[^\r\n"<>|]*/g, "[path hidden]")
      .replace(/(^|[\s"'(=:])\/(?!\/)[^\r\n"<>|]*/g, "$1[path hidden]");
    const split = text.indexOf("\n\n--- ");
    const head = split < 0 ? text : text.slice(0, split);
    try {
      const walk = value => typeof value === "string" ? hide(value) : Array.isArray(value) ? value.map(walk)
        : value && typeof value === "object" ? Object.fromEntries(Object.entries(value).map(([key, item]) => [key, walk(item)])) : value;
      return JSON.stringify(walk(JSON.parse(head)), null, 2) + (split < 0 ? "" : hide(text.slice(split)));
    } catch { return hide(text); }
  }

  async function copy(text, field, message) {
    try { await navigator.clipboard.writeText(text); message.textContent = "Copied."; }
    catch {
      if (field) { field.focus(); field.select(); message.textContent = "Press Ctrl+C to copy the selected report."; }
      else {
        const area = node("textarea", "activity-copy-fallback"); area.value = text;
        area.setAttribute("aria-label", "Summary to copy"); message.replaceChildren(area, node("span", "", "Press Ctrl+C to copy."));
        area.focus(); area.select();
      }
    }
  }

  let reportDialog, reportGeneration = 0;
  function createReportDialog() {
    const dialog = node("dialog", "activity-report"); dialog.id = "index-diagnostics-dialog";
    dialog.setAttribute("aria-labelledby", "index-diagnostics-title");
    dialog.innerHTML = `<div class="activity-report-heading"><h2 id="index-diagnostics-title">Diagnostic report preview</h2>
      <button id="index-diagnostics-close" type="button">Close</button></div>
      <p>Local status and recent logs. Review the report before sharing.</p>
      <label class="activity-redaction"><input id="diagnostics-redact" type="checkbox" checked> Hide folder and file paths</label>
      <textarea id="index-diagnostics-text" readonly aria-label="Diagnostic report preview"></textarea>
      <p id="index-diagnostics-message" role="status"></p><div class="activity-actions">
      <button id="index-diagnostics-copy" type="button">Copy report</button>
      <button id="index-diagnostics-export" type="button" class="primary">Export report…</button></div>`;
    document.body.append(dialog);
    dialog.querySelector("#index-diagnostics-close").onclick = () => { reportGeneration++; dialog.close(); };
    dialog.addEventListener("cancel", () => reportGeneration++);
    return dialog;
  }
  async function showReport() {
    const dialog = reportDialog ||= createReportDialog();
    const generation = ++reportGeneration;
    const field = dialog.querySelector("textarea"), message = dialog.querySelector("#index-diagnostics-message");
    const checkbox = dialog.querySelector("#diagnostics-redact");
    const copyButton = dialog.querySelector("#index-diagnostics-copy"), exportButton = dialog.querySelector("#index-diagnostics-export");
    checkbox.checked = true; checkbox.disabled = true; copyButton.disabled = exportButton.disabled = true;
    message.textContent = ""; field.value = "Reading local diagnostic logs…";
    if (!dialog.open) dialog.showModal();
    try {
      const raw = await invoke("indexing_diagnostics");
      if (generation !== reportGeneration || !dialog.open) return;
      const update = () => { field.value = checkbox.checked ? redact(raw) : raw; message.textContent = ""; };
      checkbox.onchange = update; checkbox.disabled = false; update();
      copyButton.disabled = exportButton.disabled = false;
      copyButton.onclick = () => copy(field.value, field, message);
      exportButton.onclick = async () => {
        exportButton.disabled = checkbox.disabled = copyButton.disabled = true;
        try { const result = await invoke("export_diagnostics", { report: field.value }); if(generation === reportGeneration)message.textContent = result?.saved ? "Report exported." : "Export cancelled."; }
        catch (error) { if(generation === reportGeneration)message.textContent = error?.message || String(error); }
        finally { if(generation === reportGeneration)exportButton.disabled = checkbox.disabled = copyButton.disabled = false; }
      };
    } catch (error) { if (generation === reportGeneration) field.value = error?.message || String(error); }
  }

  function summary(snapshot) {
    if (!snapshot) return "Activity status is unavailable.";
    const f = snapshot.files, apps = snapshot.applications, inference = snapshot.inference;
    return ["DigUp activity summary", `Files: ${phases[f.phase] || f.phase}`,
      `Entries checked: ${number(f.entriesChecked)}; candidates${f.candidatesFinal ? "" : " so far"}: ${number(f.candidates)}`,
      `Searchable files: ${number(f.searchable)}; queued: ${number(f.pending)}`,
      f.error ? `File error: ${f.error}` : "", `Applications: ${number(apps.catalog.count)} available; discovery ${apps.catalog.enabled ? "on" : "off"}`,
      `Purpose matching: ${apps.purpose.state || "idle"}; ${number(apps.purpose.embedded)} of ${number(apps.purpose.total)} prepared`,
      `Configured accelerator: ${inference.configured.backend || "unknown"}`,
      `Verified device: ${inference.verified?.device || "No runtime verification reported"}`,
      `Encoder: ${inference.encoder}`, `Last file progress: ${ago(f.lastProgressAt)}`].filter(Boolean).join("\n");
  }

  class View {
    constructor(host, options = {}) {
      this.host = host; this.options = options; this.tab = "overview";
      host.classList.add("activity-view"); host.setAttribute("aria-label", "Activity");
      host.innerHTML = `<div class="activity-heading"><h2>Activity</h2><button data-key="close" type="button">Close</button></div>
        <nav class="activity-tabs" role="tablist" aria-label="Activity views">
          <button data-tab="overview" role="tab" aria-selected="true">Overview</button>
          <button data-tab="diagnostics" role="tab" aria-selected="false">Diagnostics</button></nav>
        <p class="activity-connection" data-key="connection" role="status" hidden></p>
        <div data-key="loading" class="activity-empty">Reading current activity…</div>
        <section data-pane="overview" role="tabpanel" aria-label="Activity overview" hidden>
          <section class="activity-files"><h3 data-key="phase"></h3><p data-key="explanation" class="activity-explanation"></p>
            <ol class="activity-stages" aria-label="File indexing stages"><li>Discover</li><li>Index</li><li>Ready</li></ol>
            <div class="activity-meter" data-key="meter" role="progressbar" aria-label="File indexing progress"><span></span></div>
            <p data-key="progress-label" class="activity-progress-label"></p>
            <div class="activity-metrics"><div><strong data-key="first-value"></strong><span data-key="first-label"></span></div>
              <div><strong data-key="second-value"></strong><span data-key="second-label"></span></div></div>
            <p data-key="candidates-note" class="activity-muted"></p>
            <div class="activity-location"><div><span data-key="root"></span><p data-key="path" class="activity-path"></p></div>
              <button data-key="pause" type="button">Pause indexing</button></div>
            <p data-key="freshness" class="activity-muted"></p>
            <p data-key="file-error" class="activity-error" hidden></p>
            <details data-key="file-details"><summary>File statistics and exclusions</summary>
              <dl><div><dt>Searchable files</dt><dd data-key="searchable"></dd></div><div><dt>Queued files</dt><dd data-key="pending"></dd></div>
              <div><dt>Long files to finish</dt><dd data-key="unfinished"></dd></div></dl><div data-key="skip-reasons"></div></details>
          </section>
          <section class="activity-section" data-key="apps-section"><h3>Applications</h3><dl>
            <div><dt>Installed apps</dt><dd data-key="catalog"></dd></div><div><dt>Purpose matching</dt><dd data-key="purpose"></dd></div></dl>
            <p data-key="purpose-note" class="activity-muted"></p></section>
          <section class="activity-section"><h3>Inference device</h3><p data-key="device" class="activity-device"></p>
            <p data-key="backend" class="activity-muted"></p><p data-key="encoder" class="activity-muted"></p>
            <p data-key="verification" class="activity-verification"></p></section>
        </section>
        <section data-pane="diagnostics" role="tabpanel" aria-label="Activity diagnostics" hidden>
          <h3>Provider health</h3><dl class="activity-health"><div><dt>File indexing</dt><dd data-key="health-files"></dd></div>
            <div><dt>App discovery</dt><dd data-key="health-catalog"></dd></div><div><dt>Purpose matching</dt><dd data-key="health-purpose"></dd></div>
            <div><dt>Query encoder</dt><dd data-key="health-inference"></dd></div></dl>
          <p data-key="health-detail" class="activity-error"></p>
          <div class="activity-actions activity-recovery"><button data-key="retry" type="button">Index now</button>
            <button data-key="refresh-apps" type="button">Refresh apps</button><button data-key="prepare" type="button">Prepare purpose matching</button>
            <button data-key="folders" type="button">Folder settings</button>
            <button data-key="acceleration" type="button">Accelerator settings</button></div>
          <h3 class="activity-event-title">Recent events</h3><ol data-key="events" class="activity-events"></ol>
          <details class="activity-technical"><summary>Technical details</summary>
            <p>Build information, worker state and bounded local logs are loaded on request.</p>
            <button data-key="report" type="button">Preview diagnostic report…</button></details>
        </section>
        <div class="activity-footer"><button data-key="copy" type="button">Copy summary</button>
          <button data-key="diagnostics" type="button">Open diagnostics</button></div><div data-key="message" role="status" class="activity-muted"></div>
        <span data-key="announcement" class="visually-hidden" role="status" aria-live="polite"></span>`;
      this.get = key => host.querySelector(`[data-key="${key}"]`);
      this.get("close").hidden = !options.onClose;
      this.get("close").onclick = () => options.onClose?.();
      const prefix=`activity-view-${++viewId}`;
      for(const button of host.querySelectorAll("[data-tab]")){
        const pane=host.querySelector(`[data-pane="${button.dataset.tab}"]`);
        button.id=`${prefix}-${button.dataset.tab}`;pane.id=`${button.id}-pane`;
        button.setAttribute("aria-controls",pane.id);pane.setAttribute("aria-labelledby",button.id);
      }
      for (const button of host.querySelectorAll("[data-tab]")) button.onclick = () => this.setTab(button.dataset.tab);
      host.querySelector(".activity-tabs").onkeydown = event => {
        const tabs=[...host.querySelectorAll("[data-tab]")], current=tabs.indexOf(event.target);
        if (current < 0 || !["ArrowLeft","ArrowRight","Home","End"].includes(event.key)) return;
        event.preventDefault();
        const next=event.key === "Home" ? 0 : event.key === "End" ? tabs.length-1 : (current + (event.key === "ArrowRight" ? 1 : -1) + tabs.length) % tabs.length;
        this.setTab(tabs[next].dataset.tab); tabs[next].focus();
      };
      host.addEventListener("keydown", event => { if(event.key === "Escape" && !document.querySelector(".activity-report[open]")) { event.preventDefault(); options.onClose?.(); } });
      this.get("diagnostics").onclick = () => this.setTab("diagnostics");
      this.get("report").onclick = showReport;
      this.get("copy").onclick = () => copy(redact(summary(this.snapshot)), null, this.get("message"));
      this.get("pause").onclick = () => this.action("pause_indexing", { paused: !this.snapshot?.files.paused });
      this.get("retry").onclick = () => this.action("index_now");
      this.get("refresh-apps").onclick = () => this.action("refresh_apps");
      this.get("prepare").onclick = () => this.action("prepare_apps");
      this.get("folders").onclick = () => options.onSettings ? options.onSettings("folders") : invoke("open_settings", { tab:"folders" });
      this.get("acceleration").onclick = () => options.onSettings ? options.onSettings("general") : invoke("open_settings", { tab: "general" });
    }
    show(tab = this.tab) { this.setTab(tab); this.stop ||= subscribe((s, error) => this.update(s, error)); }
    hide() { this.stop?.(); this.stop = null; }
    destroy() { this.hide(); this.host.replaceChildren(); }
    setTab(tab) {
      this.tab = tab;
      for (const button of this.host.querySelectorAll("[data-tab]")) { button.setAttribute("aria-selected", String(button.dataset.tab === tab)); button.tabIndex=button.dataset.tab === tab ? 0 : -1; }
      for (const pane of this.host.querySelectorAll("[data-pane]")) pane.hidden = pane.dataset.pane !== tab || !this.snapshot;
      this.get("diagnostics").hidden = tab === "diagnostics";
    }
    async action(command, args) {
      if (this.busy) return;
      this.busy = command; this.get("message").textContent = ""; this.update(this.snapshot, unavailable);
      try { await invoke(command, args); }
      catch (error) { this.get("message").textContent = error?.message || String(error); }
      finally { this.busy = null; await refresh(); }
    }
    update(snapshot, error) {
      this.snapshot = snapshot;
      this.get("connection").hidden = !error;
      const connection = error ? `Activity status unavailable: ${error}${snapshot ? " Showing the last received snapshot." : ""}` : "";
      if(this.get("connection").textContent !== connection)this.get("connection").textContent=connection;
      this.get("loading").hidden = Boolean(snapshot) || Boolean(error);
      if (!snapshot) return;
      this.setTab(this.tab);
      const f = snapshot.files, apps = snapshot.applications, catalog = apps.catalog || {}, purpose = apps.purpose || {}, inference = snapshot.inference;
      const put = (key, value) => { const el=this.get(key), text=value == null ? "" : String(value); if(el.textContent !== text) el.textContent=text; };
      const scanning = ["discovering", "preparing_queue", "starting"].includes(f.phase);
      const title = phases[f.phase] || "File indexing";
      put("phase", title);
      const explanations = {
        discovering: f.searchable ? "Checking for changes. Your existing file index remains searchable." : "The first scan is still running. File indexing starts after discovery finishes.",
        preparing_queue: "Applying exclusions and reconciling supported files with the index.",
        not_configured: "Apps work without folders. Choose folders in Settings to add file search.",
        indexing: "Reading eligible files and preparing searchable content on your selected accelerator.",
        waiting: "Files are queued, but no file operation is in progress. Open Diagnostics to check worker state or choose Index now.",
        finishing: "Reading the remaining pages and chunks of long files. Partial content is already searchable.",
        scheduled: `Existing results remain searchable. Indexing resumes from ${f.scheduledAt || "the scheduled time"}.`,
        paused: "Existing results and application launching remain available.", pausing: "Waiting for the file worker to stop. Search remains available.",
        idle: f.unfinished ? "Partial content is searchable. Long documents still have pages or chunks to finish."
          : f.knownFiles ? "The current pass has finished. DigUp watches your selected folders for changes." : "No supported files are in the index. Review folders and exclusions below.",
        failed: "The last file operation failed. Review diagnostics for the error and recovery actions.",
        stopped: "Discovery stopped before the queue was prepared. Existing results remain searchable; choose Index now in Diagnostics to retry.",
        checking_accelerator: "Running the hardware speed check before file indexing starts.",
        preparing_model: "File indexing is waiting for model files. Application names and launching remain available.",
        unavailable: "The selected accelerator cannot run inference. Application names and launching remain available.",
      };
      put("explanation", explanations[f.phase] || "Waiting for the next file-worker update.");
      const known = typeof f.total === "number" && f.total > 0 && ["indexing", "finishing"].includes(f.phase);
      const meter = this.get("meter"); meter.classList.toggle("indeterminate", !known);
      meter.hidden = !known && !["starting", "discovering", "preparing_queue", "checking_accelerator", "preparing_model"].includes(f.phase);
      meter.firstElementChild.style.width = known ? `${100 * f.done / f.total}%` : "";
      for (const attr of ["aria-valuenow", "aria-valuemin", "aria-valuemax"]) meter.removeAttribute(attr);
      if (known) { meter.setAttribute("aria-valuemin", "0"); meter.setAttribute("aria-valuemax", String(f.total)); meter.setAttribute("aria-valuenow", String(f.done)); }
      meter.setAttribute("aria-valuetext", known ? `${number(f.done)} of ${number(f.total)}` : "Working; total not known yet");
      put("progress-label", known ? `${number(f.done)} of ${number(f.total)} ${f.phase === "finishing" ? "pages and chunks" : "files"}` : meter.hidden ? "" : "Total not known yet");
      const stage = f.phase === "idle" ? 2 : ["indexing", "finishing", "waiting"].includes(f.phase) ? 1 : 0;
      this.host.querySelectorAll(".activity-stages li").forEach((el, i) => { el.classList.toggle("current", i === stage); el.setAttribute("aria-current", i === stage ? "step" : "false"); });
      this.host.querySelector(".activity-stages").hidden = ["not_configured", "failed", "unavailable", "preparing_model"].includes(f.phase);
      put("first-value", number(scanning ? f.entriesChecked : f.searchable)); put("first-label", scanning ? "Entries checked" : "Searchable files");
      put("second-value", number(scanning ? f.candidates : f.pending)); put("second-label", scanning ? (f.candidatesFinal ? "Eligible candidates" : "Candidates so far") : "Queued files");
      put("candidates-note", scanning && !f.candidatesFinal ? "Candidates are checked against exclusions before indexing." : "");
      put("root", f.root ? `Scanning: ${shortPath(f.root)}` : scanning ? "Checking selected folders" : "");
      put("path", shortPath(f.path)); this.get("path").title = f.path || "";
      put("freshness", `Last progress: ${ago(f.lastProgressAt)}${snapshot.helpers.index?.pid ? " · File worker running" : snapshot.helpers.index?.busy ? " · Reading worker state" : " · File worker stopped"}`);
      put("file-error", f.error); this.get("file-error").hidden = !f.error;
      put("searchable", number(f.searchable)); put("pending", scanning && !f.candidatesFinal ? "Not known yet" : number(f.pending)); put("unfinished", number(f.unfinished));
      const skips = [...Object.entries(f.skipped || {}).map(([reason, count]) => `${number(count)} files: ${reason}`),
        ...Object.entries(f.skippedFolders || {}).map(([reason, count]) => `${number(count)} folders: ${reason}`),
        ...(f.missing || []).map(path => `Unavailable: ${shortPath(path)}`), ...(f.unreadable || []).map(path => `Unreadable: ${shortPath(path)}`)];
      put("skip-reasons", skips.join("\n") || "Exclusion counts appear after discovery finishes.");
      const pause = this.get("pause"); pause.hidden = f.phase === "not_configured";
      pause.disabled = Boolean(this.busy) || f.phase === "pausing";
      pause.textContent = this.busy === "pause_indexing" || f.phase === "pausing" ? "Updating pause state…" : f.paused ? "Resume indexing" : "Pause indexing";
      this.get("apps-section").hidden = catalog.supported === false;
      const sourceErrors = Object.values(catalog.sourceErrors || {});
      const catalogState = catalog.supported === false ? "Not supported on this OS" : !catalog.enabled ? "Discovery off" : `${number(catalog.count)} available${catalog.refreshing ? " · Refreshing" : ""}`;
      const encoderIdle = purpose.encoder === "stopped" || !purpose.encoder;
      const complete = typeof purpose.total === "number" && purpose.embedded === purpose.total;
      const purposeState = !catalog.enabled || !catalog.semanticEnabled ? "Off" : purpose.state === "unavailable" ? "Unavailable"
        : typeof purpose.total !== "number" ? (encoderIdle ? "Not started · Encoder idle" : "Preparing")
        : complete && !encoderIdle && purpose.encoder !== "unavailable" ? `${number(purpose.embedded)} / ${number(purpose.total)} ready`
        : `${number(purpose.embedded)} / ${number(purpose.total)} prepared${encoderIdle ? " · Encoder idle" : ""}`;
      put("catalog", catalogState); put("purpose", purposeState);
      put("purpose-note", purpose.message || (sourceErrors.length ? `Some sources could not refresh: ${sourceErrors.join("; ")}` : "Names and launching use the Windows catalog."));
      const verified = inference.verified?.device;
      put("device", verified || "Device not verified yet");
      put("backend", `Configured: ${inference.configured?.backend || "Unknown"}${inference.configured?.gpu ? ` · ${inference.configured.gpu}` : ""}`);
      put("encoder", `${inference.model?.state === "ready" ? "Model files: available" : `Model status: ${inference.model?.state || "unknown"}`} · Encoder: ${inference.encoder}`);
      put("verification", inference.checking ? "Checking accelerator execution…" : verified ? `Accelerator-only execution verified${inference.verified.at ? ` · ${ago(inference.verified.at)}` : ""}` : "Waiting for a verified runtime receipt");
      put("health-files", title); put("health-catalog", catalogState); put("health-purpose", purposeState); put("health-inference", inference.encoder);
      put("health-detail", [f.error, ...(f.missing || []).map(path=>`Folder unavailable: ${shortPath(path)}`),
        ...(f.unreadable || []).map(path=>`Folder unreadable: ${shortPath(path)}`), ...sourceErrors, purpose.message, inference.error].filter(Boolean).join("\n"));
      this.get("retry").disabled = Boolean(this.busy) || !f.canIndexNow;
      this.get("refresh-apps").disabled = Boolean(this.busy) || !catalog.enabled || Boolean(catalog.refreshing);
      this.get("refresh-apps").hidden = catalog.supported === false;
      this.get("prepare").disabled = Boolean(this.busy) || !catalog.enabled || !catalog.semanticEnabled || inference.model?.state !== "ready" || complete;
      this.get("prepare").hidden = catalog.supported === false;
      this.renderEvents(snapshot.events || []);
      if (this.lastPhase !== f.phase) { this.lastPhase=f.phase; put("announcement", title); }
    }
    renderEvents(events) {
      const key = JSON.stringify(events); if (key === this.eventsKey) return; this.eventsKey = key;
      const list=this.get("events"); list.replaceChildren();
      for (const entry of events.slice(0, 20)) {
        const event=entry.event || {}, item=node("li");
        const label = event.message || event.error || event.note || (event.event === "encoder" ? `Query encoder ${event.state}` : event.event === "sync" ? "File queue reconciled" : event.event || (entry.source === "applications" ? `Purpose matching ${event.state || "updated"}` : entry.source));
        item.append(node("span", "activity-event-source", entry.source), node("span", "", String(label).slice(0, 400)), node("time", "", ago(entry.time)));
        list.append(item);
      }
      if (!events.length) list.append(node("li", "activity-muted", "No significant events recorded in this session."));
    }
  }
  return { View, refresh, showReport, redact, summary, subscribe, phases };
})();
