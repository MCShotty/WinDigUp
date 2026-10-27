// What a search result says, for the panel and the window of DigUp's Windows and Linux shell: its place ("p. 3",
// "0:06"), why it matched, its details line, where it is, and the pictures the helper renders for it. The Mac app's
// Results.swift and Previews.swift are the reference for the words.
"use strict";

const tauri = window.__TAURI__;
const invoke = (command, args) => tauri.core.invoke(command, args);
const ask = async (request) => invoke("ask", { request:{...request,session_id:await SearchTiming.session} });
// Input-to-render duration is measured here; helper durations have their own monotonic origin.
const SearchTiming = {
  session:invoke("search_session").then(value=>Number.isSafeInteger(value)?value:0).catch(()=>0),
  generation: 0, input: 0, nextId: 0,
  begin(generation) { this.generation = generation; this.input = performance.now(); },
  async measure(phase, action, passive=false) {
    const generation=this.generation,input=this.input,start=performance.now(),requestId=++this.nextId;
    const reply=await action();const received=performance.now();
    if(!passive&&reply?.status!=="superseded")requestAnimationFrame(()=>requestAnimationFrame(()=>{
      if(generation!==this.generation)return;
      const end=performance.now(),ms=(reply?.ms&&typeof reply.ms==="object"?reply.ms:
        (phase==="app_purpose"||phase==="settings_purpose")&&reply?.semantic?.ms&&typeof reply.semantic.ms==="object"?reply.semantic.ms:{});
      const sample={...ms,phase,generation,requestId,total:end-input,roundtrip:received-start,debounce:start-input,
        render:end-received,native:typeof reply?.ms==="number"?reply.ms:undefined,
        nativeRequestId:reply?.id??((phase==="app_purpose"||phase==="settings_purpose")?reply?.semantic?.id:undefined),
        cacheHit:ms.cache_hit===true,semantic:reply?.meaning===true||reply?.semantic?.meaning===true};
      invoke("record_search_timing",{sample}).catch(()=>{});
      window.dispatchEvent(new CustomEvent("digup-search-timing",{detail:sample}));
    }));
    return reply;
  },
};
const fileURL = (path) => tauri.core.convertFileSrc(path);

const isMac = /Mac/.test(navigator.platform);
const isWindows = /Win/.test(navigator.platform);
const isLinux = /Linux/.test(navigator.platform);
const MOD = isMac ? "⌘" : "Ctrl+";
const FILE_MANAGER = isMac ? "Finder" : isWindows ? "Explorer" : "Files";
// Pictures every web view shows as they are; anything else (HEIC, TIFF, RAW…) comes as JPEG from the helper.
const SHOWN_AS_IS = new Set(["jpg", "jpeg", "png", "gif", "webp", "bmp"]);
const GROUP_OF = { screenshot: "Screenshots", image: "Images", pdf: "Documents", doc: "Documents", video: "Video",
                   audio: "Audio", code: "Code" };
const KIND_TITLE = { screenshot: "Screenshot", image: "Image", pdf: "PDF", doc: "Document", audio: "Audio",
                     video: "Video", code: "Code" };

/// The home folder, for "~/Pictures" (filled in as the page starts).
let homeFolder = "";
tauri.path.homeDir().then((home) => { homeFolder = home.replace(/[\\/]$/, ""); }).catch(() => {});

/// The page or moment that matched, as a badge: "p. 3", "0:06", "♪ 0:25" (a video's sound), "L12–40" (code).
function placeOf(hit) {
  if (hit.loc == null) return null;
  switch (hit.segment) {
    case "page":
    case "page_image": return `p. ${Math.trunc(hit.loc)}`;
    case "frame": return clock(hit.loc);
    case "audio": return hit.kind === "video" ? `♪ ${clock(hit.loc)}` : clock(hit.loc);
    case "lines": {
      const first = Math.trunc(hit.loc), last = Math.trunc(hit.loc_end ?? hit.loc);
      return first === last ? `L${first}` : `L${first}–${last}`;
    }
    case "cells": return span(hit);
    default: return null;
  }
}

