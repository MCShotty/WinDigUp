// File and native launcher providers refine these rows independently. Visual and keyboard order share one plan.
"use strict";

const TYPING_PAUSE = 120;          // ms after the last keystroke until the meaning results show
const ROWS_PER_GROUP = 6;
const FIELD_HEIGHT = 64;
const PANEL_HEIGHT = 640;
const BIG_HEIGHT = 560;   // the panel at its tallest, for the big preview
const WEAKER = "\u0000weaker";     // the selectable row that folds and unfolds the weaker matches
// Wayland: the window fills the screen and this page places the panel (the shell's wayland.rs).
const fillsScreen = new URLSearchParams(location.search).has("fills");
// A group's name in the window's kind filters.
const FILTER_OF = { Screenshots: "screenshots", Images: "images", Documents: "documents", Video: "video",
                    Audio: "audio" };

const $ = (id) => document.getElementById(id);
const $panel = $("panel"), $query = $("query"), $body = $("body"), $list = $("list"), $preview = $("preview");
const $footer = $("footer"), $summary = $("summary"), $keys = $("keys"), $activity = $("activity");
const $moreResults = $("more-results"), $results = $("results"), $primary = $("primary-action"), $details = $("details-action");
const panelConfig = {maxHeight: PANEL_HEIGHT, nativeSized: false};
let layoutFrame = null, announceTimer = null, lastAnnouncement = "", statusTimer = null;

const state = {
  generation: 0,
  finalGeneration: -1,   // the generation whose meaning results are showing: late keyword results don't replace them
  timer: null,
  phase: "empty",        // empty | words | meaning | wordsOnly | codeHint
  hasCode: true,         // code search has folders (the state's hasCode)
  text: "",              // what was searched (without "code:")
  isCode: false,
  isApps: false,
  isSettings: false,
  strong: [],
  weaker: [],
  groups: [],
  showWeaker: false,
  selection: null,       // a result's path, or WEAKER
  navigated: false,      // the arrow keys moved the selection since the last edit
  encoder: "stopped",
  height: FIELD_HEIGHT,
  error: null,
  indexing: null,        // {done, total} while the index helper works through new files
  caveat: null,          // why results may be incomplete right now (the shell's status.rs)
};
let debugPending = false;
const applicationSearch = new ApplicationSearch((statusOnly=false) => {
  const ids = rowIDs();
  if (!state.navigated) state.selection = ids[0] ?? null;
  else if(!ids.includes(state.selection)){state.selection=null;state.chosen=null;}
  if(statusOnly){renderFooter();return;}
  render();
  if (debugPending && state.isApps && (applicationSearch.hits.length || !applicationSearch.catalog.refreshing)) report();
});

// MARK: Searching

function queryChanged() {
  if(state.composing)return;
  closeBig();
  clearTimeout(statusTimer); state.waitingVisible = false;
  statusTimer = setTimeout(() => { state.waitingVisible = true; renderFooter(); renderPreview(); scheduleFit(); }, 180);
  state.heightFloor = FIELD_HEIGHT; lastAnnouncement = "";
  const generation = ++state.generation;
  SearchTiming.begin(generation);state.lexicalReady=false;state.fileWords=[];state.categoryQuery=false;
  state.exactFilenameKnown=false;state.exactFilename=false;
  clearTimeout(state.timer);
  cancelAnimationFrame(state.frame);
  state.refine=null;
  state.navigated = false;
  state.chosen = null;
  state.error = null;
  const typed = $query.value.trim();
  const mode = Apps.parse(typed);
  const code = mode.code;
  const text = mode.text;
  if((mode.mode==="apps"||mode.mode==="settings"||!typed||(code&&!text))&&state.filesStarted){state.filesStarted=false;ask({op:"cancel",generation}).catch(()=>{});}
  state.isCode = code;
  state.isApps = mode.mode === "apps";
  state.isSettings=mode.mode==="settings";
  applicationSearch.limit=state.isApps?6:3;
  applicationSearch.begin(text, mode.apps && (Boolean(typed) || state.isApps),mode.mode);
  settingsSearch.begin(text,mode.settings&&(Boolean(typed)||state.isSettings),mode.mode);
  if(state.isSettings){show({hits:[],strong:0},text,"settings");return;}
  if (state.isApps) {
    show({ hits: [], strong: 0 }, text, "applications");
    return;
  }
  if (!typed || (code && !text)) {
    show({ hits: [], strong: 0 }, text, typed ? "codeHint" : "empty");
    return;
  }
  show({ hits: [], strong: 0 }, text, "words");
  // Words now. The last word is probably half-typed, so it matches as a prefix.
  state.filesStarted=true;
  state.refreshWords=(passive=false)=>SearchTiming.measure("file_words",()=>ask({ op: "search", q: text, code, meaning: false, prefix_last: true, limit: 40,generation,passive }),passive)
    .then((reply) => {
      if(generation!==state.generation||reply.status==="superseded")return;
      state.lexicalReady=true;state.fileWords=reply.hits||[];state.categoryQuery=reply.category_query===true;
      state.exactFilenameKnown=reply.exact_filename_known!==false;state.exactFilename=reply.exact_filename===true;
      if(state.finalGeneration!==generation)show(reply,text,"words");else applicationSearch.changed();
    })
    .catch(error => { if (generation === state.generation && state.finalGeneration !== generation) failed(error); });
  state.frame=requestAnimationFrame(()=>state.refreshWords());
  // Submit meaning only after typing pauses; current-query words remain available meanwhile.
  state.refine = (passive=false) => {
    SearchTiming.measure("file_meaning",()=>ask({ op: "search", q: text, code, meaning: true, limit: 40,generation,passive }),passive)
      .then((reply) => {
        if (generation !== state.generation||reply.status==="superseded") return;
        state.finalGeneration = generation;
        if(reply.semantic_error)state.error=reply.semantic_error;
        show(reply, text, reply.meaning ? "meaning" : "wordsOnly");
        if (debugPending) report();
      })
      .catch(error => { if (generation === state.generation) failed(error); });
  };
  state.timer=setTimeout(state.refine,TYPING_PAUSE);
}

