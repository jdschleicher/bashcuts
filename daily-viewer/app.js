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


function groupBlock(group, rowFn) {
  var summary = el("summary", null, [
    chevron(),
    el("span", { class: "glabel", text: group.label }),
    el("span", { class: "count", text: String(group.items.length) })
  ]);

  var list = el("ul", { class: "glist" }, group.items.map(rowFn));

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
  var list = el("ul", { class: "events" }, model.events.map(eventRow));
  return [ list ];
}


function renderWeek(model) {
  return [
    groupBlock(model.stories, workItemRow),
    groupBlock(model.prep, checklistRow)
  ];
}


function renderActivity(model) {
  return model.groups.map(function (group) {
    return groupBlock(group, workItemRow);
  });
}


function renderFocus(model) {
  var primary = el("div", { class: "primary" }, [
    el("span", { class: "star", "aria-hidden": "true" }, [ STAR_GLYPH ]),
    el("div", null, [
      el("p", { class: "ptitle" }, [ externalLink(model.primary.title, model.primary.url) ]),
      el("p", { class: "psub", text: model.primary.sub })
    ])
  ]);

  return [ primary, groupBlock(model.support, workItemRow) ];
}


// ---------------------------------------------------------------------------
// Mount — populate each tile body, derive its count badge from the rendered
// rows, and set each stat number from the collection it summarizes.
// ---------------------------------------------------------------------------

function tile(key) {
  return document.querySelector('.tile[data-tile="' + key + '"]');
}

function mountTile(key, nodes) {
  var body = tile(key).querySelector(".body");
  nodes.forEach(function (node) { body.appendChild(node); });

  var badge = tile(key).querySelector(".tt .count");
  badge.textContent = String(body.querySelectorAll(".wi, .event").length);
}

function setStat(key, count) {
  var number = document.querySelector('.stat[data-target="' + key + '"] .n');
  number.textContent = String(count);
}

function activityTotal(model) {
  return model.groups.reduce(function (sum, group) {
    return sum + group.items.length;
  }, 0);
}

function renderAll() {
  mountTile("agenda", renderAgenda(MODEL.agenda));
  mountTile("week", renderWeek(MODEL.week));
  mountTile("activity", renderActivity(MODEL.activity));
  mountTile("focus", renderFocus(MODEL.focus));

  setStat("tile-agenda", MODEL.agenda.events.length);
  setStat("tile-week", MODEL.week.stories.items.length);
  setStat("tile-activity", activityTotal(MODEL.activity));
  setStat("tile-focus", MODEL.focus.support.items.length);
}

renderAll();


// ---------------------------------------------------------------------------
// Controls — wired after render so every handler sees the rendered rows.
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


// Per-tile refresh: the only expensive path. Cheap render is already on screen
// from cache; this is where the real build would fire that tile's az CLI calls.
var REFRESH_MS = 900;

function tileNameFromButton(btn) {
  var label = btn.getAttribute("aria-label") || "This tile";
  var name = label.replace(/^Refresh\s+/, "");
  return name;
}

function refreshTile(btn) {
  if (btn.disabled) return;

  var stale = btn.parentElement.querySelector(".stale");
  var label = stale.childNodes[stale.childNodes.length - 1];
  var name = tileNameFromButton(btn);

  btn.disabled = true;
  btn.classList.add("spinning");
  stale.classList.remove("warn");
  stale.classList.add("busy");
  label.textContent = "refreshing…";
  announce("Refreshing " + name + "…");

  window.setTimeout(function () {
    btn.classList.remove("spinning");
    btn.disabled = false;
    stale.classList.remove("busy");
    label.textContent = "cached just now";
    announce(name + " updated — cached just now.");
  }, REFRESH_MS);
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
    if (!target) return;

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
  if (t) return t;
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
// open/closed state so clearing the box restores the original layout.
var allDetails = document.querySelectorAll("details");
allDetails.forEach(function (d) { d.dataset.open0 = d.open ? "1" : "0"; });

document.querySelectorAll(".tile .body").forEach(function (body) {
  var note = document.createElement("p");
  note.className = "nomatch";
  note.textContent = "No matching items in this tile.";
  body.appendChild(note);
});

function applyFilter(raw) {
  var q = raw.trim().toLowerCase();

  if (q) {
    allDetails.forEach(function (d) { d.open = true; });
  } else {
    allDetails.forEach(function (d) { d.open = d.dataset.open0 === "1"; });
  }

  var matchTotal = 0;

  document.querySelectorAll(".tile").forEach(function (t) {
    var rows = t.querySelectorAll(".wi, .event");
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
