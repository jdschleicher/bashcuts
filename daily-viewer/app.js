"use strict";

// Behavior + view layer for the daily viewer. The tiles are a function of the
// MODEL below: one render pass builds every row, count badges and stat numbers
// are derived from collection length (they can't drift), and every model string
// reaches the DOM through `el()` (textContent / setAttribute) so untrusted Azure
// DevOps text is escaped by construction — there is no innerHTML path to exploit.


// ---------------------------------------------------------------------------
// Model — placeholder data shaped like the eventual cache payload. Swapping in
// live `az boards` / Outlook output is a data change, not markup surgery.
// ---------------------------------------------------------------------------

var MS_PER_DAY = 24 * 60 * 60 * 1000;

// Sample activity timestamps are expressed relative to "now" so the 30-day
// window demonstrates itself whenever the mock is opened: the six-week-old row
// is always filtered out and the rest always land inside the window. Live data
// ships real ISO dates from the server, so this helper is sample-only.
function daysAgoISO(days) {
  return new Date(Date.now() - days * MS_PER_DAY).toISOString();
}

var MODEL = {
  agenda: {
    events: [
      {
        time: { label: "9:00 AM", tz: "EST", datetime: "2026-07-14T09:00:00-05:00" },
        title: "Sprint Planning Sync",
        location: { badge: "Teams", url: "https://teams.microsoft.com/l/meetup-join/example", urlLabel: "Join meeting →" },
        details: [
          { label: "With", text: "Platform Team · 6 attendees" }
        ]
      },
      {
        time: { label: "11:00 AM", tz: "EST", datetime: "2026-07-14T11:00:00-05:00" },
        title: "Architecture Design Review",
        location: { badge: "In person", text: "Room 132" },
        details: [
          { label: "Prep", link: { text: "Design doc →", url: "https://dev.azure.com/org/project/_wiki/wikis/project.wiki/42/Design-Review" } }
        ]
      }
    ]
  },

  // This Sprint's Focus. The backend scopes these rows two ways: to completable
  // work — User Story and Bug only, via $script:AzDevOpsDailyViewerWeekTypes (no
  // Task/Feature) — and to the current sprint iteration (System.IterationPath).
  // When no current iteration resolves it falls back to all active completable
  // work. Keep this sample list to in-sprint User Story / Bug rows to stay in parity.
  week: {
    stories: {
      label: "Stories to complete",
      open: true,
      items: [
        { type: "Story", id: 1234, url: "https://dev.azure.com/org/project/_workitems/edit/1234", title: "Wire agenda tile to az boards query", titleUrl: "https://dev.azure.com/org/project/_workitems/edit/1234", state: "In progress", priority: 2, date: "Jul 18" },
        { type: "Story", id: 1240, url: "https://dev.azure.com/org/project/_workitems/edit/1240", title: "Outlook calendar pull for daily events", titleUrl: "https://dev.azure.com/org/project/_workitems/edit/1240", state: "Active", priority: 3, date: "Jul 17" },
        { type: "Bug", id: 1251, url: "https://dev.azure.com/org/project/_workitems/edit/1251", title: "Timezone offset on EST agenda rows", titleUrl: "https://dev.azure.com/org/project/_workitems/edit/1251", state: "In review", priority: 1, date: "Jul 16" }
      ]
    }
  },

  // Prep is its own calendar tile. Items carry the same optional time/location
  // shape as agenda events, so a prep row can surface meeting detail when the
  // Outlook pull provides it and degrade to just title + date when it doesn't.
  // Each carries a stable event id so its "all set" marker persists across reloads.
  prep: {
    label: "Events to prepare for",
    open: true,
    items: [
      { id: "sample-planning", title: "Sprint Planning Sync", date: "Jul 16", datetime: "2026-07-16T09:00:00-05:00", marker: "needed",
        time: { label: "9:00 AM", tz: "EST" },
        location: { badge: "Teams", urlLabel: "Join meeting →", url: "https://teams.microsoft.com/l/meetup-join/example" } },
      { id: "sample-arch", title: "Architecture Design Review", date: "Jul 18", datetime: "2026-07-18T11:00:00-05:00", marker: "set",
        time: { label: "11:00 AM", tz: "EST" },
        location: { badge: "In person", text: "Room 132" } },
      { id: "sample-api", title: "Cross-team API Contract Review", date: "Jul 22", datetime: "2026-07-22T14:00:00-05:00", marker: "needed",
        time: { label: "2:00 PM", tz: "EST" },
        location: { badge: "Teams", urlLabel: "Join meeting →", url: "https://teams.microsoft.com/l/meetup-join/example2" } },
      { id: "sample-roadmap", title: "Quarterly Roadmap Workshop", date: "Jul 27", datetime: "2026-07-27T10:00:00-05:00", marker: "needed" }
    ]
  },

  activity: {
    groups: [
      {
        label: "Tagged discussions",
        open: true,
        items: [
          { type: "Feature", id: 1180, url: "https://dev.azure.com/org/project/_workitems/edit/1180", title: "@you — “can you confirm the WIQL scope?”", titleUrl: "https://dev.azure.com/org/project/_workitems/edit/1180?discussion", priority: 2, note: "1d ago", changedDate: daysAgoISO(1) },
          { type: "Story", id: 1240, url: "https://dev.azure.com/org/project/_workitems/edit/1240", title: "@you — “ready for review whenever”", titleUrl: "https://dev.azure.com/org/project/_workitems/edit/1240?discussion", priority: 3, note: "3h ago", changedDate: daysAgoISO(0) }
        ]
      },
      {
        label: "Active story updates",
        open: false,
        items: [
          { type: "Story", id: 1234, url: "https://dev.azure.com/org/project/_workitems/edit/1234", title: "State → In progress by A. Rivera", note: "2h ago", changedDate: daysAgoISO(0) },
          { type: "Bug", id: 1251, url: "https://dev.azure.com/org/project/_workitems/edit/1251", title: "Moved to In review", note: "4h ago", changedDate: daysAgoISO(0) },
          { type: "Story", id: 1188, url: "https://dev.azure.com/org/project/_workitems/edit/1188", title: "Closed after release cut", note: "6w ago", changedDate: daysAgoISO(45) }
        ]
      },
      {
        label: "Current sprint",
        open: false,
        items: [
          { type: "Task", id: 1209, url: "https://dev.azure.com/org/project/_workitems/edit/1209", title: "Update release notes", titleUrl: "https://dev.azure.com/org/project/_workitems/edit/1209", state: "In progress", priority: 2, note: "2h ago", changedDate: daysAgoISO(0) },
          { type: "Story", id: 1222, url: "https://dev.azure.com/org/project/_workitems/edit/1222", title: "Verify acceptance criteria signed off", titleUrl: "https://dev.azure.com/org/project/_workitems/edit/1222", state: "Active", priority: 1, note: "1d ago", changedDate: daysAgoISO(1) }
        ]
      }
    ]
  },

  focus: {
    primary: {
      title: "User Story #1234 — Wire agenda tile to az boards",
      url: "https://dev.azure.com/org/project/_workitems/edit/1234",
      sub: "Primary commitment for today · In progress"
    },
    support: {
      label: "SF devs — unplanned support",
      open: true,
      items: [
        { type: "Bug", id: 1260, url: "https://dev.azure.com/org/project/_workitems/edit/1260", title: "Deploy failing on scratch org spin-up", titleUrl: "https://dev.azure.com/org/project/_workitems/edit/1260", state: "Active", priority: 1, date: "Jul 15" },
        { type: "Task", id: 1263, url: "https://dev.azure.com/org/project/_workitems/edit/1263", title: "Help triage permission set assignment", titleUrl: "https://dev.azure.com/org/project/_workitems/edit/1263", state: "New", priority: 3, date: "Jul 21" }
      ]
    }
  }
};

var TYPE_CLASS = {
  Story: "t-story",
  "User Story": "t-story",
  Bug: "t-bug",
  Task: "t-task",
  Feature: "t-feature",
  Epic: "t-epic"
};

var STATE_CLASS = {
  "New": "s-new",
  "Active": "s-active",
  "In progress": "s-progress",
  "In review": "s-review",
  "Closing": "s-closing"
};

var STAR_GLYPH = "★";

// Prep-marker states. Meetings arrive "needed" (unprepared) and the user toggles
// each to "set" (all set). The flip is optimistic in the UI and POSTed to the
// backend, which stores it by event id — so a cache reload re-reads the saved
// state, not the model default (see prepMarkerButton / savePrepMarker).
var MARKER_SET = "set";
var MARKER_NEEDED = "needed";
var MARKER_SET_LABEL = "All set";
var MARKER_NEEDED_LABEL = "Prep still needed";


// Dismissal is a separate action from the prep marker above: the marker records
// whether a meeting is prepped (and stays in the list), while dismissal removes
// a handled row entirely. Recent updates get a "reviewed" dismissal; prep rows
// get a "remove" dismissal alongside their marker. Both are the same pill-toggle
// control — only the words and the bucket differ. Pressed means "handled".
var REVIEW_LABELS = { off: "Mark reviewed", on: "Reviewed" };
var PREP_DISMISS_LABELS = { off: "Remove", on: "Removed" };

// Recent updates only surface activity from the last 30 days.
var ACTIVITY_WINDOW_DAYS = 30;

// When true, dismissed rows stay visible (dimmed, with an undo control) instead
// of being filtered out — the toolbar's "Show reviewed" toggle flips this.
var showReviewed = false;


// ---------------------------------------------------------------------------
// Dismissal store — "reviewed" recent updates and "removed" prep items persist
// here so a handled item stays gone across refresh and reload. State is keyed by
// item identity and namespaced by bucket; a recent update reappears only if it
// changed after the moment it was reviewed (an inbox, not a permanent blocklist).
// This is separate from the prep marker (which persists to the backend by id);
// it's the client-side seam — swap localStorage for the server cache later and
// nothing above this block has to change.
// ---------------------------------------------------------------------------

var DISMISS_STORE_KEY = "dailyViewer.dismissed.v1";

var dismissStore = {
  _load: function () {
    try {
      var raw = window.localStorage.getItem(DISMISS_STORE_KEY);
      var parsed = raw ? JSON.parse(raw) : null;
      if (parsed && typeof parsed === "object") {
        return parsed;
      }
    } catch (err) {
      // Corrupt or blocked storage — start clean rather than throw on boot.
    }

    return {};
  },

  _save: function (data) {
    try {
      window.localStorage.setItem(DISMISS_STORE_KEY, JSON.stringify(data));
    } catch (err) {
      // Storage full or blocked (private mode) — dismissal degrades to
      // in-memory for this session instead of breaking the toggle.
    }
  },

  _bucket: function (data, bucket) {
    if (!data[bucket] || typeof data[bucket] !== "object") {
      data[bucket] = {};
    }

    return data[bucket];
  },

  isDismissed: function (bucket, key, changedDate) {
    var map = this._bucket(this._load(), bucket);
    if (!Object.prototype.hasOwnProperty.call(map, key)) {
      return false;
    }

    // Reappear when the item changed after it was reviewed (inbox model).
    if (changedDate) {
      var changed = Date.parse(changedDate);
      var reviewed = Date.parse(map[key]);
      if (!isNaN(changed) && !isNaN(reviewed) && changed > reviewed) {
        return false;
      }
    }

    return true;
  },

  dismiss: function (bucket, key) {
    var data = this._load();
    this._bucket(data, bucket)[key] = new Date().toISOString();
    this._save(data);
  },

  restore: function (bucket, key) {
    var data = this._load();
    delete this._bucket(data, bucket)[key];
    this._save(data);
  }
};


// Identity keys for the two buckets. Both prefer a stable id (recent updates by
// work-item id, prep by the event id #207 added for its marker); prep falls back
// to title + time when the sample row carries no id.
function activityKey(item) {
  return String(item.id != null ? item.id : (item.title || ""));
}

function prepKey(item) {
  if (item.id != null) {
    return String(item.id);
  }

  return (item.title || "") + "|" + (item.datetime || item.date || "");
}


// Per-bucket config: one object holds BOTH the filter inputs and the dismiss
// button inputs so the two can't drift. Filtering reads windowed/keyOf/changedOf;
// the button reads className/labels/tileKey and builds its announcements from the
// row label. (The tile key still surfaces literally in viewModel's dispatch and
// the toolbar handler; the spec keeps the per-item behavior together, not every
// mention of the name.)
var ACTIVITY_SPEC = {
  bucket: "activity",
  windowed: true,
  keyOf: activityKey,
  changedOf: function (item) {
    return item.changedDate;
  },
  className: "pill-toggle review",
  labels: REVIEW_LABELS,
  tileKey: "activity",
  doneMessage: function (label) {
    return label + " marked reviewed.";
  },
  undoMessage: function (label) {
    return label + " restored to recent updates.";
  }
};

var PREP_DISMISS_SPEC = {
  bucket: "prep",
  windowed: false,
  keyOf: prepKey,
  changedOf: function () {
    return null;
  },
  className: "pill-toggle dismiss",
  labels: PREP_DISMISS_LABELS,
  tileKey: "prep",
  doneMessage: function (label) {
    return label + " removed from prep.";
  },
  undoMessage: function (label) {
    return label + " restored to prep.";
  }
};


// ---------------------------------------------------------------------------
// DOM builder — the single, escaping-safe path from model to page. `text` sets
// textContent and every other key goes through setAttribute, so a malicious
// title renders as inert text. Children may be nodes or plain strings.
// ---------------------------------------------------------------------------