function show(reply, text, phase) {
  const hits = reply.hits || [];
  const strong = Math.min(reply.strong ?? hits.length, hits.length);
  state.text = text;
  state.phase = phase;
  state.strong = hits.slice(0, strong);
  state.weaker = hits.slice(strong);
  const visible = state.strong.slice(0, ROWS_PER_GROUP * 3);
  state.groups = visible.length ? [{title: state.isCode ? "Code" : "Files", rows: visible, total: state.strong.length}] : [];
  if (!state.navigated) state.showWeaker = false;
  // Follow the top hit until you pick something with the arrow keys.
  const ids = rowIDs();
  if (!state.navigated) state.selection = ids[0] ?? null;
  else if(!ids.includes(state.selection)){state.selection=null;state.chosen=null;}
  render();
}

function failed(error) {
  state.error = String(error);
  if(!state.navigated)state.selection=rowIDs()[0]??null;
  render();
}

const settingsSearch=new WindowsSettingsSearch((statusOnly=false)=>{
  const ids=rowIDs();
  if(!state.navigated)state.selection = ids[0] ?? null;
  else if(!ids.includes(state.selection)){state.selection=null;state.chosen=null;}
  if(statusOnly)renderFooter();else render();
});
function resultLayout() {
  return MixedResults.compose({
    text: state.text, mode: state.isApps ? "apps" : state.isSettings ? "settings" : state.isCode || !Apps.supported ? "files" : "all",
    files: [...state.groups.flatMap(group => group.rows),
      ...state.weaker.filter(hit => !state.isApps && !state.isSettings && !state.isCode && MixedResults.tier(hit, state.text) <= 1)], apps: applicationSearch.active ? applicationSearch.hits : [],
    settings: settingsSearch.visible(), preference: Apps.mixedSearch, includeEmptyFiles: state.weaker.length > 0,
  });
}
function rowIDs() {
  const layout = resultLayout(), ids = layout.best.map(resultKey);
  for (const section of layout.sections) {
    ids.push(...section.hits.map(resultKey));
    if (section.source === "files" && weakerFiles(layout).length) {
      ids.push(WEAKER);
      if (state.showWeaker) ids.push(...weakerFiles(layout).map(resultKey));
    }
  }
  return ids;
}

function weakerFiles(layout = resultLayout()) {
  const shown = new Set(layout.rows.map(resultKey));
  return state.weaker.filter(hit => !shown.has(resultKey(hit)));
}

function selectedHit() {
  const current=rawSelectedHit();
  return current&&state.navigated&&state.chosen&&resultKey(state.chosen)===state.selection?state.chosen:current;
}
function rawSelectedHit(){return [...applicationSearch.hits,...settingsSearch.visible(),...state.strong,...state.weaker].find(hit=>resultKey(hit)===state.selection)??null;}

function move(step) {
  const ids = rowIDs();
  if (!ids.length) return;
  const index = ids.indexOf(state.selection);
  state.selection = ids[Math.max(0, Math.min(ids.length - 1, (index < 0 ? -1 : index) + step))];
  state.chosen=rawSelectedHit();
  state.navigated = true;
  render();
}

function toggleWeaker() {
  state.showWeaker = !state.showWeaker;
  state.selection = WEAKER;
  render();
}

