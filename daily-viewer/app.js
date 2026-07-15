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

  week: {
    stories: {
      label: "Stories to complete",
      open: true,
      items: [
        { type: "Story", id: 1234, url: "https://dev.azure.com/org/project/_workitems/edit/1234", title: "Wire agenda tile to az boards query", titleUrl: "https://dev.azure.com/org/project/_workitems/edit/1234", state: "In progress" },
        { type: "Story", id: 1240, url: "https://dev.azure.com/org/project/_workitems/edit/1240", title: "Outlook calendar pull for daily events", titleUrl: "https://dev.azure.com/org/project/_workitems/edit/1240", state: "Active" },
        { type: "Bug", id: 1251, url: "https://dev.azure.com/org/project/_workitems/edit/1251", title: "Timezone offset on EST agenda rows", titleUrl: "https://dev.azure.com/org/project/_workitems/edit/1251", state: "In review" }
      ]
    },
    prep: {
      label: "Events to prepare for",
      open: true,
      items: [
        { title: "Confirm demo build is deployed before Thu review" },
        { title: "Send agenda for", link: { text: "Fri sprint retro", url: "https://teams.microsoft.com/l/meetup-join/example2" } }
      ]
    }
  },

  activity: {
    groups: [
      {
        label: "Tagged discussions",
        open: false,
        items: [
          { type: "Feature", id: 1180, url: "https://dev.azure.com/org/project/_workitems/edit/1180", title: "@you — “can you confirm the WIQL scope?”", titleUrl: "https://dev.azure.com/org/project/_workitems/edit/1180?discussion" },
          { type: "Story", id: 1240, url: "https://dev.azure.com/org/project/_workitems/edit/1240", title: "@you — “ready for review whenever”", titleUrl: "https://dev.azure.com/org/project/_workitems/edit/1240?discussion" }
        ]
      },
      {
        label: "Active story updates",
        open: false,
        items: [
          { type: "Story", id: 1234, url: "https://dev.azure.com/org/project/_workitems/edit/1234", title: "State → In progress by A. Rivera", note: "2h ago" },
          { type: "Bug", id: 1251, url: "https://dev.azure.com/org/project/_workitems/edit/1251", title: "Moved to In review", note: "4h ago" }
        ]
      },
      {
        label: "Sprint close items",
        open: false,
        items: [
          { type: "Task", id: 1209, url: "https://dev.azure.com/org/project/_workitems/edit/1209", title: "Update release notes", titleUrl: "https://dev.azure.com/org/project/_workitems/edit/1209", state: "Closing" },
          { type: "Story", id: 1222, url: "https://dev.azure.com/org/project/_workitems/edit/1222", title: "Verify acceptance criteria signed off", titleUrl: "https://dev.azure.com/org/project/_workitems/edit/1222", state: "Closing" }
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
        { type: "Bug", id: 1260, url: "https://dev.azure.com/org/project/_workitems/edit/1260", title: "Deploy failing on scratch org spin-up", titleUrl: "https://dev.azure.com/org/project/_workitems/edit/1260", state: "Active" },
        { type: "Task", id: 1263, url: "https://dev.azure.com/org/project/_workitems/edit/1263", title: "Help triage permission set assignment", titleUrl: "https://dev.azure.com/org/project/_workitems/edit/1263", state: "New" }
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

function workItemRow(wi) {
  var children = [];

  children.push(el("span", { class: "type " + (TYPE_CLASS[wi.type] || ""), text: wi.type }));
  children.push(externalLink("#" + wi.id, wi.url, "id"));

  if (wi.titleUrl) {
    children.push(el("span", { class: "wtitle" }, [ externalLink(wi.title, wi.titleUrl) ]));
  } else {
    children.push(el("span", { class: "wtitle", text: wi.title }));
  }

  if (wi.state) {
    children.push(el("span", { class: "state " + (STATE_CLASS[wi.state] || ""), text: wi.state }));
  }

  if (wi.note) {
    children.push(el("span", { class: "note", text: wi.note }));
  }

  return el("li", { class: "wi" }, children);
}


function checklistRow(item) {
  var title = [ item.title ];

  if (item.link) {
    title.push(" ");
    title.push(externalLink(item.link.text, item.link.url));
  }

  return el("li", { class: "wi" }, [
    el("span", { class: "check", "aria-hidden": "true" }),
    el("span", { class: "wtitle" }, title)
  ]);
}


function eventRow(ev) {
  var timeChildren = [ ev.time.label ];
  if (ev.time.tz) {
    timeChildren.push(el("span", { class: "tz", text: ev.time.tz }));
  }
  var time = el("time", { class: "time", datetime: ev.time.datetime }, timeChildren);

  var whereChildren = [ el("span", { class: "badge-loc", text: ev.location.badge }) ];
  if (ev.location.text) {
    whereChildren.push(" ");
    whereChildren.push(ev.location.text);
  }
  if (ev.location.url) {
    whereChildren.push(" ");
    whereChildren.push(externalLink(ev.location.urlLabel, ev.location.url));
  }

  var metaLines = [ el("p", { class: "meta" }, [ el("span", { class: "where" }, whereChildren) ]) ];

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

  return el("li", { class: "event" }, [ time, content ]);
}


// A tile's collections arrive from the cache/API as JSON. Guard every list
// through this so a serialized-empty array (or an absent field) becomes [] and
// never a `.map` on a non-array.
function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function groupBlock(group, rowFn) {
  var items = asArray(group.items);

  var summary = el("summary", null, [
    chevron(),
    el("span", { class: "glabel", text: group.label }),
    el("span", { class: "count", text: String(items.length) })
  ]);

  var list = el("ul", { class: "glist" }, items.map(rowFn));

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
  return [
    groupBlock(model.stories || {}, workItemRow),
    groupBlock(model.prep || {}, checklistRow)
  ];
}


function renderActivity(model) {
  return asArray(model.groups).map(function (group) {
    return groupBlock(group, workItemRow);
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
// Tile registry — the render function, stat target, and stat count for each
// tile in one place, so mount and refresh iterate a single list.
// ---------------------------------------------------------------------------

// What counts as a "row" across mount, count badges, and the live filter.
var ROW_SELECTOR = ".wi, .event";

function activityTotal(model) {
  return asArray(model.groups).reduce(function (sum, group) {
    return sum + asArray(group.items).length;
  }, 0);
}

var TILES = [
  { key: "agenda",   render: renderAgenda,   stat: "tile-agenda",
    empty: "No meetings today.",
    statCount: function (m) { return asArray(m.events).length; } },
  { key: "week",     render: renderWeek,     stat: "tile-week",
    empty: "No stories or prep items this week.",
    statCount: function (m) { return asArray(m.stories && m.stories.items).length; } },
  { key: "activity", render: renderActivity, stat: "tile-activity",
    empty: "No recent activity.",
    statCount: activityTotal },
  { key: "focus",    render: renderFocus,    stat: "tile-focus",
    empty: "Nothing pinned. Set $global:AzDevOpsDailyFocus to a work-item id.",
    statCount: function (m) { return asArray(m.support && m.support.items).length; } }
];

var TILE_BY_KEY = {};
TILES.forEach(function (t) { TILE_BY_KEY[t.key] = t; });


// ---------------------------------------------------------------------------
// Mount — render one tile body from its data model: clear, render rows, derive
// the count badge, and drop a friendly note when the tile is genuinely empty.
// ---------------------------------------------------------------------------

function tile(key) {
  return document.querySelector('.tile[data-tile="' + key + '"]');
}

function setStat(statId, count) {
  var number = document.querySelector('.stat[data-target="' + statId + '"] .n');
  if (number) {
    number.textContent = String(count);
  }
}

function renderTileBody(key, model) {
  var conf = TILE_BY_KEY[key];
  var body = tile(key).querySelector(".body");

  body.textContent = "";
  conf.render(model || {}).forEach(function (node) { body.appendChild(node); });

  // "empty" counts the primary too so a focus tile with a pinned item but no
  // support rows isn't mislabeled as empty; the count badge stays row-only.
  var meaningful = body.querySelectorAll(ROW_SELECTOR + ", .primary").length;
  if (meaningful === 0) {
    body.appendChild(el("p", { class: "empty-note", text: conf.empty }));
  }

  // Re-add the filter's no-match note after each (re)render so the live filter
  // has its placeholder whether the body came from cache or a refresh.
  body.appendChild(el("p", { class: "nomatch", text: "No matching items in this tile." }));

  tile(key).querySelector(".tt .count").textContent =
    String(body.querySelectorAll(ROW_SELECTOR).length);
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

function setStale(key, data) {
  var stale = tile(key).querySelector(".stale");
  var label = staleLabelNode(key);

  stale.classList.remove("busy");

  if (data && typeof data.ageSeconds === "number") {
    label.textContent = "cached " + formatAge(data.ageSeconds);
    stale.classList.toggle("warn", !!data.stale);
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

function fetchJson(url, options) {
  return fetch(url, options).then(function (res) {
    if (!res.ok) {
      throw new Error("HTTP " + res.status);
    }
    return res.json();
  });
}

function paintTile(key, model, data) {
  var conf = TILE_BY_KEY[key];
  renderTileBody(key, model);
  setStat(conf.stat, conf.statCount(model || {}));
  setStale(key, data);
}

function loadTile(key) {
  return fetchJson(API + key, { headers: { "Accept": "application/json" } })
    .then(function (data) {
      paintTile(key, data.items || {}, data);
    })
    .catch(function () {
      paintTile(key, MODEL[key], null);
    });
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


// Per-tile refresh: the only expensive path. The cheap render is already on
// screen from cache; this re-runs that tile's az / Outlook query server-side
// via POST and swaps in the fresh data, count, and "cached just now" stamp.
function tileNameFromButton(btn) {
  var label = btn.getAttribute("aria-label") || "This tile";
  var name = label.replace(/^Refresh\s+/, "");
  return name;
}

function refreshTile(btn) {
  if (btn.disabled) {
    return Promise.resolve();
  }

  var key = btn.getAttribute("data-tile");
  var stale = tile(key).querySelector(".stale");
  var label = staleLabelNode(key);
  var name = tileNameFromButton(btn);

  btn.disabled = true;
  btn.classList.add("spinning");
  stale.classList.remove("warn");
  stale.classList.add("busy");
  label.textContent = "refreshing…";
  announce("Refreshing " + name + "…");

  return fetchJson(API + key + "/refresh", { method: "POST", headers: { "Accept": "application/json" } })
    .then(function (data) {
      paintTile(key, data.items || {}, data);
      rememberOpenState();
      applyFilter(searchBox.value);
      announce(name + " updated — cached just now.");
    })
    .catch(function () {
      stale.classList.remove("busy");
      stale.classList.add("warn");
      label.textContent = "refresh failed";
      announce(name + " refresh failed.");
    })
    .then(function () {
      btn.classList.remove("spinning");
      btn.disabled = false;
    });
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


// Stat strip: open and scroll to the tile a stat summarizes.
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


// ---------------------------------------------------------------------------
// Boot — load every tile from cache (falling back to the sample model), then
// record open state so the filter can restore it.
// ---------------------------------------------------------------------------

Promise.all(TILES.map(function (t) { return loadTile(t.key); })).then(function () {
  rememberOpenState();
});
