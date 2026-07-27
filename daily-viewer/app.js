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
    setupCreatorOnce();
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
// Create surface — data-driven work-item forms (Epic #228, sub-issue B). Each
// type's form is rendered from a field spec, not hand-authored per field. The
// area / iteration / parent pickers are <select>s populated from
// POST /api/create/options (the same classification + hierarchy cache the
// terminal pickers read), so there's no free-text where the terminal offers a
// pick. Every option label and result string reaches the DOM through el()
// (textContent / setAttribute) — so an Azure DevOps title or path renders inert,
// no innerHTML path. Submit POSTs /api/create/workitem; the reply's new id/url
// shows as an escaped external link with a "Create another".
// ---------------------------------------------------------------------------

var PRIORITY_OPTIONS = [
  { value: "1", text: "1 — Low" },
  { value: "2", text: "2 — Medium" },
  { value: "3", text: "3 — High" },
  { value: "4", text: "4 — Super high" }
];
var DEFAULT_PRIORITY = "2";
var TITLE_MAX = 255;
var ORPHAN_LABEL = "(No parent — orphan)";

// Field catalog — one descriptor per field, referenced by the per-type field
// lists so each field is defined once and reused across types. `kind` picks the
// control the builder renders; `required` drives the client-side check that
// mirrors the server validator.
var CREATE_FIELD_DEFS = {
  title: { label: "Title", kind: "text", required: true },
  description: { label: "Description", kind: "textarea" },
  priority: { label: "Priority", kind: "priority", required: true },
  storyPoints: { label: "Story points", kind: "number" },
  acceptanceCriteria: { label: "Acceptance criteria", kind: "textarea", help: "One criterion per line." },
  parent: { label: "Parent", kind: "parent" },
  area: { label: "Area path", kind: "area", required: true },
  iteration: { label: "Iteration path", kind: "iteration", required: true }
};

// Per-type form spec — the field order, which parent bucket the parent picker
// reads, and (Feature + Stories) the child-Story repeater. Mirrors the terminal
// creators: Epic is top-level (no parent); Feature parents to an Epic; Story to a
// Feature; Task to a Story.
var CREATE_TYPES = [
  { slug: "story", label: "User Story", parentBucket: "feature", parentLabel: "Parent Feature",
    fields: ["title", "description", "priority", "storyPoints", "acceptanceCriteria", "parent", "area", "iteration"] },
  { slug: "feature", label: "Feature", parentBucket: "epic", parentLabel: "Parent Epic",
    fields: ["title", "description", "priority", "parent", "area", "iteration"] },
  { slug: "epic", label: "Epic", parentBucket: null,
    fields: ["title", "description", "priority", "area", "iteration"] },
  { slug: "task", label: "Task", parentBucket: "story", parentLabel: "Parent Story",
    fields: ["title", "description", "priority", "parent", "area", "iteration"] },
  { slug: "feature-stories", label: "Feature + Stories", parentBucket: "epic", parentLabel: "Parent Epic",
    fields: ["title", "description", "priority", "parent", "area", "iteration"], stories: true }
];

var CREATE_TYPE_BY_SLUG = {};
CREATE_TYPES.forEach(function (t) { CREATE_TYPE_BY_SLUG[t.slug] = t; });

// A child Story in the Feature + Stories batch carries its own fields; parent /
// area / iteration are inherited from the Feature, so they're absent here.
var STORY_FIELDS = ["title", "priority", "storyPoints", "description", "acceptanceCriteria"];

var creatorReady = false;
var creatorBackendOk = false;
var creatorOptions = {
  areas: [], iterations: [],
  parents: { epic: [], feature: [], story: [] },
  defaults: { area: "", iteration: "" }
};

var typeSelect = null;
var currentFields = [];
var storyCards = [];
var storiesWrap = null;
var storySeq = 0;


// Read the create endpoints, parsing the JSON body even on a non-2xx so a
// field-level validation error (400 { error, field }) is available to the caller
// — fetchJson throws bare on !ok and would lose it.
function postCreate(path, payload) {
  return fetch(CREATE_API + path, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Accept": "application/json" },
    body: JSON.stringify(payload)
  }).then(function (res) {
    return res.json().then(function (data) {
      return { ok: res.ok, status: res.status, data: data };
    }, function () {
      return { ok: res.ok, status: res.status, data: {} };
    });
  });
}