function openSelected() {
  const hit = selectedHit();
  if (hit){state.navigated = true;state.chosen=hit;}
  if (hit) openResult(hit).catch(failed);
}

function revealSelected() {
  const hit = selectedHit();
  if (isLauncher(hit)) { if (hit.shortcut) invoke("reveal", { path: hit.shortcut }).catch(failed); return; }
  if (hit) invoke("reveal", { path: hit.path }).catch(failed);
}

/// The same search in the window, for a bigger look (only one kind, if given).
function openInWindow(kind) {
  invoke("open_window", { query: $query.value.trim(), kind: kind ?? null, selected: state.selection === WEAKER ? null : state.selection }).catch(failed);
}

// MARK: Drawing

/// The panel's height: the window's, or in a window that fills the screen the panel's own, whose place the shell is
/// told so that only the panel takes the pointer.
function acceptConfig(reply) {
  if (!reply || typeof reply !== "object") return;
  if (Number.isFinite(reply.maxHeight) && reply.maxHeight > 0) panelConfig.maxHeight = reply.maxHeight;
  if (reply.nativeSized === true) panelConfig.nativeSized = true;
  if (reply.material) AppearanceUI.applyPanel(reply.material);
}
function fit() {
  $panel.style.height = state.height + "px";
  if (!fillsScreen) {
    invoke("panel_height", {height: state.height}).then(reply => {
      const old = panelConfig.maxHeight; acceptConfig(reply);
      if (old !== panelConfig.maxHeight) scheduleFit();
    }).catch(() => {});
    return;
  }
  const {left, top, width, height} = $panel.getBoundingClientRect();
  invoke("panel_area", {x:left, y:top, width, height}).catch(() => {});
}
function scheduleFit() {
  if (layoutFrame !== null) return;
  layoutFrame = requestAnimationFrame(() => {
    layoutFrame = null;
    const empty = state.phase === "empty", count = rowIDs().length;
    const measured = FIELD_HEIGHT + $footer.getBoundingClientRect().height
      + (count ? $list.scrollHeight + $moreResults.getBoundingClientRect().height : 104);
    let height = empty ? FIELD_HEIGHT : !$big.hidden ? BIG_HEIGHT : measured;
    // Keep a list steady while replies refine it; a new query can choose a new height.
    if (!empty && $big.hidden && count) {
      state.heightFloor = Math.max(state.heightFloor || FIELD_HEIGHT, height);
      height = state.heightFloor;
    }
    const screenLimit = fillsScreen ? window.innerHeight * 0.8 - 16
      : panelConfig.nativeSized ? panelConfig.maxHeight : window.innerHeight;
    height = Math.round(Math.min(Math.max(FIELD_HEIGHT, height), panelConfig.maxHeight, Math.max(FIELD_HEIGHT, screenLimit)));
    if (height !== state.height) { state.height = height; fit(); }
  });
}
if (fillsScreen) document.documentElement.classList.add("fills-screen");
window.addEventListener("resize", scheduleFit);
tauri.event.listen("panel-geometry", () => invoke("panel_config").then(reply => {acceptConfig(reply); scheduleFit();}).catch(() => {}));
invoke("panel_config").then(reply => {acceptConfig(reply); scheduleFit();}).catch(() => {});

function announceResults() {
  clearTimeout(announceTimer);
  const count = rowIDs().filter(id => id !== WEAKER).length;
  const text = state.phase === "empty" ? "" : state.error && !count ? "Search unavailable. Open Activity for details."
    : count ? count + (count === 1 ? " result available." : " results available.")
    : state.waitingVisible && state.phase === "words" ? "Searching." : "";
  if (text === lastAnnouncement) return;
  announceTimer = setTimeout(() => { $("announcer").textContent = text; lastAnnouncement = text; }, 250);
}
function syncSelection() {
  if (!$big.hidden) { $query.removeAttribute("aria-activedescendant"); return; }
  for (const node of $list.querySelectorAll('[role="option"]')) {
    const key = node.dataset.resultKey || (node.classList.contains("weaker") ? WEAKER : "");
    node.id = "panel-option-" + encodeURIComponent(key);
  }
  const selected = $list.querySelector('[role="option"][aria-selected="true"]');
  if (selected) $query.setAttribute("aria-activedescendant", selected.id);
  else $query.removeAttribute("aria-activedescendant");
}
function render() {
  const empty = state.phase === "empty";
  $panel.dataset.state = empty ? "empty" : "results";
  $panel.classList.toggle("previewing", !$big.hidden);
  $query.setAttribute("aria-expanded", String(!empty && $big.hidden));
  $details.setAttribute("aria-expanded", String(!$big.hidden));
  $body.hidden = empty;
  $footer.hidden = empty;
  if (!empty) { renderList(); renderPreview(); renderFooter(); syncSelection(); }
  else { $query.removeAttribute("aria-activedescendant"); $activity.hidden = true; }
  announceResults(); scheduleFit();
}

