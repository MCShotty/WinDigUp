// Native name matching is independent of the file helper and its inference queue.
"use strict";
function isApp(hit) { return hit?.resultType === "application"; }
function resultKey(hit) { return isApp(hit) ? hit.id : `file:${hit.path}`; }
function titleOf(hit) { return isApp(hit) ? hit.name : nameOf(hit.path); }

const Apps = {
  supported: /Win/.test(navigator.platform),
  enabled: /Win/.test(navigator.platform),
  iconCache: new Map(),
  launching: new Set(),
  parse(query, filter = null) {
    const typed = query.trim();
    const appPrefix = this.supported && /^apps:/i.test(typed);
    const codePrefix = /^code:/i.test(typed);
    const mode = appPrefix ? "apps" : codePrefix ? "code" : filter === "apps" ? "apps" : filter === "code" ? "code" : filter ? "files" : "all";
    return { mode, text: appPrefix || codePrefix ? typed.slice(5).trim() : typed,
      apps: this.supported && (mode === "all" || mode === "apps"), files: mode !== "apps", code: mode === "code" };
  },
  async launch(hit) {
    if (this.launching.has(hit.id)) return;
    this.launching.add(hit.id);
    try { return await invoke("launch_app", { appId: hit.id }); }
    catch (error) { throw new Error(error?.message || String(error)); }
    finally { this.launching.delete(hit.id); }
  },
  icon(hit, size = 64) {
    const holder = element("span", "app-icon"); holder.textContent = "▦"; holder.setAttribute("aria-hidden", "true");
    const key = `${hit.id}:${hit.iconRevision || ""}:${size}`;
    if (!this.iconCache.has(key)) {
      const promise = invoke("app_icon", { appId: hit.id, size }).then(fileURL);
      this.iconCache.set(key, promise);
    }
    this.iconCache.get(key).then((src) => {
      const image = element("img"); image.alt = ""; image.src = src; holder.replaceChildren(image);
    }).catch(() => { this.iconCache.delete(key); });
    return holder;
  },
  row(hit, selected, select, launch) {
    const row = element("div", "app-row" + (selected ? " selected" : ""));
    row.title = hit.shortcut || "Registered Windows application";
    row.dataset.resultKey = resultKey(hit); row.setAttribute("role", "option");
    row.setAttribute("aria-selected", String(selected));
    row.setAttribute("aria-label", `Application, ${hit.name}`);
    const text = element("div", "app-row-text");
    text.append(element("div", "app-name", hit.name), element("div", "app-description", hit.description || hit.publisher || "Application"));
    row.append(this.icon(hit), text);
    row.onmousedown = (e) => { if (e.button === 0) e.preventDefault(); };
    row.onclick = () => select(resultKey(hit)); row.ondblclick = () => launch(hit);
    return row;
  },
  details(hit, fail) {
    const box = element("div", "app-details");
    box.append(this.icon(hit, 128), element("div", "app-name", hit.name));
    if (hit.publisher) box.append(element("div", "app-description", hit.publisher));
    if (hit.description) box.append(element("p", "", hit.description));
    box.append(element("p", "app-description", hit.shortcut || "Registered with Windows"));
    box.append(element("p", "app-description", hit.reason === "semantic" ? "Matches what this application does" : "Matches the application name or alias"));
    const launch = element("button", "primary", "Launch");
    launch.onclick = async () => { launch.disabled = true; try { await this.launch(hit); } catch (e) { fail(e); } finally { launch.disabled = false; } };
    box.append(launch);
    if (hit.shortcut) {
      const reveal = element("button", "", "Show shortcut location");
      reveal.onclick = () => invoke("reveal", { path: hit.shortcut }).catch(fail); box.append(reveal);
    }
    return box;
  },
};