// --- option / choice builders ---------------------------------------------

function optionEl(value, text, selected) {
  var node = el("option", { value: value, text: text });
  if (selected) {
    node.setAttribute("selected", "");
  }
  return node;
}

function buildSelect(id, name, choices, selectedValue) {
  var select = el("select", { id: id, name: name, class: "control" });

  choices.forEach(function (choice) {
    var isSel = selectedValue != null && choice.value === selectedValue;
    select.appendChild(optionEl(choice.value, choice.text, isSel));
  });

  return select;
}

function pathChoices(paths) {
  return asArray(paths).map(function (p) {
    return { value: String(p), text: String(p) };
  });
}

function choicesOrPlaceholder(choices, placeholder) {
  if (choices.length === 0) {
    return [ { value: "", text: placeholder } ];
  }
  return choices;
}

// Parent options are the open Epics / Features / Stories from the hierarchy
// cache, plus an orphan choice (value 0). Titles are untrusted, but el() sets
// them via textContent, so a title with markup renders inert in the <option>.
function parentChoices(bucket) {
  var rows = asArray(creatorOptions.parents[bucket]);

  var choices = [ { value: "0", text: ORPHAN_LABEL } ];
  rows.forEach(function (row) {
    choices.push({ value: String(row.id), text: "#" + row.id + " — " + row.title + " [" + row.state + "]" });
  });

  return choices;
}


// --- field builder ---------------------------------------------------------

// Build one form field from its catalog descriptor and return a small controller
// (value / setError / clearError) so validation and collection can drive it
// without re-querying the DOM. `idPrefix` namespaces the ids so repeated Story
// cards don't collide; `typeSpec` supplies the parent bucket / label.
function buildCreateField(name, idPrefix, typeSpec) {
  var def = CREATE_FIELD_DEFS[name];
  var id = idPrefix + name;

  var control;
  if (def.kind === "text") {
    control = el("input", { id: id, name: name, type: "text", class: "control", maxlength: String(TITLE_MAX), autocomplete: "off" });
  } else if (def.kind === "number") {
    control = el("input", { id: id, name: name, type: "number", class: "control", min: "0", step: "1", inputmode: "numeric" });
  } else if (def.kind === "textarea") {
    control = el("textarea", { id: id, name: name, class: "control", rows: "3" });
  } else if (def.kind === "priority") {
    control = buildSelect(id, name, PRIORITY_OPTIONS, DEFAULT_PRIORITY);
  } else if (def.kind === "parent") {
    control = buildSelect(id, name, parentChoices(typeSpec.parentBucket), "0");
  } else if (def.kind === "area") {
    control = buildSelect(id, name, choicesOrPlaceholder(pathChoices(creatorOptions.areas), "Select an area…"), creatorOptions.defaults.area || "");
  } else if (def.kind === "iteration") {
    control = buildSelect(id, name, choicesOrPlaceholder(pathChoices(creatorOptions.iterations), "Select an iteration…"), creatorOptions.defaults.iteration || "");
  }

  control.setAttribute("aria-describedby", id + "-error");

  var labelText = (name === "parent" && typeSpec && typeSpec.parentLabel) ? typeSpec.parentLabel : def.label;
  var labelChildren = [ labelText ];
  if (def.required) {
    labelChildren.push(el("span", { class: "req", "aria-hidden": "true", text: " *" }));
  }
  var label = el("label", { for: id }, labelChildren);

  var children = [ label, control ];
  if (def.help) {
    children.push(el("p", { class: "field-help", text: def.help }));
  }

  var error = el("p", { class: "field-error", id: id + "-error" });
  error.hidden = true;
  children.push(error);

  var wrap = el("div", { class: "field" }, children);

  return {
    name: name,
    def: def,
    wrap: wrap,
    control: control,
    value: function () { return control.value; },
    setError: function (message) {
      error.textContent = message;
      error.hidden = false;
      control.setAttribute("aria-invalid", "true");
      wrap.classList.add("invalid");
    },
    clearError: function () {
      error.textContent = "";
      error.hidden = true;
      control.removeAttribute("aria-invalid");
      wrap.classList.remove("invalid");
    }
  };
}


// --- validation (mirrors the server validators) ----------------------------