const sectionNodes = new Map(), extraNodes = new Map();
function reconcile(parent, nodes) {
  let next = parent.firstChild;
  for (const node of nodes) {
    if (node !== next) parent.insertBefore(node, next);
    next = node.nextSibling;
  }
  while (next) { const old = next; next = next.nextSibling; old.remove(); }
}
function extra(key, text, action) {
  let node = extraNodes.get(key);
  if (!node) { node = element("button", "app-more"); node.type = "button"; extraNodes.set(key, node); }
  node.textContent = text; node.onclick = action; return node;
}
function renderList() {
  thumbnailObserver.disconnect();
  const scroll = $list.scrollTop, layout = resultLayout(), weaker = weakerFiles(layout), sections = [], more = [];
  $list.hidden = !layout.rows.length && !state.weaker.length;
  $results.hidden = $list.hidden;
  const appendHits = (hits, title, best = false) => {
    const key = best ? "best" : title;
    let section = sectionNodes.get(key);
    if (!section) {
      section = element("section", "panel-result-group" + (best ? " best-matches" : ""));
      section.setAttribute("role", "group"); section.setAttribute("aria-label", title);
      section.heading = element("div", "group-title", title); sectionNodes.set(key, section);
    }
    const nodes = [section.heading, ...hits.map(hit => isLauncher(hit) ? Apps.row(hit, state.selection === resultKey(hit), key => {
      state.selection = key; state.chosen = rawSelectedHit(); state.navigated = true; render();
    }, hit => openResult(hit).catch(failed)) : row(hit))];
    sections.push(section); return {section, nodes};
  };
  const groups = [];
  if (layout.best.length) groups.push(appendHits(layout.best, "Best matches", true));
  for (const section of layout.sections) {
    const title = section.source === "apps" ? "Apps" : section.source === "settings" ? "Windows settings" : state.isCode ? "Code" : "Files";
    const group = appendHits(section.hits, title); groups.push(group);
    if (section.source === "files") {
      if (state.strong.length > state.groups.flatMap(group => group.rows).length)
        more.push(extra("files", "Show all matching files", () => openInWindow()));
      if (weaker.length) {
        let fold = extraNodes.get("weaker");
        if (!fold) { fold = element("div", "weaker"); fold.innerHTML = ICONS.chevron; fold.label = element("span"); fold.append(fold.label); extraNodes.set("weaker", fold); }
        fold.classList.toggle("open", state.showWeaker); fold.classList.toggle("selected", state.selection === WEAKER);
        fold.setAttribute("role", "option"); fold.setAttribute("aria-selected", String(state.selection === WEAKER));
        fold.label.textContent = state.showWeaker ? "Weaker matches" : weaker.length + " weaker matches";
        fold.onclick = toggleWeaker; group.nodes.push(fold);
        if (state.showWeaker) for (const hit of weaker) group.nodes.push(row(hit));
      }
    }
  }
  if (applicationSearch.active && applicationSearch.total > layout.rows.filter(isApp).length)
    more.push(extra("apps", "Show all " + applicationSearch.total + " matching apps", () => openInWindow("apps")));
  if (settingsSearch.active && settingsSearch.total > layout.rows.filter(isSetting).length)
    more.push(extra("settings", "Show all matching Windows settings", () => openInWindow("settings")));
  for (const {section, nodes} of groups) reconcile(section, nodes);
  reconcile($list, sections); reconcile($moreResults, more); $moreResults.hidden = !more.length;
  for (const image of $list.querySelectorAll("img.thumb")) if (!image.thumbnailStarted) thumbnailObserver.observe(image);
  $list.scrollTop = scroll;
  if (state.navigated) $list.querySelector(".selected")?.scrollIntoView({block: "nearest"});
}