function el(tag, opts, children) {
  var node = document.createElement(tag);

  if (opts) {
    Object.keys(opts).forEach(function (key) {
      if (key === "class") {
        node.className = opts[key];
      } else if (key === "text") {
        node.textContent = opts[key];
      } else {
        node.setAttribute(key, opts[key]);
      }
    });
  }

  if (children) {
    children.forEach(function (child) {
      if (child === null || child === undefined) {
        return;
      }
      node.appendChild(typeof child === "string" ? document.createTextNode(child) : child);
    });
  }

  return node;
}

function chevron() {
  var tpl = document.getElementById("tpl-chev");
  return tpl.content.firstElementChild.cloneNode(true);
}

// textContent protects a title's text, but an href does not — a javascript:
// URL still executes on click. Once live Azure DevOps data flows in, a link
// field is untrusted too, so gate the scheme and drop the href otherwise.
var SAFE_URL_SCHEMES = { "http:": true, "https:": true, "mailto:": true };

function safeUrl(url) {
  try {
    var parsed = new URL(url, window.location.href);
    if (SAFE_URL_SCHEMES[parsed.protocol]) {
      return parsed.href;
    }
  } catch (err) {
    return null;
  }

  return null;
}

function externalLink(text, url, className) {
  var opts = { target: "_blank", rel: "noopener noreferrer", text: text };

  var href = safeUrl(url);
  if (href) {
    opts.href = href;
  }
  if (className) {
    opts["class"] = className;
  }

  return el("a", opts);
}


// ---------------------------------------------------------------------------
// Row builders — one per row shape. Each returns a single <li>/element.
// ---------------------------------------------------------------------------

// Priority is the ADO 1-4 field. Anything outside that range (including an
// absent/`null` value) yields no chip, so a work item without a priority set
// renders cleanly. The aria-label spells out "Priority N" so the terse "P2"
// visible label isn't cryptic to a screen reader.
function priorityChip(priority) {
  var n = parseInt(priority, 10);
  if (!(n >= 1 && n <= 4)) {
    return null;
  }

  return el("span", { class: "priority p" + n, "aria-label": "Priority " + n }, [ "P" + n ]);
}

function workItemRow(wi) {
  var children = [];

  children.push(el("span", { class: "type " + (TYPE_CLASS[wi.type] || ""), text: wi.type }));
  children.push(externalLink("#" + wi.id, wi.url, "id"));

  if (wi.titleUrl) {
    children.push(el("span", { class: "wtitle" }, [ externalLink(wi.title, wi.titleUrl) ]));
  } else {
    children.push(el("span", { class: "wtitle", text: wi.title }));
  }

  var pri = priorityChip(wi.priority);
  if (pri) {
    children.push(pri);
  }

  if (wi.state) {
    children.push(el("span", { class: "state " + (STATE_CLASS[wi.state] || ""), text: wi.state }));
  }

  if (wi.date) {
    children.push(el("span", { class: "date", text: wi.date }));
  }

  if (wi.note) {
    children.push(el("span", { class: "note", text: wi.note }));
  }

  return el("li", { class: "wi" }, children);
}


// Both dismiss controls are the same pill: aria-pressed is the state, the
// visible text is the action, and an aria-label folds in the item title so a
// screen reader can tell one row's control from the next. The click hands off to
// onToggle, which updates the store and repaints the tile — the button is rebuilt
// from the fresh view model rather than mutating itself.
function dismissButton(className, pressed, labels, ariaLabel, onToggle) {
  var btn = el("button", {
    type: "button",
    class: className,
    "aria-pressed": pressed ? "true" : "false",
    "aria-label": ariaLabel,
    text: pressed ? labels.on : labels.off
  });

  btn.addEventListener("click", onToggle);

  return btn;
}


// Pressed means "handled" (reviewed / removed): restore brings the row back,
// dismiss removes it. Every flip is announced through the shared aria-live
// region so a screen reader hears which item changed, then the tile repaints.
function applyDismissalToggle(opts) {
  if (opts.pressed) {
    dismissStore.restore(opts.bucket, opts.key);
    announce(opts.undoMessage);
  } else {
    dismissStore.dismiss(opts.bucket, opts.key);
    announce(opts.doneMessage);
  }

  repaintTile(opts.tileKey);
}


// Repainting a tile rebuilds its body, so the just-clicked control is destroyed
// and focus falls to <body>. Return focus to the same-position control of the
// same kind (the row that slid into the removed row's place), falling back to the
// tile's summary — so a keyboard user keeps their place in the list.
function focusTileControl(tileKey, controlClass, index) {
  var scope = tile(tileKey);
  if (!scope) {
    return;
  }

  var controls = scope.querySelectorAll("." + controlClass);
  if (controls.length) {
    controls[Math.min(index, controls.length - 1)].focus();
  } else {
    var summary = scope.querySelector("summary");
    if (summary) {
      summary.focus();
    }
  }
}


// One builder for both dismiss controls, driven by the bucket spec — the review
// toggle and the prep remove differ only in that data, so they share this body.
function dismissToggleButton(item, spec) {
  var pressed = item._dismissed === true;
  var label = item.title || "This item";
  var ariaLabel = (pressed ? spec.labels.on : spec.labels.off) + " — " + label;
  var controlClass = spec.className.split(" ").pop();

  var btn = dismissButton(spec.className, pressed, spec.labels, ariaLabel, function () {
    var peers = tile(spec.tileKey).querySelectorAll("." + controlClass);
    var index = Array.prototype.indexOf.call(peers, btn);

    applyDismissalToggle({
      bucket: spec.bucket,
      key: spec.keyOf(item),
      pressed: pressed,
      tileKey: spec.tileKey,
      doneMessage: spec.doneMessage(label),
      undoMessage: spec.undoMessage(label)
    });

    focusTileControl(spec.tileKey, controlClass, index < 0 ? 0 : index);
  });

  return btn;
}


// Dim a row whose item is dismissed (only reachable under "Show reviewed").
function flagDismissed(li, item) {
  if (item._dismissed) {
    li.classList.add("dismissed");
  }
}


// A recent-update row is a work-item row plus the reviewed toggle. Dismissed
// rows (only visible under "Show reviewed") render dimmed via .dismissed.
function activityRow(item) {
  var li = workItemRow(item);

  flagDismissed(li, item);
  li.appendChild(dismissToggleButton(item, ACTIVITY_SPEC));

  return li;
}


// The prep marker is a real toggle button: aria-pressed carries the state (and
// drives the chip color in CSS), the visible text is its accessible name, and
// every flip is announced through the shared aria-live region so a screen reader
// hears which meeting changed. The flip is optimistic and then persisted by
// event id, so it survives a cache reload; if the save fails the button reverts.
function markerText(pressed) {
  return pressed ? MARKER_SET_LABEL : MARKER_NEEDED_LABEL;
}

function setMarkerPressed(btn, pressed) {
  btn.setAttribute("aria-pressed", pressed ? "true" : "false");
  btn.textContent = markerText(pressed);
}

// Persist one meeting's marker to the backend so it outlives the tile cache.
// Returns the fetch promise; the caller reverts the optimistic flip on reject.
function savePrepMarker(id, pressed) {
  var marker = pressed ? MARKER_SET : MARKER_NEEDED;
  return fetchJson(API + PREP_TILE + "/prep-marker", {
    method: "POST",
    headers: { "Content-Type": "application/json", "Accept": "application/json" },
    body: JSON.stringify({ id: id, marker: marker })
  });
}


function prepMarkerButton(item) {
  var pressed = item.marker === MARKER_SET;

  var btn = el("button", {
    type: "button",
    class: "pill-toggle marker",
    "aria-pressed": pressed ? "true" : "false",
    text: markerText(pressed)
  });

  // Guard re-clicks with a flag (plus aria-disabled) rather than the native
  // `disabled` property: toggling `disabled` synchronously punts keyboard focus
  // to <body>, so a keyboard user loses their place in the list. aria-disabled
  // keeps focus on the button while the save is in flight.
  var saving = false;

  btn.addEventListener("click", function () {
    if (saving) {
      return;
    }

    var next = btn.getAttribute("aria-pressed") !== "true";
    setMarkerPressed(btn, next);

    var label = item.title || "This item";
    announce(label + (next ? " marked all set." : " marked prep still needed."));

    // Only persist rows backed by the live server: they carry a real event id
    // and the prep tile loaded from the backend, not the offline sample model.
    // In sample mode the toggle stays an in-memory preview, as it was before.
    if (!item.id || !tileFromBackend.prep) {
      return;
    }

    saving = true;
    btn.setAttribute("aria-disabled", "true");
    savePrepMarker(item.id, next)
      .then(function () {
        saving = false;
        btn.removeAttribute("aria-disabled");
      })
      .catch(function () {
        saving = false;
        btn.removeAttribute("aria-disabled");
        setMarkerPressed(btn, !next);
        announce(label + " — couldn't save, change reverted.");
      });
  });

  return btn;
}


// Agenda-style detail on a prep row: the meeting time and location share one meta
// line under the title, joined by the middle-dot separator. Both are optional, so
// a prep item that carries neither renders as just its title.
var META_SEP = "·";

function prepMetaLine(item) {
  var bits = [];

  if (item.time) {
    bits.push(timeNode({ label: item.time.label, tz: item.time.tz, datetime: item.datetime }));
  }
  if (item.location) {
    bits.push(whereLine(item.location));
  }

  if (bits.length === 0) {
    return null;
  }

  var children = [];
  bits.forEach(function (bit, i) {
    if (i > 0) {
      children.push(META_SEP);
    }
    children.push(bit);
  });

  return el("p", { class: "meta" }, children);
}


function prepRow(item) {
  var titleLine = [ item.title ];

  if (item.link) {
    titleLine.push(" ");
    titleLine.push(externalLink(item.link.text, item.link.url));
  }

  var column = [ el("p", { class: "ptitle" }, titleLine) ];

  var meta = prepMetaLine(item);
  if (meta) {
    column.push(meta);
  }

  var children = [ el("div", { class: "wtitle" }, column) ];

  if (item.date) {
    children.push(el("span", { class: "date", text: item.date }));
  }

  children.push(prepMarkerButton(item));
  children.push(dismissToggleButton(item, PREP_DISMISS_SPEC));

  var li = el("li", { class: "wi prep" }, children);

  flagDismissed(li, item);

  return li;
}


// Shared time + location renderers — the agenda tile and the prep tile both
// surface a meeting's start time and place, so the escaping-safe markup for each
// lives in one helper. The datetime attribute is optional: agenda events carry it
// on the time object, prep passes the item-level datetime, and a row without one
// renders a plain <time> label rather than a literal "undefined" attribute.
function timeNode(time) {
  var opts = { class: "time" };
  if (time.datetime) {
    opts.datetime = time.datetime;
  }

  var children = [ time.label ];
  if (time.tz) {
    children.push(el("span", { class: "tz", text: time.tz }));
  }

  return el("time", opts, children);
}


function whereLine(location) {
  var children = [ el("span", { class: "badge-loc", text: location.badge }) ];

  if (location.text) {
    children.push(" ");
    children.push(location.text);
  }
  if (location.url) {
    children.push(" ");
    children.push(externalLink(location.urlLabel, location.url));
  }

  return el("span", { class: "where" }, children);
}


function eventRow(ev) {
  var metaLines = [ el("p", { class: "meta" }, [ whereLine(ev.location) ]) ];

  (ev.details || []).forEach(function (detail) {
    var line = [ el("span", { class: "k", text: detail.label }), " " ];
    if (detail.link) {
      line.push(externalLink(detail.link.text, detail.link.url));
    } else {
      line.push(detail.text);
    }
    metaLines.push(el("p", { class: "meta" }, line));
  });

  var content = el("div", null, [ el("p", { class: "etitle", text: ev.title }) ].concat(metaLines));

  return el("li", { class: "event" }, [ timeNode(ev.time), content ]);
}


// A tile's collections arrive from the cache/API as JSON. Guard every list
// through this so a serialized-empty array (or an absent field) becomes [] and
// never a `.map` on a non-array.
function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function groupBlock(group, rowFn, emptyNote) {
  var items = asArray(group.items);

  var summary = el("summary", null, [
    chevron(),
    el("span", { class: "glabel", text: group.label }),
    el("span", { class: "count", text: String(items.length) })
  ]);

  var list = el("ul", { class: "glist" }, items.map(rowFn));

  // A group that's empty for a friendly reason (no meetings in the prep window)
  // gets a note in place of a blank list; the note isn't a row, so it never
  // inflates the count badge or the tile's meaningful-row check.
  if (items.length === 0 && emptyNote) {
    list.appendChild(el("li", { class: "empty-note", text: emptyNote }));
  }

  var opts = { class: "group" };
  if (group.open) {
    opts.open = "";
  }

  return el("details", opts, [ summary, list ]);
}


// ---------------------------------------------------------------------------
// Tile renderers — each returns the array of nodes for that tile's .body.
// ---------------------------------------------------------------------------

function renderAgenda(model) {
  var list = el("ul", { class: "events" }, asArray(model.events).map(eventRow));
  return [ list ];
}


function renderWeek(model) {
  return [ groupBlock(model.stories || {}, workItemRow) ];
}


// A start time in epoch millis, or Infinity when the datetime is absent or
// unparseable — so a missing/garbled value sorts last instead of throwing or
// (for NaN) leaving the row wherever it happened to sit.
function startMillis(datetime) {
  if (!datetime) {
    return Infinity;
  }

  var ms = new Date(datetime).getTime();
  return isNaN(ms) ? Infinity : ms;
}