/// Opens a result: code in the editor at its line, a PDF at its page and a recording or video at its moment in their
/// default apps (where those apps can be told), anything else plainly.
function openResult(hit) {
  if (isSetting(hit)) return WindowsSettings.open(hit);
  if (isApp(hit)) return Apps.launch(hit);
  if (hit.kind === "code") return invoke("open_code", { path: hit.path, line: codeLine(hit) });
  return invoke("open_path", { path: hit.path, ...placeToOpen(hit) });
}

/// Ctrl+C on a result: the file, to paste elsewhere; but text selected in the page, or in the field before the arrows or
/// a click chose a result (`navigated`), is copied as text. True when it took the keys.
function copyResult(event, hit, navigated) {
  if (isLauncher(hit)) return false;
  const field = document.activeElement;
  const fieldText = field?.selectionStart != null && field.selectionStart !== field.selectionEnd;
  // (WebKit may count the field's selected text in the page's.)
  const textSelected = fieldText ? !navigated : Boolean(window.getSelection()?.toString());
  if (!hit || textSelected) return false;
  event.preventDefault();
  invoke("copy_file", { path: hit.path }).catch(() => {});
  return true;
}

/// Where a result opens: a PDF's page past the first, a recording's or video's moment past its first second (the Mac
/// app's Moments).
function placeToOpen(hit) {
  if (hit.kind === "pdf" && (hit.segment === "page" || hit.segment === "page_image") && hit.loc > 1) {
    return { page: Math.trunc(hit.loc) };
  }
  if ((hit.kind === "video" || hit.kind === "audio") && (hit.segment === "frame" || hit.segment === "audio")
      && hit.loc >= 1) {
    return { seconds: hit.loc };
  }
  return {};
}

/// The line a code result opens at in an editor: where its stretch of lines is about (the definition a name points
/// to), else its first line; a notebook at its top (the Mac app's Moments).
function codeLine(hit) {
  return hit.segment === "lines" ? Math.max(1, Math.trunc(hit.focus ?? hit.loc ?? 1)) : 1;
}

/// The lines (or a notebook's cells) of code that matched: "lines 12–40", "cell 3".
function span(hit) {
  if (hit.loc == null) return null;
  const first = Math.trunc(hit.loc), last = Math.trunc(hit.loc_end ?? hit.loc);
  const what = hit.segment === "cells" ? ["cell", "cells"] : ["line", "lines"];
  return first === last ? `${what[0]} ${first}` : `${what[1]} ${first}–${last}`;
}

/// It matched by meaning (not only its words or name).
function matchedMeaning(hit) {
  return (hit.z ?? 0) >= 2;
}

/// Why it's here, in a few words: "Matches the picture", "Matches the frame at 0:06".
function reasonOf(hit) {
  if (isLauncher(hit)) return matchLabel(hit);
  const words = hit.keyword_rank != null;
  if (!matchedMeaning(hit)) return words ? "Has your words" : "Matches its name";
  const at = hit.loc != null ? clock(hit.loc) : "";
  const page = hit.loc != null ? `page ${Math.trunc(hit.loc)}` : "a page";
  switch (hit.segment) {
    case "image": return hit.kind === "screenshot" ? "Matches what's on screen" : "Matches the picture";
    case "ocr": return "Matches the text in it";
    case "frame": return `Matches the frame at ${at}`;
    case "audio": return hit.kind === "video" ? `Matches the sound at ${at}` : `Matches what's heard at ${at}`;
    case "page": return `Matches the text on ${page}`;
    case "page_image": return `Matches ${page}`;
    case "chunk": return "Matches its text";
    case "lines":
    case "cells": return `Matches ${span(hit) ?? "the code"}`;
    default: return "Matches its name";
  }
}