const fileRows = new Map();
function row(hit) {
  const key = resultKey(hit), signature = JSON.stringify(hit), previous = fileRows.get(key);
  if (previous?.signature === signature) {
    previous.node.classList.toggle("selected", state.selection === key);
    previous.node.setAttribute("aria-selected", String(state.selection === key));
    return previous.node;
  }
  const item = element("div", "row" + (state.selection === resultKey(hit) ? " selected" : ""));
  item.setAttribute("role", "option"); item.setAttribute("aria-selected", String(state.selection === key));
  item.dataset.resultKey = key;
  item.setAttribute("aria-label", (KIND_TITLE[hit.kind] || "File") + ", " + nameOf(hit.path));
  item.append(thumbnail(hit));
  const text = element("div", "row-text");
  const title = element("div", "row-title");
  title.append(element("span", "name", nameOf(hit.path)));
  const place = placeOf(hit);
  if (place) title.append(element("span", "badge", place));
  const sub = element("div", "row-sub");
  // The words found, where keyword search found them; else where the file is.
  if (hit.excerpt && hit.excerpt.includes("«")) sub.innerHTML = marked(hit.excerpt);
  else sub.textContent = folderOf(hit);
  text.append(title, sub);
  item.append(text);
  item.onmousedown = event => { if (event.button === 0) event.preventDefault(); };
  item.onclick = () => {
    state.selection = resultKey(hit);
    state.chosen=hit;
    state.navigated = true;
    render();
  };
  item.ondblclick = openSelected;
  fileRows.set(key, {signature, node: item});
  if (fileRows.size > 100) fileRows.delete(fileRows.keys().next().value);
  return item;
}

/// A picture of the file for its row: the picture itself, a video's frame at the moment, a PDF's page; else its
/// kind's icon. All come small from the helper (a full-size photo per row would cost the web view hundreds of MB).
const thumbnailObserver = new IntersectionObserver(entries => {
  for (const entry of entries) if (entry.isIntersecting) {
    thumbnailObserver.unobserve(entry.target); entry.target.thumbnailStarted = true; entry.target.loadThumbnail?.();
  }
}, {root: $list, rootMargin: "60px"});
function thumbnail(hit) {
  const pixels = Math.round(36 * (window.devicePixelRatio || 1));
  const what = renderOf(hit);
  if (!what) return kindIcon(hit.kind);
  const image = element("img", "thumb");
  image.alt = "";
  image.loading = "lazy"; image.decoding = "async";
  thumbnailObserver.observe(image);
  image.loadThumbnail = () => rendered(hit.path, what[0], what[1], pixels)
    .then(path => { image.src = fileURL(path); })
    .catch(() => image.replaceWith(kindIcon(hit.kind)));
  return image;
}

let previewSignature=null;
function renderPreview() {
  const hasResults = rowIDs().length > 0;
  $preview.hidden = hasResults;
  if (hasResults) return;
  const signature=JSON.stringify([state.selection,state.text,selectedHit(),state.phase,state.isApps,state.waitingVisible,state.error,state.indexing]);
  if(signature===previewSignature)return;
  previewSignature=signature;
  $preview.replaceChildren();
  if (state.error) { $preview.append(message("Search needs attention", "Open Activity for details. Available app and settings matches remain usable.")); return; }
  if (!state.strong.length && !state.weaker.length && !applicationSearch.hits.length && !settingsSearch.visible().length) {
    if(state.isSettings){$preview.append(message("Windows settings",settingsSearch.status()));return;}
    if (state.isApps) {
      $preview.append(message("Applications", applicationSearch.status()));
      return;
    }
    if (state.isCode && !state.hasCode) {
      $preview.append(message("Code search is off", "Choose folders with code in Settings → Code, and DigUp finds "
        + "code by what it does."));
    } else if (state.phase === "codeHint") {
      $preview.append(message("Search your code", "Say what the code does, or type a name that's in it."));
    } else if (state.phase === "words") {
      // The words are in and the meaning results on their way (as on the Mac): no verdict yet.
      const box = element("div", "message");
      box.append(element("span", "", state.waitingVisible ? "Searching…" : ""));
      $preview.append(box);
    } else if (state.indexing) {
      const { done, total } = state.indexing;
      $preview.append(message("Nothing yet", Number.isFinite(total) ? `Still indexing (${done} of ${total} files). Until a file is read, `
        + "DigUp finds it only by its name." : "Files are still being prepared. App names and Windows settings are available."));
    } else if (state.isCode) {
      $preview.append(message("No good matches in your code", "Try saying what the code does, or a name that's in it."));
    } else {
      $preview.append(message("No good matches", "Try what you'd see or hear in it, or words you remember from it."));
    }
    return;
  }
  if (state.selection === WEAKER) {
    const count = state.weaker.length;
    $preview.append(message(state.showWeaker ? "Weaker matches" : `${count} weaker ${count === 1 ? "match" : "matches"}`,
      "They match much less well than the results above. Press Return to " + (state.showWeaker ? "fold them away." : "show them.")));
    return;
  }
  const hit = selectedHit();
  if (!hit) return;
  if (isLauncher(hit)) { $preview.append(Apps.details(hit, failed)); return; }
  $preview.append(picture(hit), facts(hit));
}