class ApplicationSearch {
  constructor(changed, limit = 6) {
    this.changed = changed; this.limit = limit; this.hits = []; this.total = 0;
    this.semantic = { state: "preparing" }; this.catalog = {}; this.epoch = 0; this.offset = 0; this.active = false;
    this.unlisten = [];
    for (const name of ["applications", "applications-progress"]) {
      tauri.event.listen(name, ({ payload }) => {
        if (!this.active) return;
        if (name === "applications") { this.refresh(); return; }
        this.semantic = payload;
        clearTimeout(this.refreshTimer);
        this.refreshTimer = setTimeout(() => {
          this.changed(); if (this.text) this.request(true, true, false, Math.max(this.limit, this.hits.length));
        }, 250);
      }).then((stop) => this.unlisten.push(stop));
    }
  }
  begin(text, active) {
    this.epoch++; clearTimeout(this.timer); clearTimeout(this.refreshTimer);
    this.text = text; this.active = active && Apps.supported; this.hits = []; this.total = 0; this.offset = 0;
    this.finalEpoch = -1; this.error = null;
    if (!this.active) return;
    this.request(false);
    if (text) this.timer = setTimeout(() => this.request(true), 120);
  }
  refresh() {
    if (!this.active) return;
    const wanted = Math.max(this.limit, this.hits.length);
    this.epoch++; this.finalEpoch = -1; clearTimeout(this.timer);
    const epoch = this.epoch;
    return this.request(false, true, false, wanted).then(() => {
      if (epoch === this.epoch) return this.request(true, true, false, wanted);
    });
  }
  async request(meaning, passive = false, append = false, wanted = this.limit) {
    if (!this.active || (meaning && !this.text)) return;
    if (meaning && this.semanticBusy) {
      if (!this.semanticQueued?.append || append || this.semanticQueued.epoch !== this.epoch) this.semanticQueued = {epoch:this.epoch,passive,append,wanted};
      return;
    }
    if (meaning) this.semanticBusy = true;
    const epoch = this.epoch;
    try {
      const page = (offset, limit) => invoke("search_apps", { q: this.text, meaning, generation: epoch, limit, offset, passive });
      const reply = await page(append ? this.hits.length : 0, this.limit);
      if (epoch !== this.epoch || reply.generation !== epoch) return;
      if (append && this.catalog.revision && reply.catalog?.revision !== this.catalog.revision) { this.refresh(); return; }
      const hits = reply.hits || [];
      while (!append && hits.length < wanted && hits.length < reply.total) {
        const next = await page(hits.length, Math.min(this.limit, wanted - hits.length));
        if (epoch !== this.epoch || next.generation !== epoch) return;
        if (next.catalog?.revision !== reply.catalog?.revision) { this.refresh(); return; }
        if (!next.hits?.length) break;
        hits.push(...next.hits);
      }
      if (!meaning && this.finalEpoch === epoch && !passive) return;
      if (meaning) this.finalEpoch = epoch;
      this.hits = append ? [...this.hits, ...hits.filter(h => !this.hits.some(old => old.id === h.id))] : hits;
      this.total = reply.total || 0; this.semantic = reply.semantic || {}; this.catalog = reply.catalog || {};
      Apps.enabled = this.catalog.enabled !== false;
      this.error = null; this.changed();
    } catch (error) {
      if (epoch !== this.epoch) return;
      this.error = error?.message || String(error); this.changed();
    } finally {
      if (meaning) {
        this.semanticBusy = false;
        const queued = this.semanticQueued; this.semanticQueued = null;
        if (queued?.epoch === this.epoch) this.request(true, queued.passive, queued.append, queued.wanted);
      }
    }
  }
  more() { return this.request(Boolean(this.text), true, true); }
  status() {
    if (this.error) return `Applications: ${this.error}`;
    if (this.catalog.enabled === false) return "Application search is off. Enable it in Settings → Apps.";
    const sourceErrors = Object.values(this.catalog.sourceErrors || {});
    if (sourceErrors.length && !this.total) return `Windows applications could not refresh: ${sourceErrors.join("; ")}`;
    if (this.semantic.state === "unavailable") return `App names available; purpose matching unavailable${this.semantic.message ? `: ${this.semantic.message}` : ""}`;
    if (this.semantic.state === "preparing") return this.semantic.total ? `Preparing app purpose matching: ${this.semantic.embedded || 0} of ${this.semantic.total}` : "App names available; preparing purpose matching…";
    if (this.catalog.refreshing) return "Refreshing installed applications…";
    return `${this.total} ${this.total === 1 ? "application" : "applications"}`;
  }
}