/// "Screenshot · Oct 7, 2026 · 1440 × 900 · 62 KB", "PDF · … · 463 pages, 120 read so far · 23 MB"
function details(hit) {
  const info = hit.info || {};
  const parts = [KIND_TITLE[hit.kind] || "File", dateOf(hit.modified)];
  if (info.width && info.height) parts.push(`${info.width} × ${info.height}`);
  const readTo = info.read_to != null ? Number(info.read_to) : null;
  if (info.pages) {
    const pages = Number(info.pages);
    parts.push((pages === 1 ? "1 page" : `${pages.toLocaleString()} pages`) + (readTo != null ? `, ${readTo} read so far` : ""));
  } else if (readTo != null) parts.push("partly read so far");
  if (info.lines) parts.push(Number(info.lines) === 1 ? "1 line" : `${Number(info.lines).toLocaleString()} lines`);
  if (info.duration) parts.push(clock(Number(info.duration)));
  if (hit.size > 0) parts.push(bytes(hit.size));
  return parts.join(" · ");
}

function nameOf(path) {
  return path.split(/[\\/]/).pop();
}

function extensionOf(path) {
  const name = nameOf(path);
  const dot = name.lastIndexOf(".");
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : "";
}

/// Where the file is: "~/Downloads/Screenshots"; code says where it is in its repo: "billing/payments".
function folderOf(hit) {
  if (isLauncher(hit)) return hit.publisher || "Application";
  const folder = hit.path.slice(0, Math.max(0, hit.path.search(/[\\/][^\\/]*$/)));
  const repo = hit.info?.repo;
  if (hit.kind === "code" && repo && hit.path.startsWith(repo + "/")) {
    return folder.slice(repo.slice(0, repo.search(/[\\/][^\\/]*$/)).length + 1);
  }
  const shown = homeFolder && folder.startsWith(homeFolder) ? "~" + folder.slice(homeFolder.length) : folder;
  return isWindows ? shown.replaceAll("/", "\\") : shown;
}

function clock(seconds) {
  const total = Math.trunc(seconds);
  const two = (n) => String(n).padStart(2, "0");
  return total >= 3600 ? `${Math.trunc(total / 3600)}:${two(Math.trunc(total / 60) % 60)}:${two(total % 60)}`
                       : `${Math.trunc(total / 60)}:${two(total % 60)}`;
}

function dateOf(seconds) {
  return new Date(seconds * 1000).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}

/// Sizes the way file managers count them (1 KB = 1,000 bytes): "62 KB", "2.1 MB".
function bytes(count) {
  if (count < 1000) return `${count} bytes`;
  const units = ["KB", "MB", "GB", "TB"];
  let value = count / 1000, unit = 0;
  while (value >= 1000 && unit < units.length - 1) { value /= 1000; unit += 1; }
  return `${value >= 10 || unit === 0 ? Math.round(value) : value.toFixed(1)} ${units[unit]}`;
}

/// An excerpt with the words keyword search found (marked « ») in bold.
function marked(excerpt) {
  return escaped(excerpt).replace(/«([^»]*)»/g, "<b>$1</b>");
}

/// The words keyword search found in an excerpt (marked « »).
function foundWords(excerpt) {
  return [...new Set([...(excerpt || "").matchAll(/«([^»]*)»/g)].map((found) => found[1]).filter(Boolean))];
}

/// The query's words, as the preview marks them.
function queryWords(query) {
  return [...new Set(query.toLowerCase().split(/[^\p{L}\p{N}_]+/u).filter((word) => word.length > 1))];
}

/// A passage with these words marked where they start a word.
function highlighted(text, query, more = []) {
  const words = [...new Set([...queryWords(query), ...more.map((word) => word.toLowerCase())])].filter((word) => word.length > 1);
  const html = escaped(text);
  if (!words.length) return html;
  const pattern = new RegExp(`(?<![\\p{L}\\p{N}])(${words.map((w) => escaped(w).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|")})`, "giu");
  return html.replace(pattern, "<mark>$1</mark>");
}

/// Up to ~900 characters of a document's passage, from just before the first of the words (the Mac app's Passage).
function passageAround(text, words) {
  const lower = text.toLowerCase();
  const first = Math.min(...words.map((word) => {
    const at = lower.indexOf(word.toLowerCase());
    return at < 0 ? Infinity : at;
  }));
  let start = 0;
  if (Number.isFinite(first) && first > 200) {
    start = first - 160;
    while (start < first && !/\s/.test(text[start])) start += 1;
  }
  const shown = text.slice(start, start + 900);
  return (start > 0 ? "…" : "") + shown + (text.length - start > 900 ? "…" : "");
}