// Prep events read as a chronological upcoming-meetings list, so sort a copy by
// start time ascending; an item missing a datetime sorts last rather than
// throwing. The tile header already names the group, so rows render as a flat
// list (no nested group label to duplicate it).
function sortByDatetime(items) {
  var copy = items.slice();

  copy.sort(function (a, b) {
    var ta = startMillis(a.datetime);
    var tb = startMillis(b.datetime);
    return ta - tb;
  });

  return copy;
}


function renderPrep(model) {
  var items = sortByDatetime(asArray(model.items));
  var list = el("ul", { class: "plist" }, items.map(prepRow));
  return [ list ];
}


function renderActivity(model) {
  return asArray(model.groups).map(function (group) {
    return groupBlock(group, activityRow);
  });
}


function renderFocus(model) {
  var nodes = [];

  // The pinned item is optional — it comes from $global:AzDevOpsDailyFocus, and
  // the tile renders its support bucket alone when nothing is pinned.
  if (model.primary) {
    nodes.push(el("div", { class: "primary" }, [
      el("span", { class: "star", "aria-hidden": "true" }, [ STAR_GLYPH ]),
      el("div", null, [
        el("p", { class: "ptitle" }, [ externalLink(model.primary.title, model.primary.url) ]),
        el("p", { class: "psub", text: model.primary.sub })
      ])
    ]));
  }

  nodes.push(groupBlock(model.support || {}, workItemRow));
  return nodes;
}


// ---------------------------------------------------------------------------
// View model — the recent-updates and prep collections are filtered before
// render: the 30-day window and dismissed items are applied here, so the render
// layer, the count badges, and the stat numbers all read the same post-filter
// data and can't drift from each other.
// ---------------------------------------------------------------------------

function withinActivityWindow(item) {
  if (!item.changedDate) {
    return true;
  }

  var changed = Date.parse(item.changedDate);
  if (isNaN(changed)) {
    return true;
  }

  var cutoff = Date.now() - ACTIVITY_WINDOW_DAYS * MS_PER_DAY;
  return changed >= cutoff;
}


// Drop items outside the window, then either hide dismissed items or — under
// "show reviewed" — keep them flagged so the row can render dimmed with an undo.
// Items are shallow-copied before flagging so the source MODEL (reused as the
// offline fallback) is never mutated.
function filterItems(items, spec) {
  var out = [];

  asArray(items).forEach(function (item) {
    if (spec.windowed && !withinActivityWindow(item)) {
      return;
    }

    var dismissed = dismissStore.isDismissed(spec.bucket, spec.keyOf(item), spec.changedOf(item));
    if (dismissed && !showReviewed) {
      return;
    }

    var copy = Object.assign({}, item);
    copy._dismissed = dismissed;
    out.push(copy);
  });

  return out;
}


function activityView(model) {
  var groups = asArray(model.groups).map(function (group) {
    var copy = Object.assign({}, group);
    copy.items = filterItems(group.items, ACTIVITY_SPEC);
    return copy;
  });

  return { groups: groups };
}


function prepView(model) {
  var view = Object.assign({}, model);
  view.items = filterItems(model.items, PREP_DISMISS_SPEC);
  return view;
}


function viewModel(key, model) {
  if (key === "activity") {
    var av = activityView(model);
    return av;
  }

  if (key === "prep") {
    var pv = prepView(model);
    return pv;
  }

  return model;
}


// ---------------------------------------------------------------------------
// Shared render constants — what counts as a "row" (mount, count badges, live
// filter) and the live filter's placeholder, named so every render path shares
// the same wording.
// ---------------------------------------------------------------------------

var ROW_SELECTOR = ".wi, .event";

var NOMATCH_TEXT = "No matching items in this tile.";

function activityTotal(model) {
  return asArray(model.groups).reduce(function (sum, group) {
    return sum + asArray(group.items).length;
  }, 0);
}


// ---------------------------------------------------------------------------
// Mount helpers — resolve a tile/panel node, set a stat number, derive the
// tile-header row count. Shared by every composite tile's paint path.
// ---------------------------------------------------------------------------

// A key resolves to a whole tile, or — for a panel key (agenda / prep / week /
// activity / focus) — to that panel's <details> inside its composite tile, so the
// dismissal/marker code can scope and repaint a single panel without disturbing
// its siblings.
function tile(key) {
  return document.querySelector('.tile[data-tile="' + key + '"]') ||
    document.querySelector('.group[data-panel="' + key + '"]');
}

// The number binds by data-stat (each stat is unique); data-target is only where
// clicking it jumps — the stats that share a composite tile share one jump target.
function setStat(statId, count) {
  var number = document.querySelector('.stat[data-stat="' + statId + '"] .n');
  if (number) {
    number.textContent = String(count);
  }
}


// The tile-header count is always the number of visible rows in the body — one
// derivation shared by every composite tile, so the badge can never drift from a
// hand-authored literal.
function paintRowCount(key) {
  var scope = tile(key);
  var rows = scope.querySelector(".body").querySelectorAll(ROW_SELECTOR).length;
  scope.querySelector(".tt .count").textContent = String(rows);
}


// ---------------------------------------------------------------------------
// Composite tiles — a tile whose body holds N panels rendered as collapsible
// groups. Each panel keeps its own endpoint, model slice, stat, and empty note;
// its tile has one refresh (fanning out to every panel) and one staleness label
// (the oldest of the panel cache ages). Panels render and repaint independently,
// so one panel's dismissal leaves its siblings untouched. Both the Calendar tile
// (Outlook agenda + prep) and the Azure DevOps tile (this sprint's focus, recent
// activity, today's focus) are composites driven by this one engine.
// ---------------------------------------------------------------------------

var CALENDAR_PANELS = [
  { key: "agenda", label: "Today’s Agenda", render: renderAgenda,
    empty: "No meetings today.", stat: "tile-agenda",
    statCount: function (m) { return asArray(m.events).length; } },
  { key: "prep", label: "Events to Prepare For", render: renderPrep,
    empty: "No meetings to prepare for in the next two weeks.", stat: "tile-prep",
    statCount: function (m) { return asArray(m.items).length; } }
];

var ADO_PANELS = [
  { key: "week", label: "This Sprint’s Focus", render: renderWeek,
    empty: "No stories in the current sprint.", stat: "tile-week",
    statCount: function (m) { return asArray(m.stories && m.stories.items).length; } },
  { key: "activity", label: "Recent Activity", render: renderActivity,
    empty: "No recent activity.", stat: "tile-activity",
    statCount: activityTotal },
  { key: "focus", label: "Today’s Focus", render: renderFocus,
    empty: "Nothing pinned. Set $global:AzDevOpsDailyFocus to a work-item id.", stat: "tile-focus",
    statCount: function (m) { return asArray(m.support && m.support.items).length; } }
];

var COMPOSITES = [
  { key: "calendar",    name: "Calendar",     panels: CALENDAR_PANELS },
  { key: "azuredevops", name: "Azure DevOps", panels: ADO_PANELS }
];

// Panel-key lookups: which panel config a key names, and which composite tile it
// lives in — so a single-panel repaint (dismissal / show-reviewed) can find its
// render config and its owning tile for the combined count.
var COMPOSITE_BY_KEY = {};
var PANEL_BY_KEY = {};
var COMPOSITE_BY_PANEL = {};
COMPOSITES.forEach(function (composite) {
  COMPOSITE_BY_KEY[composite.key] = composite;
  composite.panels.forEach(function (panel) {
    PANEL_BY_KEY[panel.key] = panel;
    COMPOSITE_BY_PANEL[panel.key] = composite;
  });
});

// Each panel's last-loaded raw model + staleness, so a panel can repaint from data
// (a dismissal / show-reviewed flip) without refetching, and its tile can recompute
// its combined count and oldest-age staleness.
var panelState = {};

// Store a panel's backend payload: mark it backend-backed and keep its model +
// staleness. The load and refresh success paths share this; only the failure
// handling differs (load falls back to sample, refresh keeps the last-good data).
function storePanelPayload(panelKey, data) {
  tileFromBackend[panelKey] = true;
  panelState[panelKey] = { model: data.items || {}, data: data };
}


// Build one panel as a .group <details> — the same collapsible shell the drill-in
// groups use, so the disclosure caret, summary, and count badge all match. The
// count and the empty-note decision are both derived from the rendered rows, so
// the badge can't drift from the list and a focus panel with a pinned item (but no
// support rows) still counts as non-empty.
function buildCompositePanel(panel, view, open) {
  var body = el("div", { class: "panel-body" }, panel.render(view));

  var meaningful = body.querySelectorAll(ROW_SELECTOR + ", .primary").length;
  if (meaningful === 0) {
    body.appendChild(el("p", { class: "empty-note", text: panel.empty }));
  }

  var rows = body.querySelectorAll(ROW_SELECTOR).length;

  var summary = el("summary", null, [
    chevron(),
    el("span", { class: "glabel", text: panel.label }),
    el("span", { class: "count", text: String(rows) })
  ]);

  var opts = { class: "group", "data-panel": panel.key };
  if (open) {
    opts.open = "";
  }

  return el("details", opts, [ summary, body ]);
}


// One staleness label for N sources: show the oldest of the panel cache ages (and
// warn if any is stale). If any panel fell back to the sample model, the tile
// reads "sample data" — the same signal a single-source tile gives on fallback.
function setCompositeStale(composite) {
  var stale = tile(composite.key).querySelector(".stale");
  var label = staleLabelNode(composite.key);

  var ages = [];
  var anyStale = false;
  var anySample = false;

  composite.panels.forEach(function (panel) {
    var data = (panelState[panel.key] || {}).data;
    if (data && typeof data.ageSeconds === "number") {
      ages.push(data.ageSeconds);
      if (data.stale) {
        anyStale = true;
      }
    } else {
      anySample = true;
    }
  });

  var age = (anySample || ages.length === 0) ? null : Math.max.apply(null, ages);
  applyStaleLabel(stale, label, age, anyStale);
}


// Full paint: rebuild every panel (default open), refresh each panel's stat and
// the tile count + staleness. Used on load and after a refresh.
function paintComposite(composite) {
  var body = tile(composite.key).querySelector(".body");
  body.textContent = "";

  composite.panels.forEach(function (panel) {
    var st = panelState[panel.key] || { model: {}, data: null };
    var view = viewModel(panel.key, st.model || {});

    body.appendChild(buildCompositePanel(panel, view, true));
    setStat(panel.stat, panel.statCount(view));
  });

  body.appendChild(el("p", { class: "nomatch", text: NOMATCH_TEXT }));

  paintRowCount(composite.key);
  setCompositeStale(composite);
}


// Repaint a single panel from its stored model — the dismissal / show-reviewed
// path. Only the target panel's node is replaced (preserving its current open
// state), so its sibling panels are left exactly as they were.
function repaintCompositePanel(panelKey) {
  var panel = PANEL_BY_KEY[panelKey];
  var composite = COMPOSITE_BY_PANEL[panelKey];
  var st = panelState[panelKey];
  if (!panel || !composite || !st) {
    return;
  }

  var existing = tile(panelKey);
  var open = existing ? existing.open : true;

  var view = viewModel(panelKey, st.model || {});
  var next = buildCompositePanel(panel, view, open);

  if (existing) {
    existing.replaceWith(next);
  }

  setStat(panel.stat, panel.statCount(view));
  paintRowCount(composite.key);
}


// Load one panel from its endpoint, falling back to the sample model on any
// failure — independently, so one endpoint being down doesn't blank the others.
function loadCompositePanel(panelKey) {
  return fetchJson(API + panelKey, { headers: { "Accept": "application/json" } })
    .then(function (data) {
      storePanelPayload(panelKey, data);
      return true;
    })
    .catch(function () {
      tileFromBackend[panelKey] = false;
      panelState[panelKey] = { model: MODEL[panelKey], data: null };
      return false;
    });
}


// Boot load: fetch every panel, paint once. Returns false if any panel fell back
// to sample data, so the boot handler can announce it.
function loadComposite(composite) {
  var loads = composite.panels.map(function (panel) {
    return loadCompositePanel(panel.key);
  });

  return Promise.all(loads).then(function (results) {
    paintComposite(composite);
    return results.indexOf(false) === -1;
  });
}


// One refresh button, every source: fan out to each panel's POST /refresh, then
// repaint the whole tile. A single spinner + staleness label covers them all; if
// any source fails the label warns and the announcement says so.
function refreshComposite(btn, composite) {
  var stale = tile(composite.key).querySelector(".stale");
  var label = staleLabelNode(composite.key);

  beginRefreshSpinner(btn, stale, label, composite.name);

  var refreshes = composite.panels.map(function (panel) {
    return fetchJson(API + panel.key + "/refresh", { method: "POST", headers: { "Accept": "application/json" } })
      .then(function (data) {
        storePanelPayload(panel.key, data);
        return true;
      })
      .catch(function () {
        return false;
      });
  });

  return Promise.all(refreshes).then(function (results) {
    paintComposite(composite);
    rememberOpenState();
    applyFilter(searchBox.value);

    if (results.indexOf(false) === -1) {
      announce(composite.name + " updated — cached just now.");
    } else {
      stale.classList.remove("busy");
      stale.classList.add("warn");
      announce(composite.name + " refresh failed for one or more sections.");
    }
  }).then(function () {
    endRefreshSpinner(btn);
  });
}


// ---------------------------------------------------------------------------
// Staleness — turn the cache's ageSeconds into the "cached Nm ago" label the
// tile header shows, matching the server's own relative-time buckets.
// ---------------------------------------------------------------------------

