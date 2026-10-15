// Native name matching is independent of the file helper and its inference queue.
"use strict";
function isApp(hit) { return hit?.resultType === "application"; }
function resultKey(hit) { return isApp(hit) ? hit.id : `file:${hit.path}`; }
function titleOf(hit) { return isApp(hit) ? hit.name : nameOf(hit.path); }

const Apps = {
  supported: /Win/.test(navigator.platform),
  enabled: /Win/.test(navigator.platform),
  iconCache: new Map(),
  observedIcons: new Set(),
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
    finally {
      this.launching.delete(hit.id);
      for(const row of document.querySelectorAll(`[data-result-key="${CSS.escape(hit.id)}"]`)) {
        const button=row.querySelector(".app-launch");if(button)button.disabled=false;
      }
    }
  },
  icon(hit, size = 64) {
    const holder = element("span", "app-icon"); holder.setAttribute("aria-hidden", "true");
    const fallback = element("img", "app-generic"); fallback.src = "app-generic.svg"; fallback.alt = ""; holder.append(fallback);
    const key = `${hit.id}:${hit.iconRevision || ""}:${size}`;
    const load = () => {
      if (!this.iconCache.has(key)) {
        this.iconCache.set(key, invoke("app_icon", { appId: hit.id, size }).then(fileURL));
        if (this.iconCache.size > 256) this.iconCache.delete(this.iconCache.keys().next().value);
      }
      this.iconCache.get(key).then(src => {
        if (!holder.isConnected) return;
        const image = element("img"); image.alt = ""; image.src = src;
        image.onload = () => holder.replaceChildren(image);
      }).catch(() => {});
    };
    if (typeof IntersectionObserver === "undefined") load();
    else {
      this.iconObserver ||= new IntersectionObserver(entries => {
        for (const entry of entries) if(entry.isIntersecting) {
          this.iconObserver.unobserve(entry.target); this.observedIcons.delete(entry.target); entry.target.loadIcon?.();
        }
      }, {rootMargin:"80px"});
      holder.loadIcon = load; this.observedIcons.add(holder); this.iconObserver.observe(holder);
      if (!this.pruneIcons) this.pruneIcons = requestAnimationFrame(() => {
        this.pruneIcons = null;
        for (const icon of this.observedIcons) if(!icon.isConnected) { this.iconObserver.unobserve(icon);this.observedIcons.delete(icon); }
      });
    }
    return holder;
  },
  row(hit, selected, select, launch, expanded = false) {
    const row = element("div", "app-row" + (selected ? " selected" : ""));
    row.title = hit.shortcut || "Registered Windows application";
    row.dataset.resultKey = resultKey(hit); row.setAttribute("role", expanded ? "row" : "option");
    row.setAttribute("aria-selected", String(selected));
    row.setAttribute("aria-label", `Application, ${hit.name}`);
    const text = element("div", "app-row-text");
    text.append(element("div", "app-name", hit.name));
    if (expanded && hit.publisher) text.append(element("div", "app-publisher", hit.publisher));
    text.append(element("div", "app-description", hit.purpose || hit.description || hit.publisher || "Windows application"));
    const icon = this.icon(hit); row.append(icon, text);
    if (expanded) {
      row.classList.add("app-row-expanded"); icon.setAttribute("role","gridcell"); text.setAttribute("role","gridcell");
      const reason = element("span", "app-match-reason", hit.reason === "semantic" ? "Purpose match" : ""); reason.setAttribute("role","gridcell"); row.append(reason);
      const actions = element("span", "app-row-actions"); actions.setAttribute("role","gridcell");
      const button = element("button", "app-launch", "Launch"); button.setAttribute("aria-label",`Launch ${hit.name}`);
      button.disabled = this.launching.has(hit.id); button.tabIndex = selected ? 0 : -1;
      button.onclick = async event => { event.stopPropagation(); select(resultKey(hit)); button.disabled=true; try { await launch(hit); } finally { button.disabled=false; } };
      actions.append(button); row.append(actions);
    }
    row.onmousedown = (e) => { if (e.button === 0) e.preventDefault(); };
    row.onclick = () => select(resultKey(hit)); row.ondblclick = () => launch(hit);
    return row;
  },
  details(hit, fail) {
    const box = element("div", "app-details");
    box.append(this.icon(hit, 128), element("div", "app-name", hit.name));
    if (hit.publisher) box.append(element("div", "app-description", hit.publisher));
    if (hit.purpose || hit.description) box.append(element("p", "", hit.purpose || hit.description));
    if (hit.aliases?.length) box.append(element("p", "app-description", `Aliases: ${hit.aliases.join(", ")}`));
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
  constructor(changed, limit = 6, selected = null) {
    this.changed = changed; this.selected = selected; this.limit = limit; this.hits = []; this.total = 0;
    this.semantic = { state: "preparing" }; this.catalog = {}; this.epoch = 0; this.offset = 0; this.active = false;
    this.unlisten = [];
    for (const name of ["applications", "applications-progress"]) {
      tauri.event.listen(name, ({ payload }) => {
        if (name === "applications") {
          this.catalog=payload; Apps.enabled=payload.enabled !== false;
          if(!Apps.enabled) {
            this.epoch++;this.active=false;this.hits=[];this.total=0;this.semantic={state:"disabled"};
            clearTimeout(this.timer);clearTimeout(this.refreshTimer);this.changed();return;
          }
          this.active=Boolean(this.requestedActive);
          if(this.active)this.refresh();else this.changed();
          return;
        }
        if (!this.active) return;
        this.semantic = payload;
        clearTimeout(this.refreshTimer);
        this.refreshTimer = setTimeout(() => {
          this.changed(); if (this.text && payload.encoder === "ready") this.request(true, true, false, Math.max(this.limit, this.hits.length));
        }, 250);
      }).then((stop) => this.unlisten.push(stop));
    }
    tauri.event.listen("model", ({ payload }) => {
      // A purpose query made while the download was pending needs a new semantic phase after readiness.
      if (payload.state === "ready" && this.active && this.text) this.refresh();
    }).then((stop) => this.unlisten.push(stop));
  }
  begin(text, active) {
    this.epoch++; clearTimeout(this.timer); clearTimeout(this.refreshTimer);
    this.text = text; this.requestedActive=active && Apps.supported;this.active=this.requestedActive && Apps.enabled; this.hits = []; this.total = 0; this.offset = 0;
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
      const page = (offset, limit) => invoke("search_apps", { q: this.text, meaning, generation: epoch, limit, offset, passive,
        anchorId: passive && !append ? this.selected?.() : null });
      const reply = await page(append ? this.hits.length : 0, this.limit);
      if (epoch !== this.epoch || reply.generation !== epoch) return;
      if (append && this.catalog.revision && reply.catalog?.revision !== this.catalog.revision) { this.refresh(); return; }
      const hits = reply.hits || [];
      const anchored = !append && passive && Number.isInteger(reply.anchorOffset)
        ? Math.min(20_100,Math.max(wanted,Math.ceil((reply.anchorOffset+1)/this.limit)*this.limit)) : wanted;
      while (!append && hits.length < anchored && hits.length < reply.total) {
        const next = await page(hits.length, Math.min(this.limit, anchored - hits.length));
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
      if(!Apps.enabled){this.active=false;clearTimeout(this.timer);clearTimeout(this.refreshTimer);}
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
    if (this.semantic.state === "unavailable") return "Name search available · Purpose matching unavailable";
    if (this.semantic.state === "preparing" && this.text) return "Name search available · Purpose matching preparing";
    if (this.catalog.refreshing) return "Refreshing installed applications…";
    return `${this.total} ${this.total === 1 ? "application" : "applications"}`;
  }
  purposeLabel() {
    return this.semantic.state === "disabled" ? "Purpose matching off" : this.semantic.state === "ready" ? "Purpose matching ready"
      : this.semantic.state === "unavailable" ? "Purpose matching unavailable" : "Purpose matching preparing";
  }
}