function validateField(field) {
  var raw = field.value();
  var val = (typeof raw === "string") ? raw.trim() : raw;

  if (field.name === "title") {
    if (!val) {
      return "Title is required.";
    }
    if (val.length > TITLE_MAX) {
      return "Title must be " + TITLE_MAX + " characters or fewer.";
    }
    return null;
  }

  if (field.name === "priority") {
    var p = parseInt(val, 10);
    if (!(p >= 1 && p <= 4)) {
      return "Priority must be from 1 to 4.";
    }
    return null;
  }

  if (field.name === "storyPoints") {
    if (val !== "") {
      var sp = Number(val);
      if (!Number.isInteger(sp) || sp < 0) {
        return "Story points must be a non-negative whole number.";
      }
    }
    return null;
  }

  if (field.def.required && !val) {
    return field.def.label + " is required.";
  }

  return null;
}


// Validate every top-level field and every non-blank Story card (a Story with no
// title is skipped, matching the terminal batch). Returns the first field that
// failed so the caller can move focus to it.
function validateAll(typeSpec) {
  var firstBad = null;

  currentFields.forEach(function (field) {
    field.clearError();
    var message = validateField(field);
    if (message) {
      field.setError(message);
      if (!firstBad) {
        firstBad = field;
      }
    }
  });

  if (typeSpec.stories) {
    storyCards.forEach(function (card) {
      var hasTitle = (storyCardTitle(card) || "").trim() !== "";

      card.fields.forEach(function (field) {
        field.clearError();
        if (!hasTitle) {
          return;
        }
        var message = validateField(field);
        if (message) {
          field.setError(message);
          if (!firstBad) {
            firstBad = field;
          }
        }
      });
    });
  }

  return firstBad;
}


// --- Story repeater (Feature + Stories) ------------------------------------

function storyCardTitle(card) {
  return card.fields.length ? card.fields[0].value() : "";
}

function renumberStories() {
  storyCards.forEach(function (card, i) {
    var badge = card.node.querySelector(".story-index");
    if (badge) {
      badge.textContent = "Story " + (i + 1);
    }
  });
}

function removeStoryCard(card) {
  var i = storyCards.indexOf(card);
  if (i === -1) {
    return;
  }

  storyCards.splice(i, 1);
  card.node.remove();
  renumberStories();
  announce("Story removed.");
}

function addStoryCard() {
  var idPrefix = "cs-" + storySeq + "-";
  storySeq++;

  var fields = STORY_FIELDS.map(function (name) {
    return buildCreateField(name, idPrefix, null);
  });

  var removeBtn = el("button", { type: "button", class: "btn ghost", text: "Remove" });
  var head = el("div", { class: "story-head" }, [
    el("span", { class: "story-index" }),
    removeBtn
  ]);
  var body = el("div", { class: "story-fields" }, fields.map(function (f) { return f.wrap; }));
  var node = el("div", { class: "story-card" }, [ head, body ]);

  var card = { node: node, fields: fields };
  removeBtn.addEventListener("click", function () { removeStoryCard(card); });

  storyCards.push(card);
  storiesWrap.appendChild(node);
  renumberStories();

  return card;
}


// --- form assembly ---------------------------------------------------------

function renderCreateForm(typeSpec) {
  currentFields = typeSpec.fields.map(function (name) {
    return buildCreateField(name, "cf-", typeSpec);
  });

  var fieldsWrap = document.getElementById("create-fields");
  fieldsWrap.textContent = "";
  currentFields.forEach(function (field) {
    fieldsWrap.appendChild(field.wrap);
  });

  var storiesSection = document.getElementById("create-stories");
  storiesSection.textContent = "";
  storyCards = [];

  if (typeSpec.stories) {
    storiesWrap = el("div", { class: "stories-list" });

    var addBtn = el("button", { type: "button", class: "btn ghost", text: "Add story" });
    addBtn.addEventListener("click", function () {
      var card = addStoryCard();
      card.fields[0].control.focus();
    });

    var head = el("div", { class: "stories-head" }, [
      el("h3", { text: "Child stories" }),
      addBtn
    ]);

    storiesSection.appendChild(head);
    storiesSection.appendChild(storiesWrap);
    addStoryCard();
  }
}

