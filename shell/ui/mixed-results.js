"use strict";

const MixedResults = {
  version: 1,
  normalize(text) {
    return String(text ?? "").normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase()
      .replace(/ß/g, "ss").replace(/ς/g, "σ").replace(/\u200b/g, " ")
      .replace(/[\u00ad\u061c\u0640\u200c-\u200f\u202a-\u202e\u2066-\u2069\ufeff]/g, "")
      .replace(/\s+/gu, " ").trim();
  },
  tokens(text) { return this.normalize(text).match(/[\p{L}\p{N}]+/gu) || []; },
  source(hit) {
    return hit.resultType === "application" ? "apps" : hit.resultType === "windows_setting" ? "settings" : "files";
  },
  key(hit) { return this.source(hit) === "files" ? "file:" + hit.path : hit.id; },
  title(hit) { return this.source(hit) === "files" ? String(hit.path).split(/[\\/]/).pop() : hit.name; },
  nameTier(query, candidates) {
    if (!query) return 4;
    const words = this.tokens(query);
    let tier = 4;
    for (const value of candidates) {
      const name = this.normalize(value);
      if (!name) continue;
      if (name === query) return 0;
      const parts = this.tokens(name);
      if (name.startsWith(query) || (words.length && words.every(word => parts.some(part => part.startsWith(word))))) {
        tier = Math.min(tier, 1);
      } else if (query.length >= 2 && (name.includes(query) || parts.map(part => [...part][0]).join("").startsWith(query))) {
        tier = Math.min(tier, 2);
      }
    }
    return tier;
  },
  tier(hit, text) {
    const query = this.normalize(text), source = this.source(hit);
    if (source !== "files") {
      const native = {exact: 0, prefix: 1, substring: 2, fuzzy: 3}[hit.reason];
      if (native != null) return native;
      // Semantic receipts have passed their provider's gate; they do not acquire name evidence here.
      if (hit.reason === "semantic") return 4;
      return this.nameTier(query, [hit.name, ...(hit.aliases || [])]);
    }
    const name = this.title(hit);
    return this.nameTier(query, [name, name.replace(/\.[^.]+$/, "")]);
  },
  compareHeads(a, b) {
    return a.tier - b.tier || (a.title < b.title ? -1 : a.title > b.title ? 1 : 0)
      || (a.key < b.key ? -1 : a.key > b.key ? 1 : 0);
  },
  compose({text = "", mode = "all", files = [], apps = [], settings = [], preference = "smart", includeEmptyFiles = false} = {}) {
    const unique = hits => {
      const seen = new Set();
      return hits.filter(hit => { const key = this.key(hit); if (seen.has(key)) return false; seen.add(key); return true; });
    };
    files = unique(files); apps = unique(apps); settings = unique(settings);
    if (mode !== "all" || !text.trim()) {
      const source = mode === "apps" ? "apps" : mode === "settings" ? "settings" : "files";
      const hits = source === "apps" ? apps : source === "settings" ? settings : files;
      return {best: [], sections: [{source, hits}], rows: hits};
    }
    if (preference === "apps-only") apps = [];
    apps = apps.slice(0, 3); settings = settings.slice(0, 2);
    const inputs = {files, apps, settings}, queues = [], best = [], selected = new Set();
    for (const [source, hits] of Object.entries(inputs)) {
      if (source === "apps" && preference === "files-first") continue;
      const entries = hits.map((hit, rank) => ({
        hit, rank, source, tier: this.tier(hit, text), title: this.normalize(this.title(hit)), key: this.key(hit),
      })).sort((a, b) => a.tier - b.tier || a.rank - b.rank);
      if (entries.length) queues.push(entries);
    }
    // Only match classes are shared. Provider scores and provider order remain local.
    while (best.length < 5 && queues.some(queue => queue.length)) {
      const next = queues.filter(queue => queue.length).sort((a, b) => this.compareHeads(a[0], b[0]))[0];
      const entry = next.shift();
      best.push(entry.hit); selected.add(entry.key);
    }
    const sections = Object.entries(inputs).map(([source, hits]) => ({
      source, hits: hits.filter(hit => !selected.has(this.key(hit))),
    })).filter(section => section.hits.length || (section.source === "files" && includeEmptyFiles));
    const head = section => {
      const entries = section.hits.map((hit, rank) => ({
        tier: this.tier(hit, text), rank, title: this.normalize(this.title(hit)), key: this.key(hit),
      })).sort((a, b) => a.tier - b.tier || a.rank - b.rank);
      return entries[0] || {tier: 5, title: "", key: ""};
    };
    sections.sort((a, b) => this.compareHeads(head(a), head(b)));
    if (preference === "files-first") {
      const appIndex = sections.findIndex(section => section.source === "apps");
      if (appIndex >= 0) {
        const [appSection] = sections.splice(appIndex, 1);
        sections.push(appSection);
      }
    }
    return {best, sections, rows: [...best, ...sections.flatMap(section => section.hits)]};
  },
};

if (typeof module !== "undefined" && module.exports) module.exports = MixedResults;