/// The big picture: the photo or screenshot, the frame at the moment (it plays from there), the page, what's heard
/// at the moment, or the passage that matched.
function picture(hit) {
  const frame = element("div", "picture");
  const image = element("img");
  image.alt = "";
  frame.append(image);
  switch (hit.kind) {
    case "image":
    case "screenshot":
      if (SHOWN_AS_IS.has(extensionOf(hit.path))) image.src = fileURL(hit.path);
      else rendered(hit.path, "image", null, 1024, true).then((path) => { image.src = fileURL(path); }).catch(() => {});
      return frame;
    case "pdf":
      rendered(hit.path, "pdf", hit.loc ?? 1, 1024, true).then((path) => { image.src = fileURL(path); }).catch(() => {});
      return frame;
    case "video": {
      // The frame at the moment, its time on it; a click plays the video from there.
      const at = hit.loc ?? 0;
      rendered(hit.path, "video", at, 1024, true).then((path) => { image.src = fileURL(path); }).catch(() => {});
      const moment = element("div", "moment");
      const play = element("div", "play");
      play.innerHTML = ICONS.play;
      moment.append(image, play, element("span", "at", clock(at)));
      frame.replaceChildren(moment);
      frame.onclick = () => {
        const video = element("video");
        video.src = `${fileURL(hit.path)}#t=${at}`;
        video.controls = true;
        video.autoplay = true;
        frame.replaceChildren(video);
      };
      return frame;
    }
    case "audio": {
      const audio = element("div", "audio-picture");
      audio.innerHTML = ICONS.audio;
      const player = element("audio");
      player.src = `${fileURL(hit.path)}#t=${hit.loc ?? 0}`;
      player.controls = true;
      player.preload = "metadata";
      audio.append(player);
      frame.replaceChildren(audio);
      return frame;
    }
    default: {
      const passage = element("div", "passage" + (hit.kind === "code" ? " code" : ""));
      passage.textContent = (hit.excerpt ?? "").replace(/[«»]/g, "");
      ask({ op: "text", segment: hit.segment_id, code: state.isCode })
        .then((reply) => { if (reply.text) passage.innerHTML = highlighted(reply.text, state.text); })
        .catch(() => {});
      return passage;
    }
  }
}

function facts(hit) {
  const box = element("div", "facts");
  box.append(element("div", "title", nameOf(hit.path)), element("div", "line", folderOf(hit)),
             element("div", "line", details(hit)));
  const reason = element("div", "reason");
  reason.innerHTML = ICONS.found;
  reason.append(element("span", "", reasonOf(hit)));
  box.append(reason);
  if (hit.excerpt && hit.excerpt.includes("«") && hit.kind !== "doc" && hit.kind !== "code") {
    const words = element("div", "reason-text");
    words.innerHTML = marked(hit.excerpt);
    box.append(words);
  }
  const buttons = element("div", "buttons");
  const open = element("button", "", "Open");
  open.onclick = openSelected;
  const reveal = element("button", "", `Show in ${FILE_MANAGER}`);
  reveal.onclick = revealSelected;
  buttons.append(open, reveal);
  box.append(buttons);
  return box;
}

function renderFooter() {
  const weaker = weakerFiles().length, strong = state.strong.length + state.weaker.length - weaker;
  let summary;
  if (state.error) summary = `DigUp: ${state.error}`;
  else if(state.isSettings)summary=settingsSearch.status();
  else if (state.isApps) summary = applicationSearch.status();
  else if (state.phase === "words") {
    summary = !state.waitingVisible ? "" : state.encoder === "starting" ? "Loading purpose and content search…" : "Searching contents…";
  } else if (state.phase === "wordsOnly") summary = "Words only: meaning search isn't available";
  else if (state.phase === "codeHint") summary = "Searching your code";
  // Results while indexing (or before the model is in) may be missing some: that, where they're counted.
  else if (state.caveat && !state.isCode) summary = state.caveat;
  else summary = `${strong} ${strong === 1 ? "result" : "results"}` + (weaker ? ` · ${weaker} weaker` : "");
  if(!state.isApps&&!state.isSettings&&!state.isCode){
    const native=[];
    if(applicationSearch.active&&applicationSearch.total)native.push(applicationSearch.total+" "+(applicationSearch.total===1?"app":"apps"));
    if(settingsSearch.active&&settingsSearch.total)native.push(settingsSearch.total+" Windows "+(settingsSearch.total===1?"setting":"settings"));
    if(native.length){
      const files=resultLayout().rows.filter(hit=>!isLauncher(hit)).length;
      summary=(state.error?summary+" · ":"")+native.join(" · ")+" · "+(state.lexicalReady?files+" file "+(files===1?"match":"matches")+" shown":"Files pending");
    }
  }
  $summary.textContent = summary;
  const hit = selectedHit();
  $primary.hidden = !hit; $details.hidden = !hit;
  $primary.textContent = isSetting(hit) ? "Open settings" : isLauncher(hit) ? "Launch" : "Open";
  $primary.setAttribute("aria-label", hit ? $primary.textContent + " " + titleOf(hit) : "Open selected result");
  $primary.disabled = isLauncher(hit) && Apps.launching.has(hit.id);
  $details.textContent = !$big.hidden ? "Back" : isLauncher(hit) ? "Details" : "Preview";
  $activity.hidden = !(state.error || state.caveat || state.activityBadge || state.phase === "wordsOnly");
  $activity.classList.toggle("has-problem", Boolean(state.error || state.phase === "wordsOnly"));
  $activity.title = state.error || state.caveat || state.activityLine || "Open Activity and diagnostics";
  $keys.textContent = isSetting(selectedHit()) ? "↩ Open Windows settings" : isLauncher(selectedHit()) ? "↩ Launch application" : `↩ Open   ${MOD}↩ Show in ${FILE_MANAGER}   ␣ Preview`;
}