function fieldByName(name) {
  for (var i = 0; i < currentFields.length; i++) {
    if (currentFields[i].name === name) {
      return currentFields[i];
    }
  }
  return null;
}

function setFieldValue(name, value) {
  var field = fieldByName(name);
  if (field && value != null) {
    field.control.value = value;
  }
}

function collectPayload(typeSpec) {
  var payload = { type: typeSpec.slug };

  currentFields.forEach(function (field) {
    payload[field.name] = field.value();
  });

  if (typeSpec.stories) {
    payload.stories = storyCards
      .map(function (card) {
        var story = {};
        card.fields.forEach(function (field) {
          story[field.name] = field.value();
        });
        return story;
      })
      .filter(function (story) {
        return (story.title || "").trim() !== "";
      });
  }

  return payload;
}


// --- submit + result -------------------------------------------------------

function setSubmitting(on) {
  var btn = document.getElementById("create-submit");
  if (!btn) {
    return;
  }
  btn.disabled = on;
  btn.textContent = on ? "Creating…" : "Create";
}

function clearCreateResult() {
  var box = document.getElementById("create-result");
  box.textContent = "";
  box.classList.remove("ok", "err");
}

function renderCreateResult(node, ok) {
  var box = document.getElementById("create-result");
  box.textContent = "";
  box.classList.toggle("ok", !!ok);
  box.classList.toggle("err", !ok);
  box.appendChild(node);
}

function showCreateMessage(ok, message) {
  var line = el("p", { class: ok ? "ok-line" : "err-line", text: message });
  renderCreateResult(line, ok);
  announce(message);
}

// An escaped link to a created work item: id/url are from the server, so the
// text goes through externalLink (textContent) and the href is scheme-gated.
// A create with no configured URL renders the id as inert text.
function createdLink(label, id, url) {
  var text = label + " #" + id;
  if (url) {
    return externalLink(text, url);
  }
  return el("span", { text: text });
}

function buildCreateAnotherButton(typeSpec) {
  var btn = el("button", { type: "button", class: "btn primary", text: "Create another" });

  btn.addEventListener("click", function () {
    var keepArea = valueOfField("area");
    var keepIteration = valueOfField("iteration");

    renderCreateForm(typeSpec);
    setFieldValue("area", keepArea);
    setFieldValue("iteration", keepIteration);

    clearCreateResult();

    var titleField = fieldByName("title");
    if (titleField) {
      titleField.control.focus();
    }
    announce("Form cleared — create another.");
  });

  return btn;
}

function valueOfField(name) {
  var field = fieldByName(name);
  return field ? field.value() : "";
}

function handleSingleSuccess(typeSpec, data) {
  var container = el("div", { class: "create-ok" }, [
    el("p", { class: "ok-line" }, [ "Created ", createdLink(typeSpec.label, data.id, data.url), "." ])
  ]);
  container.appendChild(buildCreateAnotherButton(typeSpec));

  renderCreateResult(container, true);
  announce(typeSpec.label + " created.");
}

function handleFeatureStoriesSuccess(typeSpec, data) {
  var feature = data.feature || {};
  var stories = asArray(data.stories);

  var children = [
    el("p", { class: "ok-line" }, [ "Created ", createdLink("Feature", feature.id, feature.url), "." ])
  ];

  if (stories.length) {
    var list = el("ul", { class: "story-results" }, stories.map(function (story) {
      if (story.ok) {
        var suffix = story.title ? (" — " + story.title) : "";
        return el("li", { class: "ok" }, [ createdLink("Story", story.id, story.url), suffix ]);
      }
      return el("li", { class: "err", text: (story.title || "Story") + " — " + (story.error || "failed to create") });
    }));
    children.push(list);
  }

  var container = el("div", { class: "create-ok" }, children);
  container.appendChild(buildCreateAnotherButton(typeSpec));

  renderCreateResult(container, true);

  var failed = stories.filter(function (s) { return !s.ok; }).length;
  announce(failed
    ? ("Feature created; " + failed + " child story(ies) failed.")
    : ("Feature and " + stories.length + " story(ies) created."));
}