function formatAge(sec) {
  if (sec < 45) {
    return "just now";
  }

  var min = Math.round(sec / 60);
  if (min < 60) {
    return min + "m ago";
  }

  var hr = Math.round(min / 60);
  if (hr < 24) {
    return hr + "h ago";
  }

  var day = Math.round(hr / 24);
  return day + "d ago";
}

function staleLabelNode(key) {
  var stale = tile(key).querySelector(".stale");
  return stale.childNodes[stale.childNodes.length - 1];
}

// Paint one staleness label: "cached N ago" (warn-tinted if stale) when an age is
// known, else "sample data". `ageSeconds` is null when the tile fell back. Shared
// by the single-source tiles and the calendar tile's oldest-of-two label.
function applyStaleLabel(stale, label, ageSeconds, isStale) {
  stale.classList.remove("busy");

  if (typeof ageSeconds === "number") {
    label.textContent = "cached " + formatAge(ageSeconds);
    stale.classList.toggle("warn", !!isStale);
  } else {
    label.textContent = "sample data";
    stale.classList.remove("warn");
  }
}


// ---------------------------------------------------------------------------
// Data layer — cheap GET on load, expensive POST /refresh on demand. Both hit
// the same-origin local server; on any failure (offline preview, no backend)
// the tile falls back to the embedded sample MODEL so the page still renders.
// ---------------------------------------------------------------------------

var API = "/api/tiles/";
var CREATE_API = "/api/create/";
var PREP_TILE = "prep";

// Which tiles this session actually loaded from the backend (vs. the offline
// sample fallback). The prep-marker POST only fires for backend-backed rows, so
// an offline preview toggles in-memory instead of trying — and failing — to save.
var tileFromBackend = {};

function fetchJson(url, options) {
  return fetch(url, options).then(function (res) {
    if (!res.ok) {
      throw new Error("HTTP " + res.status);
    }
    return res.json();
  });
}

// POST the create-surface smoke check. Sends an empty JSON object so the request
// exercises the same POST + application/json path the real create endpoints
// (sub-issues B–E) will use — the backend rejects non-JSON bodies — and resolves
// only on a 2xx. Rejects (offline mock, no backend) so the caller can report it.
function pingCreateBackend() {
  return fetchJson(CREATE_API + "ping", {
    method: "POST",
    headers: { "Accept": "application/json", "Content-Type": "application/json" },
    body: "{}"
  });
}

// Repaint a single panel from its last-loaded model — after a dismissal toggle or
// a "show reviewed" flip. Re-deriving the view model reapplies the 30-day window
// and dismissals, then the open-state and the active search filter the full
// repaint dropped are restored (the same post-render fix-up the refresh path does).
function repaintTile(key) {
  if (!PANEL_BY_KEY[key]) {
    return;
  }

  repaintCompositePanel(key);
  rememberOpenState();
  applyFilter(searchBox.value);
}


// ---------------------------------------------------------------------------
// Controls — announce, expand/collapse, per-tile + all refresh, stat jump,
// theme, live filter. Wired once; all handlers query the DOM at event time so
// they see whatever the async render produced.
// ---------------------------------------------------------------------------

// Named liveRegion, not `status`: a top-level `var status` in a classic script
// aliases the built-in window.status string and breaks assignment under strict mode.
var liveRegion = document.getElementById("sr-status");

function announce(message) {
  if (liveRegion) {
    liveRegion.textContent = message;
  }
}


document.getElementById("expandAll").addEventListener("click", function () {
  document.querySelectorAll("details").forEach(function (d) { d.open = true; });
});

document.getElementById("collapseAll").addEventListener("click", function () {
  document.querySelectorAll(".tile > details").forEach(function (d) { d.open = false; });
});


// "Show reviewed" reveals dismissed rows (dimmed, with an undo) across the two
// tiles that support dismissal — recent updates and prep — instead of filtering
// them out.
var showReviewedBtn = document.getElementById("showReviewed");
showReviewedBtn.addEventListener("click", function () {
  showReviewed = !showReviewed;
  showReviewedBtn.setAttribute("aria-pressed", showReviewed ? "true" : "false");

  repaintTile("activity");
  repaintTile("prep");

  announce(showReviewed ? "Showing reviewed and removed items." : "Hiding reviewed and removed items.");
});


// Refresh spinner lifecycle — the button spin, the "refreshing…" busy label, and
// the announcement, shared by the single-tile and calendar refresh paths.
function beginRefreshSpinner(btn, stale, label, name) {
  btn.disabled = true;
  btn.classList.add("spinning");
  stale.classList.remove("warn");
  stale.classList.add("busy");
  label.textContent = "refreshing…";
  announce("Refreshing " + name + "…");
}

function endRefreshSpinner(btn) {
  btn.classList.remove("spinning");
  btn.disabled = false;
}

// Every tile is a composite (Calendar, Azure DevOps); the button's data-tile
// names which one, and refreshComposite fans out to that tile's panels.
function refreshTile(btn) {
  if (btn.disabled) {
    return Promise.resolve();
  }

  var composite = COMPOSITE_BY_KEY[btn.getAttribute("data-tile")];
  if (!composite) {
    return Promise.resolve();
  }

  return refreshComposite(btn, composite);
}

document.querySelectorAll(".refresh-btn").forEach(function (btn) {
  btn.addEventListener("click", function (e) {
    e.preventDefault();
    e.stopPropagation();
    refreshTile(btn);
  });
});

document.getElementById("refreshAll").addEventListener("click", function () {
  document.querySelectorAll(".refresh-btn").forEach(refreshTile);
});


// Stat strip: open and scroll to the composite tile a stat summarizes, then open
// its matching inner panel so the jump lands on the right group, not just the tile.
document.querySelectorAll(".stat").forEach(function (stat) {
  stat.addEventListener("click", function () {
    var target = document.getElementById(stat.dataset.target);
    if (!target) {
      return;
    }

    var details = target.querySelector("details");
    if (details) {
      details.open = true;
    }

    if (stat.dataset.group) {
      var panel = target.querySelector('.group[data-panel="' + stat.dataset.group + '"]');
      if (panel) {
        panel.open = true;
      }
    }

    target.scrollIntoView({ behavior: "smooth", block: "start" });
  });
});


// Theme toggle: stamp data-theme on <html> so it overrides the OS media query.
var root = document.documentElement;
var iconSun = document.getElementById("icon-sun");
var iconMoon = document.getElementById("icon-moon");