// MARK: The big preview (Space, as Quick Look on the Mac)

const $big = element("div", "big");
$big.id = "result-preview"; $big.setAttribute("role", "region"); $big.setAttribute("aria-label", "Selected result details");
$details.setAttribute("aria-controls", "result-preview");
$big.hidden = true;
document.getElementById("panel").append($big);

/// Space, once a result is chosen with the arrows or a click: the panel at its tallest with the result over all of
/// it, a video playing from its moment. Space or Esc puts it away; the arrows go on through the results under it.
function toggleBig() {
  if (!selectedHit()) return;
  if (!$big.hidden) return closeBig();
  $big.hidden = false;
  renderBig();
  render();
}

function closeBig() {
  if ($big.hidden) return;
  $big.hidden = true;
  $big.replaceChildren();   // its video or sound stops with it
  $query.focus({preventScroll:true});
  render();
}

function renderBig() {
  const hit = selectedHit();
  if (!hit) return closeBig();
  const head = element("div", "head");
  const back = element("button", "preview-back", "Back"); back.type = "button"; back.onclick = closeBig;
  head.append(back, element("span", "name", titleOf(hit)));
  const place = isLauncher(hit) ? "" : placeOf(hit);
  if (place) head.append(element("span", "place", place));
  let view;
  if (isLauncher(hit)) {
    view = Apps.details(hit, failed);
  } else if (hit.kind === "video") {
    view = element("video");
    view.src = `${fileURL(hit.path)}#t=${hit.loc ?? 0}`;
    view.controls = true;
    view.autoplay = true;
  } else {
    view = picture(hit);
  }
  const box = element("div", "view");
  box.append(view);
  $big.replaceChildren(head, box);
}

function message(title, text) {
  const box = element("div", "message");
  box.append(element("strong", "", title), element("span", "", text));
  return box;
}

// MARK: Keys and events

$query.addEventListener("input", queryChanged);

document.addEventListener("keydown", (event) => {
  if (event.isComposing) return; // an input method is composing: its keys
  if (event.key !== "Escape" && event.target !== $query
      && event.target.closest("button, a, input, textarea, select, summary, video, audio, [contenteditable]")) return;
  const modifier = isMac ? event.metaKey : event.ctrlKey;
  switch (event.key) {
    case "Escape":
      event.preventDefault();
      if (!$big.hidden) closeBig();
      else invoke("hide_panel").catch(() => {});
      break;
    case " ":
      if (isLauncher(selectedHit())) return;
      // After the arrows or a click: the big preview (or the weaker matches' fold). While typing: a space.
      if (event.altKey || event.shiftKey || modifier || !(state.navigated || !$big.hidden) || !state.selection) return;
      event.preventDefault();
      if (state.selection === WEAKER) toggleWeaker();
      else toggleBig();
      break;
    case "ArrowDown":
    case "ArrowUp":
      if (event.altKey || event.shiftKey || modifier) return;
      event.preventDefault();
      move(event.key === "ArrowDown" ? 1 : -1);
      if (!$big.hidden) {
        if (state.selection === WEAKER) closeBig();
        else renderBig();
      }
      break;
    case "Enter":
      event.preventDefault();
      closeBig();
      if (modifier) revealSelected();
      else if (state.selection === WEAKER) toggleWeaker();
      else openSelected();
      break;
    case "c":
    case "C":
      if (!modifier || event.altKey || event.shiftKey || state.selection === WEAKER) return;
      copyResult(event, selectedHit(), state.navigated);
      break;
    case "o":
    case "O":
      if (!modifier || event.altKey || event.shiftKey) return;
      event.preventDefault();
      openInWindow();
      break;
  }
});