// A 400 with a `field` highlights that field; anything else is a message in the
// result region. Server messages are set via textContent, so they render inert.
function handleCreateError(res) {
  var data = res.data || {};
  var message = data.error || ("Create failed (HTTP " + res.status + ").");

  if (data.field) {
    var field = fieldByName(data.field);
    if (field) {
      field.setError(message);
      field.control.focus();
      announce(message);
      return;
    }
  }

  showCreateMessage(false, message);
}

function onCreateSubmit(e) {
  e.preventDefault();

  var typeSpec = CREATE_TYPE_BY_SLUG[typeSelect.value] || CREATE_TYPES[0];

  var firstBad = validateAll(typeSpec);
  if (firstBad) {
    firstBad.control.focus();
    announce("Please fix the highlighted field.");
    return;
  }

  if (!creatorBackendOk) {
    showCreateMessage(false, "Creating needs the local daily-viewer server, which isn't reachable. Start it with az-Start-AzDevOpsDailyViewer.");
    return;
  }

  var payload = collectPayload(typeSpec);
  setSubmitting(true);
  clearCreateResult();

  postCreate("workitem", payload)
    .then(function (res) {
      setSubmitting(false);

      if (res.ok && res.data && res.data.ok) {
        if (typeSpec.stories) {
          handleFeatureStoriesSuccess(typeSpec, res.data);
        } else {
          handleSingleSuccess(typeSpec, res.data);
        }
      } else {
        handleCreateError(res);
      }
    })
    .catch(function () {
      setSubmitting(false);
      showCreateMessage(false, "Couldn't reach the create endpoint.");
    });
}


// --- setup + options load --------------------------------------------------

function normalizeCreateOptions(data) {
  var parents = data.parents || {};
  var defaults = data.defaults || {};

  return {
    areas: asArray(data.areas),
    iterations: asArray(data.iterations),
    parents: {
      epic: asArray(parents.epic),
      feature: asArray(parents.feature),
      story: asArray(parents.story)
    },
    defaults: {
      area: defaults.area || "",
      iteration: defaults.iteration || ""
    }
  };
}

function markCreatorOffline() {
  creatorBackendOk = false;

  var submit = document.getElementById("create-submit");
  if (submit) {
    submit.disabled = true;
  }

  showCreateMessage(false, "The daily-viewer server isn't reachable, so the pickers are empty and creating is disabled. Start it with az-Start-AzDevOpsDailyViewer and open this page from 127.0.0.1.");
}

function loadCreatorOptions() {
  postCreate("options", {})
    .then(function (res) {
      if (res.ok && res.data) {
        creatorOptions = normalizeCreateOptions(res.data);
        creatorBackendOk = true;

        var spec = CREATE_TYPE_BY_SLUG[typeSelect.value] || CREATE_TYPES[0];
        renderCreateForm(spec);
      } else {
        markCreatorOffline();
      }
    })
    .catch(function () {
      markCreatorOffline();
    });
}

function buildCreatorShell() {
  var body = document.getElementById("creator-body");
  body.textContent = "";

  typeSelect = el("select", { id: "create-type", class: "control" },
    CREATE_TYPES.map(function (t) { return optionEl(t.slug, t.label, t.slug === "story"); }));

  typeSelect.addEventListener("change", function () {
    var spec = CREATE_TYPE_BY_SLUG[typeSelect.value] || CREATE_TYPES[0];
    renderCreateForm(spec);
    clearCreateResult();
  });

  var typeField = el("div", { class: "field" }, [
    el("label", { for: "create-type", text: "What do you want to create?" }),
    typeSelect
  ]);

  var fieldsWrap = el("div", { id: "create-fields" });
  var storiesSection = el("div", { id: "create-stories" });

  var submit = el("button", { id: "create-submit", type: "submit", class: "btn primary", text: "Create" });
  var actions = el("div", { class: "create-actions" }, [ submit ]);

  var form = el("form", { id: "create-form", novalidate: "" }, [ fieldsWrap, storiesSection, actions ]);
  form.addEventListener("submit", onCreateSubmit);

  var result = el("div", { id: "create-result", class: "create-result" });

  body.appendChild(el("div", { class: "create" }, [ typeField, form, result ]));

  renderCreateForm(CREATE_TYPE_BY_SLUG["story"]);
}

function setupCreatorOnce() {
  if (creatorReady) {
    return;
  }
  creatorReady = true;

  buildCreatorShell();
  loadCreatorOptions();
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