function currentTheme() {
  var t = root.getAttribute("data-theme");
  if (t) {
    return t;
  }
  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

function paintThemeIcon() {
  var dark = currentTheme() === "dark";
  iconMoon.classList.toggle("is-hidden", !dark);
  iconSun.classList.toggle("is-hidden", dark);
}

document.getElementById("themeToggle").addEventListener("click", function () {
  var next = currentTheme() === "dark" ? "light" : "dark";
  root.setAttribute("data-theme", next);
  paintThemeIcon();
  announce(next === "dark" ? "Dark theme." : "Light theme.");
});

paintThemeIcon();


// ---------------------------------------------------------------------------
// View mode — Agenda ↔ Create sub-tabs. Agenda is the default read dashboard;
// Create hosts the Azure DevOps creation surface (sub-issues B–E mount into
// #creator-body). The active mode mirrors to a #create URL hash so deep links
// and the back button work, and the tablist adds arrow-key nav with a roving
// tabindex. setMode is idempotent, so the click, keyboard, and hash paths can
// all funnel through it without fighting each other.
// ---------------------------------------------------------------------------

var MODES = ["agenda", "create"];
var CREATE_HASH = "#create";

var modeTabs = {
  agenda: document.getElementById("tab-agenda"),
  create: document.getElementById("tab-create")
};
var modeViews = {
  agenda: document.getElementById("view-agenda"),
  create: document.getElementById("view-create")
};
var agendaControls = document.getElementById("agenda-controls");
var activeMode = "agenda";
var createPinged = false;

function modeFromHash() {
  return location.hash === CREATE_HASH ? "create" : "agenda";
}

function setMode(mode, silent) {
  if (MODES.indexOf(mode) === -1) {
    mode = "agenda";
  }
  activeMode = mode;

  MODES.forEach(function (m) {
    var isActive = m === mode;
    var tab = modeTabs[m];
    var view = modeViews[m];

    tab.setAttribute("aria-selected", isActive ? "true" : "false");
    tab.tabIndex = isActive ? 0 : -1;

    view.classList.toggle("is-hidden", !isActive);
    if (isActive) {
      view.removeAttribute("hidden");
    } else {
      view.setAttribute("hidden", "");
    }
  });

  agendaControls.classList.toggle("is-hidden", mode !== "agenda");

  if (!silent) {
    announce(mode === "create" ? "Create mode." : "Agenda mode.");
  }

  if (mode === "create") {
    pingCreateOnce();
    ensureCreateForm();
  }
}

// Update the URL fragment without reloading: pushState keeps a clean path in
// Agenda mode (no dangling "#") and gives the back button an entry. file:// can
// reject pushState, so fall back to a hash assignment for the offline mock.
function writeModeHash(mode) {
  try {
    if (mode === "create") {
      history.pushState(null, "", CREATE_HASH);
    } else {
      history.pushState(null, "", location.pathname + location.search);
    }
  } catch (e) {
    location.hash = mode === "create" ? CREATE_HASH : "";
  }
}

function goToMode(mode) {
  setMode(mode);
  writeModeHash(mode);
}

// Arrow / Home / End move selection across the tablist (roving tabindex), the
// WAI-ARIA tabs pattern; Enter/Space activate natively since the tabs are buttons.
function onModeKeydown(e) {
  var idx = MODES.indexOf(activeMode);
  var next = null;

  if (e.key === "ArrowRight" || e.key === "ArrowDown") {
    next = (idx + 1) % MODES.length;
  } else if (e.key === "ArrowLeft" || e.key === "ArrowUp") {
    next = (idx - 1 + MODES.length) % MODES.length;
  } else if (e.key === "Home") {
    next = 0;
  } else if (e.key === "End") {
    next = MODES.length - 1;
  }

  if (next === null) {
    return;
  }

  e.preventDefault();
  var mode = MODES[next];
  goToMode(mode);
  modeTabs[mode].focus();
}

MODES.forEach(function (m) {
  modeTabs[m].addEventListener("click", function () { goToMode(m); });
  modeTabs[m].addEventListener("keydown", onModeKeydown);
});

window.addEventListener("popstate", function () { setMode(modeFromHash()); });
window.addEventListener("hashchange", function () { setMode(modeFromHash()); });


// Backend reachability, checked once when Create is first shown — the browser end
// of the POST /api/create/ping smoke test. Success means the create endpoints
// (sub-issues B–E) can reach the PowerShell backend; failure means the page is
// running without its server (the offline mock), so creates aren't wired yet.
function setCreateStatus(state, text) {
  var chip = document.getElementById("creator-status");
  var label = document.getElementById("creator-status-text");
  if (!chip || !label) {
    return;
  }

  chip.classList.remove("checking", "ok", "offline");
  chip.classList.add(state);
  label.textContent = text;
}

function pingCreateOnce() {
  if (createPinged) {
    return;
  }
  createPinged = true;

  setCreateStatus("checking", "Checking backend…");

  pingCreateBackend()
    .then(function () {
      setCreateStatus("ok", "Backend connected");
      announce("Create backend connected.");
    })
    .catch(function () {
      setCreateStatus("offline", "Offline — sample mode");
      announce("Create backend offline — sample mode.");
    });
}

// ---------------------------------------------------------------------------
// Create mode — work-item forms (Epic #228 sub-issue B). The form is a function
// of the selected type: one field spec drives which fields render, so Story /
// Task / Feature / Epic / Feature+Stories share one render path instead of five
// hand-authored forms. Area / iteration / parent choices come from the cache via
// GET /api/create/options; a submit POSTs /api/create/workitem, which runs the
// same non-interactive create core the terminal az-New-* funcs wrap. Every value
// reaches the DOM through el() (textContent / setAttribute), so an untrusted
// Azure DevOps title in a parent option can't inject markup.
// ---------------------------------------------------------------------------

var CREATE_OPTIONS_API  = CREATE_API + "options";
var CREATE_WORKITEM_API = CREATE_API + "workitem";

// One spec row per form type: the parent type it links to (null = a root item),
// and whether it carries story points / acceptance criteria. Mirrors the
// backend's $script:AzDevOpsDailyViewerCreateTypes so the two can't drift on
// which fields a type honors.
var CREATE_TYPE_SPECS = {
  "User Story":     { parentType: "Feature",    points: true,  acceptance: true,  batch: false },
  "Task":           { parentType: "User Story", points: false, acceptance: false, batch: false },
  "Feature":        { parentType: "Epic",       points: false, acceptance: false, batch: false },
  "Epic":           { parentType: null,         points: false, acceptance: false, batch: false },
  "FeatureStories": { parentType: "Epic",       points: false, acceptance: false, batch: true }
};

var PRIORITY_OPTIONS = [
  { value: "1", label: "P1 — highest" },
  { value: "2", label: "P2" },
  { value: "3", label: "P3" },
  { value: "4", label: "P4 — lowest" }
];
var CREATE_DEFAULT_PRIORITY = "2";

// Row separators used when composing option/result labels, named so they aren't
// scattered as bare punctuation literals (the backend names its dash/middot too).
var CREATE_DASH = " — ";
var CREATE_MIDDOT = " · ";

var createState = { options: null, loaded: false, initialized: false };
var createStorySeq = 0;

var createForm = document.getElementById("create-form");
var createTypeSelect = document.getElementById("create-type");
var createFields = document.getElementById("create-fields");
var createSubmit = document.getElementById("create-submit");
var createResult = document.getElementById("create-result");


// --- control builders — every value goes in via el() (textContent/setAttribute) ---

function buildSelect(optionModels, placeholder, attrs) {
  var options = [];
  if (placeholder) {
    options.push(el("option", { value: "", text: placeholder }));
  }
  optionModels.forEach(function (m) {
    options.push(el("option", { value: m.value, text: m.label }));
  });
  return el("select", attrs || {}, options);
}

function stringOptionModels(values) {
  return (values || []).map(function (v) {
    return { value: v, label: v };
  });
}

function parentOptionModels(parentType) {
  var opts = createState.options;
  if (!opts || !opts.parents || !parentType) {
    return [];
  }

  var rows = opts.parents[parentType] || [];
  return rows.map(function (r) {
    var suffix = r.state ? CREATE_MIDDOT + r.state : "";
    return { value: String(r.id), label: "#" + r.id + CREATE_DASH + r.title + suffix };
  });
}

// Explicit label+control for the singleton main fields (unique ids).
function labeledField(id, labelText, control, hint) {
  var children = [ el("label", { "for": id, text: labelText }), control ];
  if (hint) {
    children.push(el("p", { class: "field-hint", text: hint }));
  }
  return el("div", { class: "field" }, children);
}

// Wrapped implicit label for the repeatable story rows (no shared ids).
function wrappedField(labelText, control) {
  return el("label", { class: "field" }, [
    el("span", { class: "field-label", text: labelText }),
    control
  ]);
}


// Priority / area / iteration are shared across every type; points, acceptance,
// and parent depend on the spec. defaultArea / defaultIteration preselect the
// user's usual values when the options payload carries them.
function createSharedFields(spec) {
  var opts = createState.options || {};
  var fields = [];

  fields.push(labeledField("f-title", "Title",
    el("input", { id: "f-title", type: "text", maxlength: "255", autocomplete: "off" })));

  fields.push(labeledField("f-description", "Description",
    el("textarea", { id: "f-description", rows: "4" })));

  var prioritySelect = buildSelect(PRIORITY_OPTIONS, null, { id: "f-priority" });
  prioritySelect.value = CREATE_DEFAULT_PRIORITY;
  fields.push(labeledField("f-priority", "Priority", prioritySelect));

  if (spec.points) {
    fields.push(labeledField("f-points", "Story points",
      el("input", { id: "f-points", type: "number", min: "0", step: "1", inputmode: "numeric" }),
      "Leave blank to omit."));
  }

  if (spec.acceptance) {
    fields.push(labeledField("f-acceptance", "Acceptance criteria",
      el("textarea", { id: "f-acceptance", rows: "3" })));
  }

  var areaSelect = buildSelect(stringOptionModels(opts.areas), "Select an area…", { id: "f-area" });
  if (opts.defaultArea) {
    areaSelect.value = opts.defaultArea;
  }
  fields.push(labeledField("f-area", "Area path", areaSelect));

  var iterationSelect = buildSelect(stringOptionModels(opts.iterations), "Select an iteration…", { id: "f-iteration" });
  if (opts.defaultIteration) {
    iterationSelect.value = opts.defaultIteration;
  }
  fields.push(labeledField("f-iteration", "Iteration path", iterationSelect));

  if (spec.parentType) {
    var parentSelect = buildSelect(parentOptionModels(spec.parentType), "No parent", { id: "f-parent" });
    fields.push(labeledField("f-parent", "Parent " + spec.parentType, parentSelect,
      "Links this item under a " + spec.parentType + " from the cache."));
  }

  return fields;
}


// One child-story row for the Feature+Stories batch. Uses class-based selectors
// (not ids) so many rows coexist; aria-labels number them for screen readers.
function buildStoryBlock() {
  createStorySeq++;
  var n = createStorySeq;

  var title = el("input", { type: "text", class: "s-title", maxlength: "255", autocomplete: "off", "aria-label": "Story " + n + " title" });
  var description = el("textarea", { class: "s-description", rows: "2", "aria-label": "Story " + n + " description" });

  var priority = buildSelect(PRIORITY_OPTIONS, null, { class: "s-priority", "aria-label": "Story " + n + " priority" });
  priority.value = CREATE_DEFAULT_PRIORITY;

  var points = el("input", { type: "number", class: "s-points", min: "0", step: "1", inputmode: "numeric", "aria-label": "Story " + n + " points" });
  var acceptance = el("textarea", { class: "s-acceptance", rows: "2", "aria-label": "Story " + n + " acceptance criteria" });

  var remove = el("button", { type: "button", class: "btn story-remove", "aria-label": "Remove story " + n }, [ "Remove" ]);

  var block = el("div", { class: "story-block" }, [
    el("div", { class: "story-head" }, [
      el("span", { class: "story-n", text: "Story" }),
      remove
    ]),
    wrappedField("Title", title),
    wrappedField("Description", description),
    wrappedField("Priority", priority),
    wrappedField("Points", points),
    wrappedField("Acceptance criteria", acceptance)
  ]);

  remove.addEventListener("click", function () {
    var list = document.getElementById("create-stories");
    if (list && list.querySelectorAll(".story-block").length > 1) {
      block.remove();
    }
  });

  return block;
}

function buildStoriesSection() {
  var list = el("div", { id: "create-stories", class: "story-list" }, [ buildStoryBlock() ]);

  var add = el("button", { type: "button", class: "btn", id: "add-story" }, [ "+ Add story" ]);
  add.addEventListener("click", function () {
    list.appendChild(buildStoryBlock());
  });

  return el("fieldset", { class: "story-fieldset" }, [
    el("legend", { text: "Child stories" }),
    list,
    add
  ]);
}


function renderCreateFields() {
  var type = createTypeSelect.value;
  var spec = CREATE_TYPE_SPECS[type] || {};

  createFields.textContent = "";
  createSharedFields(spec).forEach(function (field) {
    createFields.appendChild(field);
  });

  if (spec.batch) {
    createFields.appendChild(buildStoriesSection());
  }
}


// --- submit + result ---

function fieldValue(id) {
  var node = document.getElementById(id);
  return node ? node.value : "";
}

function collectStoryPayloads() {
  var blocks = document.querySelectorAll("#create-stories .story-block");
  var stories = [];

  blocks.forEach(function (block) {
    var title = block.querySelector(".s-title").value.trim();
    if (!title) {
      return;
    }

    stories.push({
      title: title,
      description: block.querySelector(".s-description").value,
      priority: block.querySelector(".s-priority").value,
      storyPoints: block.querySelector(".s-points").value,
      acceptanceCriteria: block.querySelector(".s-acceptance").value
    });
  });

  return stories;
}

function collectCreatePayload(type, spec) {
  var payload = {
    type: type,
    title: fieldValue("f-title").trim(),
    description: fieldValue("f-description"),
    priority: fieldValue("f-priority"),
    area: fieldValue("f-area"),
    iteration: fieldValue("f-iteration")
  };

  var parent = document.getElementById("f-parent");
  if (parent && parent.value) {
    payload.parentId = parent.value;
  }

  if (spec.points) {
    payload.storyPoints = fieldValue("f-points");
  }
  if (spec.acceptance) {
    payload.acceptanceCriteria = fieldValue("f-acceptance");
  }
  if (spec.batch) {
    payload.stories = collectStoryPayloads();
  }

  return payload;
}

function validateCreatePayload(payload, spec) {
  if (!payload.title) {
    return "Title is required.";
  }
  if (!payload.area) {
    return "Select an area path.";
  }
  if (!payload.iteration) {
    return "Select an iteration path.";
  }
  if (spec.batch && payload.stories.length === 0) {
    return "Add at least one child story with a title.";
  }
  return null;
}

function setCreateBusy(busy) {
  createSubmit.disabled = busy;
  createSubmit.textContent = busy ? "Creating…" : "Create";
}

function showCreateMessage(kind, text) {
  createResult.textContent = "";
  if (!text) {
    return;
  }
  createResult.appendChild(el("div", { class: "create-banner " + kind }, [ text ]));
}

// One created-item line: a link to the new work item, or an error line when the
// create failed. The work-item title is untrusted, so it lands via el() text.
function createdLine(result) {
  if (!result || !result.ok) {
    var msg = (result && result.error) ? result.error : "Create failed.";
    return el("li", { class: "create-item bad" }, [ msg ]);
  }

  var label = "Created " + result.type + " #" + result.id;
  var children = [];

  if (result.url) {
    children.push(externalLink(label, result.url, "create-link"));
  } else {
    children.push(el("span", { text: label }));
  }

  if (result.title) {
    children.push(el("span", { class: "create-item-title", text: CREATE_DASH + result.title }));
  }

  if (result.linked === false && result.linkError) {
    children.push(el("span", { class: "create-warn", text: " (created, but parent link failed: " + result.linkError + ")" }));
  }

  return el("li", { class: "create-item good" }, children);
}

function renderCreateResult(res, spec) {
  createResult.textContent = "";

  var data = res.data;
  if (!data) {
    showCreateMessage("bad", "Create failed (HTTP " + res.status + ").");
    return;
  }

  var list = el("ul", { class: "create-list" }, []);
  var anyOk;

  if (spec.batch) {
    list.appendChild(createdLine(data.feature));
    (data.stories || []).forEach(function (story) {
      list.appendChild(createdLine(story));
    });
    anyOk = !!(data.feature && data.feature.ok);
  } else {
    list.appendChild(createdLine(data));
    anyOk = !!data.ok;
  }

  if (!anyOk) {
    createResult.appendChild(el("div", { class: "create-banner bad" }, [ data.error || "Create failed." ]));
  }
  createResult.appendChild(list);

  if (anyOk) {
    var again = el("button", { type: "button", class: "btn" }, [ "Create another" ]);
    again.addEventListener("click", resetCreateForAnother);
    createResult.appendChild(again);
  }
}

function resetCreateForAnother() {
  [ "f-title", "f-description", "f-acceptance", "f-points" ].forEach(function (id) {
    var node = document.getElementById(id);
    if (node) {
      node.value = "";
    }
  });

  var stories = document.getElementById("create-stories");
  if (stories) {
    stories.querySelectorAll(".story-block").forEach(function (block, index) {
      if (index === 0) {
        block.querySelectorAll("input, textarea").forEach(function (node) {
          node.value = "";
        });
      } else {
        block.remove();
      }
    });
  }

  createResult.textContent = "";
  var title = document.getElementById("f-title");
  if (title) {
    title.focus();
  }
}

// POST that keeps the JSON body on any status — the create endpoint returns
// { ok, error } with a 400/200, and we want the error text either way (fetchJson
// throws on non-2xx and would drop it).
function postCreateJson(url, payload) {
  return fetch(url, {
    method: "POST",
    headers: { "Accept": "application/json", "Content-Type": "application/json" },
    body: JSON.stringify(payload)
  }).then(function (res) {
    return res.json().then(function (data) {
      return { status: res.status, data: data };
    }, function () {
      return { status: res.status, data: null };
    });
  });
}

function submitCreate(event) {
  event.preventDefault();

  var type = createTypeSelect.value;
  var spec = CREATE_TYPE_SPECS[type] || {};
  var payload = collectCreatePayload(type, spec);

  var problem = validateCreatePayload(payload, spec);
  if (problem) {
    showCreateMessage("bad", problem);
    return;
  }

  setCreateBusy(true);
  showCreateMessage("busy", "Creating…");

  postCreateJson(CREATE_WORKITEM_API, payload).then(function (res) {
    renderCreateResult(res, spec);
  }).catch(function () {
    showCreateMessage("bad", "Create failed — the daily-viewer server isn't reachable. Start it with az-Start-AzDevOpsDailyViewer.");
  }).then(function () {
    setCreateBusy(false);
  });
}


// Cache-backed picker data; empty lists on any failure so the form still renders
// (offline mock) — a submit then surfaces the not-reachable message.
function loadCreateOptions() {
  return fetchJson(CREATE_OPTIONS_API, { headers: { "Accept": "application/json" } })
    .then(function (data) {
      createState.options = data;
      createState.loaded = true;
    })
    .catch(function () {
      createState.options = { areas: [], iterations: [], parents: {} };
      createState.loaded = false;
    });
}

// Fetch the picker data at most once — the create form and the draft panel both
// need it, so the second consumer reuses the in-flight / settled promise instead
// of hitting GET /api/create/options twice.
var createOptionsPromise = null;
function ensureCreateOptions() {
  if (!createOptionsPromise) {
    createOptionsPromise = loadCreateOptions();
  }
  return createOptionsPromise;
}

// Wire + render once, the first time Create mode is shown.
function ensureCreateForm() {
  if (createState.initialized) {
    return;
  }
  createState.initialized = true;

  createTypeSelect.addEventListener("change", function () {
    renderCreateFields();
    showCreateMessage("", "");
  });
  createForm.addEventListener("submit", submitCreate);

  ensureCreateOptions().then(function () {
    renderCreateFields();
  });
}


// ---------------------------------------------------------------------------
// Creator sub-tabs — Work item (the per-type create form) vs Draft (the
// brain-dump hierarchy builder). A nested tablist inside the Create view, the
// same roving-tabindex pattern as the top-level mode tabs; the Draft panel wires
// + loads lazily the first time it's shown. Timer (#232) / unplanned (#233) slot
// their own tabs here.
// ---------------------------------------------------------------------------

var CREATOR_TABS = ["workitem", "draft", "timer"];
var CREATOR_TAB_LABELS = {
  workitem: "Work item form.",
  draft: "Draft builder.",
  timer: "Timer session."
};
var creatorTabs = {
  workitem: document.getElementById("subtab-workitem"),
  draft: document.getElementById("subtab-draft"),
  timer: document.getElementById("subtab-timer")
};
var creatorPanels = {
  workitem: document.getElementById("panel-workitem"),
  draft: document.getElementById("panel-draft"),
  timer: document.getElementById("panel-timer")
};
var activeCreatorTab = "workitem";

function setCreatorTab(tab, silent) {
  if (CREATOR_TABS.indexOf(tab) === -1) {
    tab = "workitem";
  }
  activeCreatorTab = tab;

  CREATOR_TABS.forEach(function (t) {
    var isActive = t === tab;
    creatorTabs[t].setAttribute("aria-selected", isActive ? "true" : "false");
    creatorTabs[t].tabIndex = isActive ? 0 : -1;

    creatorPanels[t].classList.toggle("is-hidden", !isActive);
    if (isActive) {
      creatorPanels[t].removeAttribute("hidden");
    } else {
      creatorPanels[t].setAttribute("hidden", "");
    }
  });

  if (!silent) {
    announce(CREATOR_TAB_LABELS[tab] || "Work item form.");
  }

  if (tab === "draft") {
    ensureDraftPanel();
  } else if (tab === "timer") {
    ensureTimerPanel();
  }
}

function onCreatorTabKeydown(e) {
  var idx = CREATOR_TABS.indexOf(activeCreatorTab);
  var next = null;

  if (e.key === "ArrowRight" || e.key === "ArrowDown") {
    next = (idx + 1) % CREATOR_TABS.length;
  } else if (e.key === "ArrowLeft" || e.key === "ArrowUp") {
    next = (idx - 1 + CREATOR_TABS.length) % CREATOR_TABS.length;
  } else if (e.key === "Home") {
    next = 0;
  } else if (e.key === "End") {
    next = CREATOR_TABS.length - 1;
  }

  if (next === null) {
    return;
  }

  e.preventDefault();
  var tab = CREATOR_TABS[next];
  setCreatorTab(tab);
  creatorTabs[tab].focus();
}

CREATOR_TABS.forEach(function (t) {
  creatorTabs[t].addEventListener("click", function () { setCreatorTab(t); });
  creatorTabs[t].addEventListener("keydown", onCreatorTabKeydown);
});


// ---------------------------------------------------------------------------
// Timer mode — headless focus session (Epic #228 sub-issue D, #232). The browser
// owns only the countdown (a JS interval, its progress bar gated by
// prefers-reduced-motion) and the debrief form; composing and posting the comment
// stay server-side in the pow_timer.ps1 helpers via POST /api/timer/post, so the
// terminal (az-Start-TimerSession) and the browser share one debrief format and
// one posting path. Setup data (the registered integrations + their cached items)
// comes from GET /api/timer/options. Every echoed item/title reaches the DOM
// through el() (textContent), so an untrusted Azure DevOps title stays inert. The
// panel walks three stages — setup, running, debrief — shown one at a time.
// ---------------------------------------------------------------------------

var TIMER_API = "/api/timer/";
var TIMER_DEFAULT_MINUTES = 25;
var TIMER_MAX_MINUTES = 180;
var TIMER_ADD_SECONDS = 300;
var TIMER_TICK_MS = 1000;

var timerState = {
  initialized: false,
  integrations: [],
  defaultMinutes: TIMER_DEFAULT_MINUTES,
  intervalId: null,
  minutes: TIMER_DEFAULT_MINUTES,
  total: 0,
  remaining: 0,
  interrupted: false,
  item: null,
  integration: null
};

var timerSetup = document.getElementById("timer-setup");
var timerFields = document.getElementById("timer-fields");
var timerRunning = document.getElementById("timer-running");
var timerItemLabel = document.getElementById("timer-item");
var timerClock = document.getElementById("timer-clock");
var timerDebrief = document.getElementById("timer-debrief");
var timerResult = document.getElementById("timer-result");


// Toggle the is-hidden class + hidden attribute together — the same pair the mode
// and sub-tab switches use, factored out here for the timer's three stages.
function setNodeHidden(node, hidden) {
  if (!node) {
    return;
  }
  node.classList.toggle("is-hidden", hidden);
  if (hidden) {
    node.setAttribute("hidden", "");
  } else {
    node.removeAttribute("hidden");
  }
}

function timerPad2(n) {
  return n < 10 ? "0" + n : String(n);
}

function formatTimerClock(totalSeconds) {
  var s = Math.max(0, Math.round(totalSeconds));
  var m = Math.floor(s / 60);
  var r = s % 60;
  return timerPad2(m) + ":" + timerPad2(r);
}

function timerFieldValue(id) {
  var node = document.getElementById(id);
  return node ? node.value : "";
}

function timerActionButton(label, handler) {
  var btn = el("button", { type: "button", class: "btn" }, [ label ]);
  btn.addEventListener("click", handler);
  return btn;
}

// One transient status line in #timer-result — a busy/bad banner, or cleared when
// text is empty. The success path (renderTimerResult) writes the banner + the
// three-way restart choice directly instead.
function showTimerMessage(kind, text) {
  timerResult.textContent = "";
  if (!text) {
    return;
  }
  timerResult.appendChild(el("div", { class: "create-banner " + kind }, [ text ]));
}

function showTimerStage(stage) {
  setNodeHidden(timerSetup, stage !== "setup");
  setNodeHidden(timerRunning, stage !== "running");
  setNodeHidden(timerDebrief, stage !== "debrief");
}

function setTimerStartEnabled(enabled) {
  var btn = document.getElementById("timer-start");
  if (btn) {
    btn.disabled = !enabled;
  }
}

function setTimerPostBusy(busy) {
  var btn = document.getElementById("timer-post");
  if (btn) {
    btn.disabled = busy;
    btn.textContent = busy ? "Posting…" : "Post debrief";
  }
}


// --- setup stage: integration + item + minutes, from the cached options ---

function renderTimerFields() {
  timerFields.textContent = "";

  var integrations = timerState.integrations;
  if (!integrations.length) {
    timerFields.appendChild(el("p", { class: "field-hint", text:
      "No timer integrations are registered, or the daily-viewer server isn't running. Start it with az-Start-AzDevOpsDailyViewer." }));
    setTimerStartEnabled(false);
    return;
  }

  timerState.integration = integrations[0];

  if (integrations.length > 1) {
    var integrationModels = integrations.map(function (integ, idx) {
      return { value: String(idx), label: integ.name };
    });
    var integrationSelect = buildSelect(integrationModels, null, { id: "timer-integration" });
    integrationSelect.addEventListener("change", function () {
      timerState.integration = integrations[Number(integrationSelect.value)] || integrations[0];
      renderTimerItemField();
    });
    timerFields.appendChild(labeledField("timer-integration", "Integration", integrationSelect));
  }

  timerFields.appendChild(el("div", { id: "timer-item-field" }));
  renderTimerItemField();

  var minutesInput = el("input", {
    id: "timer-minutes", type: "number", min: "1", max: String(TIMER_MAX_MINUTES),
    value: String(timerState.defaultMinutes), inputmode: "numeric", autocomplete: "off"
  });
  timerFields.appendChild(labeledField("timer-minutes", "Minutes", minutesInput));
}

// The item dropdown — repainted on its own when the integration changes, so the
// list always matches the selected integration's cached items.
function renderTimerItemField() {
  var container = document.getElementById("timer-item-field");
  if (!container) {
    return;
  }
  container.textContent = "";

  var integ = timerState.integration;
  var items = (integ && integ.items) || [];

  if (!items.length) {
    var empty = buildSelect([], null, { id: "timer-item-select", disabled: "" });
    empty.appendChild(el("option", { value: "", text: "No cached items — run az-Sync-AzDevOpsCache" }));
    container.appendChild(labeledField("timer-item-select", "Work item", empty));
    setTimerStartEnabled(false);
    return;
  }

  var itemModels = items.map(function (it) {
    var suffix = it.state ? CREATE_MIDDOT + it.state : "";
    return { value: String(it.id), label: "#" + it.id + CREATE_DASH + it.title + suffix };
  });
  container.appendChild(labeledField("timer-item-select", "Work item",
    buildSelect(itemModels, null, { id: "timer-item-select" })));
  setTimerStartEnabled(true);
}

function findTimerItem(integ, id) {
  var items = (integ && integ.items) || [];
  for (var i = 0; i < items.length; i++) {
    if (String(items[i].id) === String(id)) {
      return items[i];
    }
  }
  return { id: Number(id), title: "", type: "", state: "" };
}

function readTimerMinutes() {
  var val = parseInt(timerFieldValue("timer-minutes"), 10);
  if (!isFinite(val) || val < 1) {
    val = timerState.defaultMinutes;
  }
  if (val > TIMER_MAX_MINUTES) {
    val = TIMER_MAX_MINUTES;
  }
  return val;
}


// --- running stage: the JS countdown ---

function clearTimerInterval() {
  if (timerState.intervalId !== null) {
    window.clearInterval(timerState.intervalId);
    timerState.intervalId = null;
  }
}

function paintTimerClock() {
  timerClock.textContent = formatTimerClock(timerState.remaining);

  var fill = document.getElementById("timer-progress-fill");
  if (fill && timerState.total > 0) {
    var pct = Math.max(0, Math.min(100, (timerState.remaining / timerState.total) * 100));
    fill.style.width = pct + "%";
  }
}

function onTimerTick() {
  timerState.remaining -= 1;

  if (timerState.remaining <= 0) {
    timerState.remaining = 0;
    paintTimerClock();
    finishTimer(false);
    return;
  }

  paintTimerClock();
}

function runTimerCountdown() {
  timerState.remaining = timerState.total;
  timerState.interrupted = false;

  paintTimerClock();
  showTimerStage("running");
  clearTimerInterval();
  timerState.intervalId = window.setInterval(onTimerTick, TIMER_TICK_MS);
}

function startTimer(event) {
  event.preventDefault();

  var integ = timerState.integration;
  if (!integ) {
    return;
  }

  var itemId = timerFieldValue("timer-item-select");
  if (!itemId) {
    showTimerMessage("bad", "Pick a work item to time.");
    return;
  }

  timerState.item = findTimerItem(integ, itemId);
  timerState.minutes = readTimerMinutes();
  timerState.total = timerState.minutes * 60;

  showTimerMessage("", "");
  renderTimerItemBanner(timerState.item);
  runTimerCountdown();
  announce("Timer started for " + timerState.minutes + " minutes.");
}

function renderTimerItemBanner(item) {
  timerItemLabel.textContent = "";
  var label = "#" + item.id + (item.title ? CREATE_DASH + item.title : "");
  timerItemLabel.appendChild(el("span", { text: label }));
}

function addTimerMinutes() {
  timerState.total += TIMER_ADD_SECONDS;
  timerState.remaining += TIMER_ADD_SECONDS;
  paintTimerClock();
  announce("Added 5 minutes.");
}

function cancelTimer() {
  clearTimerInterval();
  showTimerMessage("", "");
  showTimerStage("setup");
  announce("Timer cancelled.");
}


// --- debrief stage ---

function updateTimerResolveVisibility() {
  var field = document.getElementById("timer-resolve-field");
  var canResolve = !!(timerState.integration && timerState.integration.canResolve);
  setNodeHidden(field, !canResolve);
}

function finishTimer(interrupted) {
  clearTimerInterval();
  timerState.interrupted = interrupted;

  updateTimerResolveVisibility();
  showTimerStage("debrief");
  announce(interrupted ? "Timer ended early. Add a debrief and post." : "Time's up. Add a debrief and post.");

  var focus = document.getElementById("timer-debrief-text");
  if (focus) {
    focus.focus();
  }
}

function resetTimerDebriefFields() {
  [ "timer-debrief-text", "timer-next-text" ].forEach(function (id) {
    var node = document.getElementById(id);
    if (node) {
      node.value = "";
    }
  });

  var resolve = document.getElementById("timer-resolve");
  if (resolve) {
    resolve.checked = false;
  }
}

function discardTimerDebrief() {
  resetTimerDebriefFields();
  showTimerMessage("", "");
  showTimerStage("setup");
  announce("Debrief discarded.");
}

function postTimerDebrief(event) {
  event.preventDefault();

  var integ = timerState.integration;
  var item = timerState.item;
  if (!integ || !item) {
    return;
  }

  var debrief = timerFieldValue("timer-debrief-text");
  var next = timerFieldValue("timer-next-text");
  if (!debrief.trim() && !next.trim()) {
    showTimerMessage("bad", "Enter a debrief or a next step before posting.");
    return;
  }

  var resolveNode = document.getElementById("timer-resolve");
  var resolve = !!(resolveNode && resolveNode.checked);
  var elapsed = timerState.total - timerState.remaining;

  var payload = {
    integration: integ.name,
    id: item.id,
    title: item.title,
    totalSeconds: timerState.total,
    elapsedSeconds: elapsed,
    interrupted: timerState.interrupted,
    debrief: debrief,
    next: next,
    resolve: resolve
  };

  setTimerPostBusy(true);
  showTimerMessage("busy", "Posting debrief…");
  announce("Posting debrief.");

  postCreateJson(TIMER_API + "post", payload).then(function (res) {
    renderTimerResult(res);
  }).catch(function () {
    showTimerMessage("bad", "Post failed — the daily-viewer server isn't reachable. Start it with az-Start-AzDevOpsDailyViewer.");
  }).then(function () {
    setTimerPostBusy(false);
  });
}

function renderTimerResult(res) {
  timerResult.textContent = "";

  var data = res.data;
  if (!data) {
    showTimerMessage("bad", "Post failed (HTTP " + res.status + ").");
    return;
  }

  if (!data.ok) {
    showTimerMessage("bad", data.error || "Post failed.");
    return;
  }

  var line = "Debrief posted on #" + data.id + ".";
  if (data.resolved) {
    line += " Item resolved.";
  } else if (data.resolveError) {
    line += " " + data.resolveError;
  }

  timerResult.appendChild(el("div", { class: "create-banner good" }, [ line ]));
  announce(line);

  // Three-way restart — the browser mirror of the terminal Read-TimerNextAction
  // choice: reuse the same item, return to the picker, or finish.
  var again = el("div", { class: "timer-again" }, [
    timerActionButton("Same item", function () { restartTimer(true); }),
    timerActionButton("Pick another", function () { restartTimer(false); }),
    timerActionButton("Done", finishTimerSession)
  ]);
  timerResult.appendChild(again);
}

function restartTimer(sameItem) {
  resetTimerDebriefFields();
  showTimerMessage("", "");

  if (!sameItem) {
    showTimerStage("setup");
    announce("Pick another item.");
    var sel = document.getElementById("timer-item-select");
    if (sel) {
      sel.focus();
    }
    return;
  }

  timerState.total = timerState.minutes * 60;
  runTimerCountdown();
  announce("New session started for the same item.");
}

function finishTimerSession() {
  resetTimerDebriefFields();
  showTimerMessage("", "");
  showTimerStage("setup");
  announce("Timer session finished.");
}


// --- lazy init + options load ---

function loadTimerOptions() {
  return fetchJson(TIMER_API + "options", { headers: { "Accept": "application/json" } })
    .then(function (data) {
      timerState.integrations = (data && data.integrations) || [];
      if (data && data.defaultMinutes) {
        timerState.defaultMinutes = data.defaultMinutes;
      }
    })
    .catch(function () {
      timerState.integrations = [];
    });
}

function ensureTimerPanel() {
  if (timerState.initialized) {
    return;
  }
  timerState.initialized = true;

  timerSetup.addEventListener("submit", startTimer);
  document.getElementById("timer-add5").addEventListener("click", addTimerMinutes);
  document.getElementById("timer-endnow").addEventListener("click", function () { finishTimer(true); });
  document.getElementById("timer-cancel").addEventListener("click", cancelTimer);
  timerDebrief.addEventListener("submit", postTimerDebrief);
  document.getElementById("timer-discard").addEventListener("click", discardTimerDebrief);

  loadTimerOptions().then(function () {
    renderTimerFields();
  });
}


// ---------------------------------------------------------------------------
// Draft mode — the brain-dump hierarchy builder (Epic #228 sub-issue C). The
// tree renders from GET /api/draft/state (a flat item list the client nests by
// parentRef); add / edit / remove / clear / publish POST to /api/draft/* and
// return the refreshed state so one round-trip repaints. Area / iteration /
// parent choices reuse the create-mode options. Every drafted title reaches the
// DOM through el() (textContent), so an untrusted Azure DevOps title stays inert.
// ---------------------------------------------------------------------------

var DRAFT_API = "/api/draft/";
var DRAFT_TYPES = ["Epic", "Feature", "User Story", "Task"];

// The tier a given type nests under (null = a root tier) and, inversely, the
// child tier it spawns — mirrors the backend's Get-AzDevOpsDraftParentType so the
// browser offers the same parent candidates and "+ child" affordances.
var DRAFT_PARENT_TYPE = { "Epic": null, "Feature": "Epic", "User Story": "Feature", "Task": "User Story" };
var DRAFT_CHILD_TYPE = { "Epic": "Feature", "Feature": "User Story", "User Story": "Task", "Task": null };

// Priority as a select, with a leading "Not set" so a drafted item can stay
// unset (which lowers its completeness) rather than defaulting to a value — the
// backend keeps -1 for unset too.
var DRAFT_PRIORITY_OPTIONS = [{ value: "", label: "Not set" }].concat(PRIORITY_OPTIONS);

// editingNode holds the item being edited (add mode when null), so a Save re-uses
// its ref and only re-parents when the parent select actually changed.
var draftState = { initialized: false, tree: null, editingNode: null };

var draftForm = document.getElementById("draft-form");
var draftFields = document.getElementById("draft-fields");
var draftSubmit = document.getElementById("draft-submit");
var draftCancelEdit = document.getElementById("draft-cancel-edit");
var draftFormTitle = document.getElementById("draft-form-title");
var draftTree = document.getElementById("draft-tree");
var draftSummary = document.getElementById("draft-summary");
var draftResult = document.getElementById("draft-result");
var draftPublishFields = document.getElementById("draft-publish-fields");
var draftPublishBtn = document.getElementById("draft-publish-btn");
var draftClearBtn = document.getElementById("draft-clear-btn");


// --- add / edit form ---

function isStoryType(type) {
  return type === "User Story";
}

// Parent candidates for a child type: the current draft items one tier up, keyed
// by their local ref. Existing-Azure parents aren't offered here — building the
// hierarchy inside the draft (or leaving an item top-level) is the browser flow.
function draftParentOptions(childType) {
  var expected = DRAFT_PARENT_TYPE[childType];
  if (!expected || !draftState.tree) {
    return [];
  }

  var items = asArray(draftState.tree.items);
  return items.filter(function (it) {
    return it.type === expected;
  }).map(function (it) {
    return { value: String(it.ref), label: "#" + it.ref + CREATE_DASH + it.title };
  });
}

// Build the add/edit fields for a type. In edit mode the type select is disabled
// (az-Set can't retype an item) and the fields prefill from the node.
function renderDraftFields(type, preselectParentRef) {
  var node = draftState.editingNode;
  var editing = !!node;

  var typeSelect = buildSelect(stringOptionModels(DRAFT_TYPES), null, { id: "d-type" });
  typeSelect.value = type;
  if (editing) {
    typeSelect.disabled = true;
  } else {
    typeSelect.addEventListener("change", function () {
      renderDraftFields(typeSelect.value);
    });
  }

  var fields = [ labeledField("d-type", "Type", typeSelect) ];

  var titleInput = el("input", { id: "d-title", type: "text", maxlength: "255", autocomplete: "off" });
  if (editing) {
    titleInput.value = node.title;
  }
  fields.push(labeledField("d-title", "Title", titleInput));

  var descInput = el("textarea", { id: "d-description", rows: "3" });
  if (editing) {
    descInput.value = node.description;
  }
  fields.push(labeledField("d-description", "Description", descInput));

  var prioritySelect = buildSelect(DRAFT_PRIORITY_OPTIONS, null, { id: "d-priority" });
  prioritySelect.value = (editing && node.priority >= 1 && node.priority <= 4) ? String(node.priority) : "";
  fields.push(labeledField("d-priority", "Priority", prioritySelect));

  if (isStoryType(type)) {
    var pointsInput = el("input", { id: "d-points", type: "number", min: "0", step: "1", inputmode: "numeric" });
    if (editing && node.storyPoints >= 0) {
      pointsInput.value = String(node.storyPoints);
    }
    fields.push(labeledField("d-points", "Story points", pointsInput, "Leave blank to omit."));

    var acceptanceInput = el("textarea", { id: "d-acceptance", rows: "3" });
    if (editing) {
      acceptanceInput.value = node.acceptanceCriteria;
    }
    fields.push(labeledField("d-acceptance", "Acceptance criteria", acceptanceInput));
  }

  if (DRAFT_PARENT_TYPE[type]) {
    var parentSelect = buildSelect(draftParentOptions(type), "No parent (top level)", { id: "d-parent" });
    var wantParent = (preselectParentRef !== undefined && preselectParentRef !== null)
      ? String(preselectParentRef)
      : (editing && node.parentRef > 0 ? String(node.parentRef) : "");
    parentSelect.value = wantParent;
    fields.push(labeledField("d-parent", "Parent " + DRAFT_PARENT_TYPE[type], parentSelect,
      "Nests this item under a " + DRAFT_PARENT_TYPE[type] + " already in the draft."));
  }

  draftFields.textContent = "";
  fields.forEach(function (field) {
    draftFields.appendChild(field);
  });
}

function draftFormMode(editing) {
  draftFormTitle.textContent = editing ? "Edit item" : "Add an item";
  draftSubmit.textContent = editing ? "Save changes" : "Add to draft";
  draftCancelEdit.hidden = !editing;
}

function startAddChild(node, childType) {
  draftState.editingNode = null;
  draftFormMode(false);
  showDraftMessage("", "");
  renderDraftFields(childType, node.ref);

  draftForm.scrollIntoView({ block: "nearest" });
  var title = document.getElementById("d-title");
  if (title) {
    title.focus();
  }
}

function startEditItem(node) {
  draftState.editingNode = node;
  draftFormMode(true);
  showDraftMessage("", "");
  renderDraftFields(node.type);

  draftForm.scrollIntoView({ block: "nearest" });
  var title = document.getElementById("d-title");
  if (title) {
    title.focus();
  }
}

function cancelDraftEdit() {
  draftState.editingNode = null;
  draftFormMode(false);
  showDraftMessage("", "");
  renderDraftFields(DRAFT_TYPES[0]);
}


// --- tree render ---

function draftBand(percent) {
  if (percent >= 100) {
    return "ready";
  }
  if (percent >= 50) {
    return "partial";
  }
  return "low";
}

function draftNodeActions(node) {
  var actions = [];

  var edit = el("button", { type: "button", class: "btn tiny" }, [ "Edit" ]);
  edit.addEventListener("click", function (e) {
    e.preventDefault();
    e.stopPropagation();
    startEditItem(node);
  });
  actions.push(edit);

  var childType = DRAFT_CHILD_TYPE[node.type];
  if (childType) {
    var add = el("button", { type: "button", class: "btn tiny" }, [ "+ " + childType ]);
    add.addEventListener("click", function (e) {
      e.preventDefault();
      e.stopPropagation();
      startAddChild(node, childType);
    });
    actions.push(add);
  }

  var remove = el("button", { type: "button", class: "btn tiny danger", "aria-label": "Remove item #" + node.ref }, [ "Remove" ]);
  remove.addEventListener("click", function (e) {
    e.preventDefault();
    e.stopPropagation();
    removeDraftItem(node);
  });
  actions.push(remove);

  return el("div", { class: "draft-node-actions" }, actions);
}

function draftRowContent(node, hasChildren) {
  var children = [];

  if (hasChildren) {
    children.push(chevron());
  }

  children.push(el("span", { class: "type " + (TYPE_CLASS[node.type] || ""), text: node.type }));
  children.push(el("span", { class: "draft-ref", text: "#" + node.ref }));
  children.push(el("span", { class: "draft-title", text: node.title }));

  var missing = asArray(node.missing);
  var pctTitle = missing.length ? "Missing: " + missing.join(", ") : "Ready to publish";
  children.push(el("span", { class: "draft-pct " + draftBand(node.percent), text: node.percent + "%", title: pctTitle }));

  if (missing.length) {
    children.push(el("span", { class: "draft-missing", text: "missing: " + missing.join(", ") }));
  }

  return children;
}

// One tree node. childMap groups items by parentRef; `visited` guards a re-parent
// that produced a cycle so recursion can't spin. Nodes with children collapse via
// native <details>/<summary>; the action buttons sit OUTSIDE the summary (a sibling
// of <details> in a flex wrap) so they're valid interactive content and don't
// inflate the disclosure's accessible name — leaf rows carry the same buttons
// inline since they have no summary.
function draftTreeNode(node, childMap, visited) {
  if (visited[node.ref]) {
    return null;
  }
  visited[node.ref] = true;

  var kids = childMap[node.ref] || [];
  var hasChildren = kids.length > 0;
  var rowChildren = draftRowContent(node, hasChildren);

  if (!hasChildren) {
    return el("li", { class: "draft-node" }, [
      el("div", { class: "draft-row is-leaf" }, rowChildren.concat([ draftNodeActions(node) ]))
    ]);
  }

  var summary = el("summary", { class: "draft-row" }, rowChildren);
  var childList = el("ul", { class: "draft-children" }, kids.map(function (kid) {
    return draftTreeNode(kid, childMap, visited);
  }));

  return el("li", { class: "draft-node" }, [
    el("div", { class: "draft-row-wrap" }, [
      el("details", { open: "" }, [ summary, childList ]),
      draftNodeActions(node)
    ])
  ]);
}

function renderDraftTree() {
  draftTree.textContent = "";

  var tree = draftState.tree;
  var items = tree ? asArray(tree.items) : [];

  if (items.length === 0) {
    draftTree.appendChild(el("p", { class: "draft-empty", text: "The draft is empty — add an item below to start a hierarchy." }));
    return;
  }

  var childMap = {};
  items.forEach(function (it) {
    if (it.parentRef > 0) {
      if (!childMap[it.parentRef]) {
        childMap[it.parentRef] = [];
      }
      childMap[it.parentRef].push(it);
    }
  });

  var visited = {};
  var roots = items.filter(function (it) {
    return it.isRoot;
  });

  var list = el("ul", { class: "draft-root" }, roots.map(function (root) {
    return draftTreeNode(root, childMap, visited);
  }));
  draftTree.appendChild(list);
}

function renderDraftSummary() {
  var tree = draftState.tree;
  if (!tree || tree.count === 0) {
    draftSummary.textContent = "Draft is empty.";
    return;
  }

  var ready = tree.readyCount + " ready to publish";
  draftSummary.textContent = tree.count + " item" + (tree.count === 1 ? "" : "s") +
    CREATE_MIDDOT + "avg " + tree.avgPercent + "% complete" + CREATE_MIDDOT + ready;
}


// --- messages, mutations, publish ---

function showDraftMessage(kind, text) {
  draftResult.textContent = "";
  if (!text) {
    return;
  }
  draftResult.appendChild(el("div", { class: "create-banner " + kind }, [ text ]));
}

// Apply a mutation response: refresh the tree from the returned state and reset
// the add form (so its parent options reflect the new tree), or surface the
// endpoint's error text.
function applyDraftResponse(res) {
  var data = res.data;
  if (!data) {
    showDraftMessage("bad", "Draft update failed (HTTP " + res.status + ").");
    return false;
  }

  if (!data.ok) {
    showDraftMessage("bad", data.error || "Draft update failed.");
    return false;
  }

  draftState.tree = data.draft;
  renderDraftTree();
  renderDraftSummary();
  return true;
}

function collectDraftPayload(type) {
  var payload = {
    title: fieldValue("d-title").trim(),
    description: fieldValue("d-description"),
    priority: fieldValue("d-priority")
  };

  if (isStoryType(type)) {
    payload.storyPoints = fieldValue("d-points");
    payload.acceptanceCriteria = fieldValue("d-acceptance");
  }

  return payload;
}

function submitDraftItem(event) {
  event.preventDefault();

  var node = draftState.editingNode;
  var type = node ? node.type : fieldValue("d-type");
  var payload = collectDraftPayload(type);

  if (!payload.title) {
    showDraftMessage("bad", "Title is required.");
    return;
  }

  var parentControl = document.getElementById("d-parent");
  var newParentRef = (parentControl && parentControl.value) ? parseInt(parentControl.value, 10) : 0;
  var url;

  if (node) {
    payload.ref = node.ref;

    // Only touch the parent when the select actually changed, so an item whose
    // parent the browser can't offer (an existing Azure parent) isn't orphaned.
    if (DRAFT_PARENT_TYPE[type] && newParentRef !== node.parentRef) {
      if (newParentRef > 0) {
        payload.parentRef = String(newParentRef);
      } else {
        payload.orphan = true;
      }
    }
    url = DRAFT_API + "set";
  } else {
    payload.type = type;
    if (newParentRef > 0) {
      payload.parentRef = String(newParentRef);
    }
    url = DRAFT_API + "add";
  }

  draftSubmit.disabled = true;
  showDraftMessage("busy", node ? "Saving…" : "Adding…");

  postCreateJson(url, payload).then(function (res) {
    if (applyDraftResponse(res)) {
      draftState.editingNode = null;
      draftFormMode(false);
      showDraftMessage("", "");
      renderDraftFields(DRAFT_TYPES[0]);
      announce(node ? "Draft item saved." : "Item added to draft.");
    }
  }).catch(function () {
    showDraftMessage("bad", "Draft update failed — the daily-viewer server isn't reachable. Start it with az-Start-AzDevOpsDailyViewer.");
  }).then(function () {
    draftSubmit.disabled = false;
  });
}

function removeDraftItem(node) {
  showDraftMessage("busy", "Removing…");

  postCreateJson(DRAFT_API + "remove", { ref: node.ref }).then(function (res) {
    if (applyDraftResponse(res)) {
      // The removed item may have been the one being edited.
      if (draftState.editingNode && draftState.editingNode.ref === node.ref) {
        draftState.editingNode = null;
        draftFormMode(false);
        renderDraftFields(DRAFT_TYPES[0]);
      }
      showDraftMessage("", "");
      announce("Draft item removed.");
    }
  }).catch(function () {
    showDraftMessage("bad", "Remove failed — the daily-viewer server isn't reachable.");
  });
}

function clearDraft() {
  showDraftMessage("busy", "Clearing…");

  postCreateJson(DRAFT_API + "clear", {}).then(function (res) {
    if (applyDraftResponse(res)) {
      draftState.editingNode = null;
      draftFormMode(false);
      renderDraftFields(DRAFT_TYPES[0]);
      showDraftMessage("", "");
      announce("Draft cleared.");
    }
  }).catch(function () {
    showDraftMessage("bad", "Clear failed — the daily-viewer server isn't reachable.");
  });
}


// --- publish ---

function renderDraftPublishFields() {
  var opts = createState.options || {};

  var areaSelect = buildSelect(stringOptionModels(opts.areas), "Select an area…", { id: "d-area" });
  if (opts.defaultArea) {
    areaSelect.value = opts.defaultArea;
  }

  var iterationSelect = buildSelect(stringOptionModels(opts.iterations), "Select an iteration…", { id: "d-iteration" });
  if (opts.defaultIteration) {
    iterationSelect.value = opts.defaultIteration;
  }

  draftPublishFields.textContent = "";
  draftPublishFields.appendChild(labeledField("d-area", "Area path", areaSelect));
  draftPublishFields.appendChild(labeledField("d-iteration", "Iteration path", iterationSelect));
}

// One published-item line: a link to the new work item (title is untrusted, so it
// lands via el() text). Mirrors the create surface's createdLine vocabulary.
function draftPublishedLine(row) {
  var label = "Published " + row.type + " #" + row.id;
  var children = [];

  if (row.url) {
    children.push(externalLink(label, row.url, "create-link"));
  } else {
    children.push(el("span", { text: label }));
  }

  if (row.title) {
    children.push(el("span", { class: "create-item-title", text: CREATE_DASH + row.title }));
  }

  if (row.linked === false && row.linkError) {
    children.push(el("span", { class: "create-warn", text: " (created, but parent link failed: " + row.linkError + ")" }));
  }

  return el("li", { class: "create-item good" }, children);
}

function draftFailedLine(row) {
  var label = row.type + CREATE_DASH + row.title + ": " + (row.reason || "create failed");
  return el("li", { class: "create-item bad" }, [ label ]);
}

function renderDraftPublishResult(res) {
  draftResult.textContent = "";

  var data = res.data;
  if (!data) {
    showDraftMessage("bad", "Publish failed (HTTP " + res.status + ").");
    return;
  }

  var published = asArray(data.published);
  var failed = asArray(data.failed);

  if (!published.length && !failed.length) {
    showDraftMessage("bad", data.error || "Publish failed.");
    return;
  }

  var summary = published.length + " published" + (failed.length ? ", " + failed.length + " failed/skipped" : "");
  var bannerKind = failed.length ? "create-banner bad" : "create-banner";
  draftResult.appendChild(el("div", { class: bannerKind }, [ summary ]));

  var list = el("ul", { class: "create-list" }, []);
  published.forEach(function (row) {
    list.appendChild(draftPublishedLine(row));
  });
  failed.forEach(function (row) {
    list.appendChild(draftFailedLine(row));
  });
  draftResult.appendChild(list);

  if (data.draft) {
    draftState.tree = data.draft;
    renderDraftTree();
    renderDraftSummary();
  }

  announce(summary + ".");
}

function publishDraft() {
  var area = fieldValue("d-area");
  var iteration = fieldValue("d-iteration");

  if (!area || !iteration) {
    showDraftMessage("bad", "Select an area and iteration to publish.");
    return;
  }

  if (!draftState.tree || draftState.tree.count === 0) {
    showDraftMessage("bad", "The draft is empty — add items before publishing.");
    return;
  }

  draftPublishBtn.disabled = true;
  showDraftMessage("busy", "Publishing…");

  postCreateJson(DRAFT_API + "publish", { area: area, iteration: iteration }).then(function (res) {
    renderDraftPublishResult(res);
  }).catch(function () {
    showDraftMessage("bad", "Publish failed — the daily-viewer server isn't reachable. Start it with az-Start-AzDevOpsDailyViewer.");
  }).then(function () {
    draftPublishBtn.disabled = false;
  });
}


// --- initial load ---

// Read-only snapshot; an empty tree on any failure so the panel renders (offline
// mock) — a mutation then surfaces the not-reachable message.
function loadDraftState() {
  return fetchJson(DRAFT_API + "state", { headers: { "Accept": "application/json" } })
    .then(function (data) {
      draftState.tree = data;
    })
    .catch(function () {
      draftState.tree = { items: [], count: 0, avgPercent: 0, readyCount: 0 };
    })
    .then(function () {
      renderDraftTree();
      renderDraftSummary();
    });
}

// Wire + render once, the first time the Draft sub-tab is shown.
function ensureDraftPanel() {
  if (draftState.initialized) {
    return;
  }
  draftState.initialized = true;

  draftForm.addEventListener("submit", submitDraftItem);
  draftCancelEdit.addEventListener("click", cancelDraftEdit);
  draftPublishBtn.addEventListener("click", publishDraft);
  draftClearBtn.addEventListener("click", clearDraft);

  // Publish fields need the options; the add form's parent select needs the
  // loaded tree — so render fields only after the state read settles.
  ensureCreateOptions().then(function () {
    renderDraftPublishFields();
    return loadDraftState();
  }).then(function () {
    renderDraftFields(DRAFT_TYPES[0]);
  });
}


// Apply the initial mode from the hash so a deep link to #create opens Create.
// Silent: the boot sync shouldn't announce a mode change the user didn't make.
setMode(modeFromHash(), true);


// Live filter across every work-item and event row. Remembers each tile's
// original open/closed state (recorded lazily, since rows render async) so
// clearing the box restores the layout the data produced.
function rememberOpenState() {
  document.querySelectorAll("details").forEach(function (d) {
    if (d.dataset.open0 === undefined) {
      d.dataset.open0 = d.open ? "1" : "0";
    }
  });
}

function applyFilter(raw) {
  var q = raw.trim().toLowerCase();
  var allDetails = document.querySelectorAll("details");

  if (q) {
    allDetails.forEach(function (d) { d.open = true; });
  } else {
    allDetails.forEach(function (d) { d.open = d.dataset.open0 === "1"; });
  }

  var matchTotal = 0;

  document.querySelectorAll(".tile").forEach(function (t) {
    var rows = t.querySelectorAll(ROW_SELECTOR);
    var anyVisible = false;

    rows.forEach(function (row) {
      var match = !q || row.textContent.toLowerCase().indexOf(q) !== -1;
      row.classList.toggle("hide", !match);
      if (match) {
        anyVisible = true;
        matchTotal++;
      }
    });

    t.querySelectorAll(".group").forEach(function (group) {
      var visible = group.querySelectorAll(".wi:not(.hide), .event:not(.hide)").length;
      group.classList.toggle("hide", !!q && visible === 0);
    });

    t.classList.toggle("empty", !!q && !anyVisible);
  });

  if (q) {
    announce(matchTotal + (matchTotal === 1 ? " item matches." : " items match."));
  }
}

var searchBox = document.getElementById("search");
searchBox.addEventListener("input", function () { applyFilter(searchBox.value); });
searchBox.addEventListener("keydown", function (e) {
  if (e.key === "Escape") {
    searchBox.value = "";
    applyFilter("");
  }
});


// Header date — rendered live so the dashboard always names the current day,
// replacing the static fallback baked into the markup for the JS-off case.
function paintTodayDate() {
  var node = document.getElementById("today-date");
  if (!node) {
    return;
  }

  var today = new Date();
  node.textContent = today.toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric" });
}

paintTodayDate();


// ---------------------------------------------------------------------------
// Boot — cache-first, then an independent background refresh per tile. Each
// composite paints from its cache read first (instant, no blank screen), then
// auto-triggers its own refresh through the existing refresh path so a stale
// tile freshens up on its own spinner without blocking or resetting the other.
// ---------------------------------------------------------------------------

// Kick a tile's background refresh on open, gated by staleness: refresh only
// when at least one of its panels came back stale (reusing the server's own
// `data.stale` flag, so the frontend invents no threshold). A tile whose panels
// are all fresh stays put — no spinner, no redundant az/Outlook call. A tile
// that fell back to the sample model (data === null, backend unreachable) is
// left as sample rather than firing a doomed refresh, matching today's offline
// preview. Reuses refreshTile → refreshComposite, so the spinner lifecycle,
// aria-live announcements, and per-panel repaint are the existing ones — no new
// refresh engine. Returns whether a refresh was started.
function autoRefreshOnOpen(composite) {
  var needsRefresh = composite.panels.some(function (panel) {
    var data = (panelState[panel.key] || {}).data;
    return data && data.stale === true;
  });

  if (!needsRefresh) {
    return false;
  }

  var btn = tile(composite.key).querySelector(".refresh-btn");
  if (!btn) {
    return false;
  }

  refreshTile(btn);
  return true;
}

var bootLoads = COMPOSITES.map(function (composite) {
  return loadComposite(composite).then(function (allBackend) {
    rememberOpenState();

    autoRefreshOnOpen(composite);
    return allBackend;
  });
});

Promise.all(bootLoads).then(function (results) {
  // Screen-reader parity with the refresh path: if a tile couldn't reach the
  // backend and fell back to the sample model, say so once (not per tile). A
  // fallen-back tile never auto-refreshes (its refresh would be doomed), so a
  // sibling tile that is refreshing can't starve this notice — that tile
  // announces its own progress and settles independently.
  if (results.indexOf(false) !== -1) {
    announce("Showing sample data — the daily-viewer server isn't reachable.");
  }
});