/// Arabic or Hebrew text reads from the right.
function isRightToLeft(text) {
  const letter = text.match(/\p{L}/u)?.[0];
  return letter != null && /[֐-ࣿיִ-ﻼ]/.test(letter);
}

function escaped(text) {
  return text.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function kindIcon(kind) {
  const icon = element("div", "thumb icon");
  icon.innerHTML = ICONS[kind] || ICONS.doc;
  return icon;
}

/// The helper's JPEG of a page, a frame or a picture, asked for once per file and place.
const renders = new Map();
function rendered(path, kind, loc, pixels, foreground=false) {
  const key = `${path}|${kind}|${loc}|${pixels}`;
  const generation=SearchTiming.generation,previous=renders.get(key);
  if(previous&&(previous.done||(previous.generation===generation&&(previous.foreground||!foreground))))return previous.promise;
  const entry={generation,foreground,done:false};
  entry.promise=ask({ op: "render", path, kind, loc, pixels, generation, foreground }).then(reply=>{
    if(!reply.image){const error=new Error("Preview was superseded");error.superseded=reply.status==="superseded";throw error;}
    entry.done=true;return reply.image;
  }).catch(error=>{if(renders.get(key)===entry)renders.delete(key);throw error;});
  renders.set(key,entry);
  if(renders.size>256)renders.delete(renders.keys().next().value);
  return entry.promise;
}

/// What the helper renders for a result's picture: [kind, place], or null when it has none (documents, audio, code).
function renderOf(hit) {
  if (hit.kind === "image" || hit.kind === "screenshot") return ["image", null];
  if (hit.kind === "video") return ["video", hit.loc ?? 0.5];
  if (hit.kind === "pdf") return ["pdf", hit.segment === "page" || hit.segment === "page_image" ? hit.loc : 1];
  return null;
}

const ICONS = {
  chevron: '<svg class="chevron" viewBox="0 0 16 16" width="12" height="12"><path d="M6 3.5 L10.5 8 L6 12.5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  play: '<svg viewBox="0 0 20 20"><path d="M5 3 L17 10 L5 17 Z"/></svg>',
  pause: '<svg viewBox="0 0 20 20"><path d="M5 3 H8.5 V17 H5 Z M11.5 3 H15 V17 H11.5 Z"/></svg>',
  found: '<svg viewBox="0 0 24 24"><circle cx="10" cy="10" r="6.5"/><path d="M15 15 L20.5 20.5 M10 7 V13 M7 10 H13"/></svg>',
  words: '<svg viewBox="0 0 24 24"><path d="M4 18 L9 5 L14 18 M5.8 13.5 H12.2 M15.5 11.5 C16.4 10.3 19.8 10 20 12.5 V18 M20 14.5 C17 14 15 15 15.4 16.8 C15.9 18.6 19.2 18.2 20 16"/></svg>',
  doc: '<svg viewBox="0 0 24 24"><path d="M6 3 H14 L19 8 V21 H6 Z M14 3 V8 H19 M9 12 H16 M9 15 H16 M9 18 H13"/></svg>',
  pdf: '<svg viewBox="0 0 24 24"><path d="M6 3 H14 L19 8 V21 H6 Z M14 3 V8 H19 M9 13 H16 M9 16 H14"/></svg>',
  code: '<svg viewBox="0 0 24 24"><path d="M9 7 L4 12 L9 17 M15 7 L20 12 L15 17"/></svg>',
  audio: '<svg viewBox="0 0 24 24"><path d="M3 12 H5 M7 8 V16 M10 5 V19 M13 9 V15 M16 6 V18 M19 10 V14 M21 12 H22"/></svg>',
  video: '<svg viewBox="0 0 24 24"><path d="M4 6 H15 V18 H4 Z M15 10 L20 7 V17 L15 14"/></svg>',
  image: '<svg viewBox="0 0 24 24"><path d="M4 5 H20 V19 H4 Z M4 16 L9 11 L13 15 L16 12 L20 16"/></svg>',
  screenshot: '<svg viewBox="0 0 24 24"><path d="M4 8 V4 H8 M16 4 H20 V8 M20 16 V20 H16 M8 20 H4 V16 M9 12 A3 3 0 1 0 15 12 A3 3 0 1 0 9 12"/></svg>',
};

function matchLabel(hit) {
  const labels = {name:"Name match",alias:"Alias match",content:"Content match",purpose:"Purpose match"};
  if (labels[hit.matchSource]) return labels[hit.matchSource];
  if (isLauncher(hit)) return hit.reason === "semantic" ? "Purpose match" : "Name or alias match";
  return matchedMeaning(hit) || hit.keyword_rank != null ? "Content match" : "Name match";
}

function availabilityLabel(hit) {
  return !isLauncher(hit) && (hit.availability === "unknown" || hit.availability_stale === true)
    ? "Availability checked when opened" : "";
}

function appendUsefulResult(container, hit, fail) {
  if (!hit.feedbackToken) return;
  const button = element("button", "relevance-feedback", hit.usefulSaved ? "Feedback saved" : "Useful result");
  button.type = "button";
  button.disabled = hit.usefulSaved === true;
  button.setAttribute("aria-label", "Mark " + titleOf(hit) + " as a useful result");
  button.onclick = async event => {
    event.stopPropagation(); button.disabled = true;
    try {
      await invoke("useful_result", {token:hit.feedbackToken});
      hit.usefulSaved = true; button.textContent = "Feedback saved";
      button.setAttribute("aria-label", "Useful feedback saved for " + titleOf(hit));
    } catch (error) { button.disabled = false; fail(error); }
  };
  container.append(button);
}

// A refreshed name index can advance while the compatible vector snapshot is unchanged.
function mergeFileSearchReplies(semantic, lexical, text) {
  if (!semantic?.meaning) return {...semantic, ...lexical, meaning:false,
    ...(semantic?.semantic_error ? {semantic_error:semantic.semantic_error} : {})};
  const split = (reply,keep=()=>true) => {
    const hits=reply.hits || [], strong=Math.max(0,Math.min(reply.strong ?? hits.length,hits.length));
    const seen=new Set(),ranked=[],weaker=[];
    hits.forEach((hit,index)=>{
      const key=resultKey(hit);
      if(seen.has(key)||!keep(hit))return;
      seen.add(key);(index<strong?ranked:weaker).push(hit);
    });
    return [ranked,weaker];
  };
  const currentWords=new Set((lexical.hits || []).map(resultKey));
  const [ranked,weaker]=split(semantic,hit=>currentWords.has(resultKey(hit))||matchedMeaning(hit));
  const [words,weakWords]=split(lexical);
  const known=new Map([...ranked,...weaker].map(hit=>[resultKey(hit),hit]));
  const strongKeys=new Set(ranked.map(resultKey));
  const supplement=(target,hit) => {
    const tier=MixedResults.tier(hit,text), at=target.findIndex(current=>MixedResults.tier(current,text)>tier);
    target.splice(at<0?target.length:at,0,hit);
  };
  for(const hit of words) {
    const key=resultKey(hit);
    if(strongKeys.has(key))continue;
    const previous=known.get(key);
    if(previous)weaker.splice(weaker.findIndex(current=>resultKey(current)===key),1);
    supplement(ranked,previous || hit);strongKeys.add(key);known.set(key,previous || hit);
  }
  for(const hit of weakWords) {
    const key=resultKey(hit);if(known.has(key))continue;
    supplement(weaker,hit);known.set(key,hit);
  }
  const facets={};
  for(const hit of ranked)facets[hit.kind]=(facets[hit.kind] || 0)+1;
  return {...semantic, hits:[...ranked,...weaker], strong:ranked.length, facets, count_scope:"displayed_matches",
    exact_filename_known:lexical.exact_filename_known,exact_filename:lexical.exact_filename,
    category_query:lexical.category_query};
}