tauri.event.listen("panel-shown", ({payload}) => {
  closeBig();
  // Like Spotlight: the last query, selected.
  $query.focus();
  $query.select();
  invoke("panel_config").then(reply => { acceptConfig(reply); scheduleFit(); }).catch(() => {});
  requestAnimationFrame(() => requestAnimationFrame(() => {
    if (payload?.requestId && document.activeElement === $query)
      invoke("panel_ready", {requestId: payload.requestId}).catch(() => {});
  }));
  if($query.value.trim()&&!applicationSearch.active)queryChanged();
  if (!state.isApps && !state.isSettings) ask({ op: "prewarm" }).catch(() => {});
});
tauri.event.listen("panel-hidden",()=>{
  clearTimeout(state.timer); clearTimeout(statusTimer); clearTimeout(announceTimer); cancelAnimationFrame(state.frame); applicationSearch.suspend();settingsSearch.suspend();
  ask({op:"cancel",generation:++state.generation}).catch(()=>{});
});

tauri.event.listen("helper", ({ payload }) => {
  const { from, event } = payload;
  if(from==="search"&&event.event==="search_index"&&event.state==="words_ready"&&!document.hidden&&!state.isApps && !state.isSettings&&state.text)state.refreshWords?.(true);
  if(from==="search"&&event.event==="search_index"&&event.state==="ready"&&!document.hidden&&!state.isApps && !state.isSettings&&state.text)state.refine?.(true);
  if (from === "search" && event.event === "encoder") {
    state.encoder = event.state;
    if (state.phase !== "empty") renderFooter();
  }
});

tauri.event.listen("model", ({ payload }) => {
  if (payload.state === "ready" && !state.isApps && !state.isSettings) ask({ op: "prewarm" }).catch(() => {});
});

function showState(app) {
  state.indexing = app.indexing || null;
  state.hasCode = app.hasCode !== false;
  state.caveat = app.caveat || null;
  state.activityBadge = app.badge || null;
  state.activityLine = app.line || "";
  if (state.phase !== "empty") { renderFooter(); renderPreview(); scheduleFit(); }
}
$("expand-search").onclick = () => openInWindow();
$primary.onclick = openSelected;
$details.onclick = toggleBig;
$activity.onclick = () => invoke("open_settings", {tab:"activity"}).catch(failed);

tauri.event.listen("state", ({ payload }) => showState(payload));
invoke("app_state").then(showState).catch(() => {});

// Debug runs (--debug-query): type the query in, and once the meaning results and their pictures are in, report
// what the panel shows.
function debugSearch(query) {
  if (!query) return;
  debugPending = true;
  $query.value = query;
  queryChanged();
}
invoke("debug_query").then(debugSearch);
tauri.event.listen("debug-query", ({ payload }) => debugSearch(payload));   // after setup's first index

function report() {
  debugPending = false;
  // Dev snapshots (index.html?big): the selected result's big preview, as Space shows it.
  if (new URLSearchParams(location.search).has("big")) toggleBig();
  setTimeout(() => {
    const big = $preview.querySelector("img, video, audio, .passage");
    const thumbs = [...$list.querySelectorAll("img.thumb")];
    invoke("debug_report", {
      report: {
        query: $query.value,
        phase: state.phase,
        groups: [...(applicationSearch.hits.length ? [{title:"Apps", rows:applicationSearch.hits.map(titleOf)}] : []), ...state.groups.map((group) => ({ title: group.title, rows: group.rows.map(titleOf) }))],
        applications: applicationSearch.hits.map(hit => ({id: hit.id, name: hit.name})),
        weaker: state.weaker.length,
        selected: state.selection && nameOf(state.selection),
        preview: big && {
          tag: big.tagName.toLowerCase(),
          loaded: big.tagName === "IMG" ? big.complete && big.naturalWidth > 0 : null,
          size: big.tagName === "IMG" ? `${big.naturalWidth}x${big.naturalHeight}` : null,
          text: big.classList.contains("passage") ? big.textContent.slice(0, 80) : null,
        },
        thumbnails: `${thumbs.filter((image) => image.complete && image.naturalWidth > 0).length} of ${thumbs.length} drawn`,
        facts: [...$preview.querySelectorAll(".facts .title, .facts .line, .reason span")].map((node) => node.textContent),
        footer: [$summary.textContent, $keys.textContent],
      },
    }).catch(() => {});
  }, 1500);
}

$query.addEventListener("compositionstart",()=>{state.composing=true;clearTimeout(state.timer);});
$query.addEventListener("compositionend",()=>{state.composing=false;queryChanged();});
document.addEventListener("visibilitychange",()=>{
  if(document.hidden){clearTimeout(state.timer);applicationSearch.suspend();settingsSearch.suspend();ask({op:"cancel",generation:++state.generation}).catch(()=>{});}
});
