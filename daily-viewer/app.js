"use strict";

/* ---------------------------------------------------------------------------
   Daily Viewer — data-driven view layer + control behavior.

   The view is a function of `model`: placeholder data shaped like the eventual
   cache payload (az boards query + the Outlook module). Every tile body, group,
   and row is built by a render function from that model — index.html carries no
   hardcoded rows — and count badges / stat numbers are DERIVED from collection
   lengths so they can't drift.

   Escaping: all model text reaches the DOM through textContent / createElement /
   setAttribute (never innerHTML), so untrusted Azure DevOps titles, discussion
   text, and display names render as inert text.
--------------------------------------------------------------------------- */

var WORKITEM_URL = "https://dev.azure.com/org/project/_workitems/edit/";

var model = {
  tiles: {
    agenda: {
      events: [
        {
          time: "9:00 AM", tz: "EST", datetime: "2026-07-14T09:00:00-05:00",
          title: "Sprint Planning Sync",
          location: { badge: "Teams", link: { href: "https://teams.microsoft.com/l/meetup-join/example", text: "Join meeting →" } },
          detail: { label: "With", text: "Platform Team · 6 attendees" }
        },
        {
          time: "11:00 AM", tz: "EST", datetime: "2026-07-14T11:00:00-05:00",
          title: "Architecture Design Review",
          location: { badge: "In person", text: "Room 132" },
          detail: { label: "Prep", link: { href: "https://dev.azure.com/org/project/_wiki/wikis/project.wiki/42/Design-Review", text: "Design doc →" } }
        }
      ]
    },

    week: {
      groups: [
        {
          label: "Stories to complete", open: true,
          items: [
            { type: "Story", typeClass: "t-story", id: "#1234", url: WORKITEM_URL + "1234", title: "Wire agenda tile to az boards query", titleUrl: WORKITEM_URL + "1234", state: { label: "In progress", cls: "s-progress" } },
            { type: "Story", typeClass: "t-story", id: "#1240", url: WORKITEM_URL + "1240", title: "Outlook calendar pull for daily events", titleUrl: WORKITEM_URL + "1240", state: { label: "Active", cls: "s-active" } },
            { type: "Bug", typeClass: "t-bug", id: "#1251", url: WORKITEM_URL + "1251", title: "Timezone offset on EST agenda rows", titleUrl: WORKITEM_URL + "1251", state: { label: "In review", cls: "s-review" } }
          ]
        },
        {
          label: "Events to prepare for", open: true,
          items: [
            { check: true, text: "Confirm demo build is deployed before Thu review" },
            { check: true, text: "Send agenda for ", link: { href: "https://teams.microsoft.com/l/meetup-join/example2", text: "Fri sprint retro" } }
          ]
        }
      ]
    },

    activity: {
      groups: [
        {
          label: "Tagged discussions", open: false,
          items: [
            { type: "Feature", typeClass: "t-feature", id: "#1180", url: WORKITEM_URL + "1180", title: "@you — “can you confirm the WIQL scope?”", titleUrl: WORKITEM_URL + "1180?discussion" },
            { type: "Story", typeClass: "t-story", id: "#1240", url: WORKITEM_URL + "1240", title: "@you — “ready for review whenever”", titleUrl: WORKITEM_URL + "1240?discussion" }
          ]
        },
        {
          label: "Active story updates", open: false,
          items: [
            { type: "Story", typeClass: "t-story", id: "#1234", url: WORKITEM_URL + "1234", title: "State → In progress by A. Rivera", note: "2h ago" },
            { type: "Bug", typeClass: "t-bug", id: "#1251", url: WORKITEM_URL + "1251", title: "Moved to In review", note: "4h ago" }
          ]
        },
        {
          label: "Sprint close items", open: false,
          items: [
            { type: "Task", typeClass: "t-task", id: "#1209", url: WORKITEM_URL + "1209", title: "Update release notes", titleUrl: WORKITEM_URL + "1209", state: { label: "Closing", cls: "s-closing" } },
            { type: "Story", typeClass: "t-story", id: "#1222", url: WORKITEM_URL + "1222", title: "Verify acceptance criteria signed off", titleUrl: WORKITEM_URL + "1222", state: { label: "Closing", cls: "s-closing" } }
          ]
        }
      ]
    },

    focus: {
      primary: {
        url: WORKITEM_URL + "1234",
        title: "User Story #1234 — Wire agenda tile to az boards",
        sub: "Primary commitment for today · In progress"
      },
      groups: [
        {
          label: "SF devs — unplanned support", open: true,
          items: [
            { type: "Bug", typeClass: "t-bug", id: "#1260", url: WORKITEM_URL + "1260", title: "Deploy failing on scratch org spin-up", titleUrl: WORKITEM_URL + "1260", state: { label: "Active", cls: "s-active" } },
            { type: "Task", typeClass: "t-task", id: "#1263", url: WORKITEM_URL + "1263", title: "Help triage permission set assignment", titleUrl: WORKITEM_URL + "1263", state: { label: "New", cls: "s-new" } }
          ]
        }
      ]
    }
  }
};


/* ---------- derivations (single source of truth for every count) ---------- */

function sumGroupItems(groups) {
  return groups.reduce(function (total, group) { return total + group.items.length; }, 0);
}

function groupByLabel(groups, label) {
  var match = groups.filter(function (group) { return group.label === label; })[0];
  return match ? match.items.length : 0;
}

var statDefs = [
  { cls: "a", target: "tile-agenda",   label: "Meetings today",        value: function () { return model.tiles.agenda.events.length; } },
  { cls: "f", target: "tile-week",     label: "Stories due this week", value: function () { return groupByLabel(model.tiles.week.groups, "Stories to complete"); } },
  { cls: "s", target: "tile-activity", label: "Recent updates",        value: function () { return sumGroupItems(model.tiles.activity.groups); } },
  { cls: "g", target: "tile-focus",    label: "Support & focus items", value: function () { return sumGroupItems(model.tiles.focus.groups); } }
];


/* ---------- DOM builders (escaping-safe: no innerHTML anywhere) ---------- */

// escapeText — the one place model strings become DOM. createTextNode can never
// be parsed as markup, so this is the escaping boundary the whole render layer
// funnels through.
function escapeText(str) {
  return document.createTextNode(str == null ? "" : String(str));
}

function h(tag, opts, kids) {
  var node = document.createElement(tag);
  opts = opts || {};

  if (opts.class) {
    node.className = opts.class;
  }
  if (opts.attrs) {
    Object.keys(opts.attrs).forEach(function (key) {
      node.setAttribute(key, opts.attrs[key]);
    });
  }
  if (opts.text != null) {
    node.appendChild(escapeText(opts.text));
  }
  if (kids) {
    kids.forEach(function (kid) {
      if (kid == null) {
        return;
      }
      node.appendChild(typeof kid === "string" ? escapeText(kid) : kid);
    });
  }

  return node;
}

function link(url, label, cls) {
  var opts = { text: label, attrs: { href: url, target: "_blank", rel: "noopener" } };
  if (cls) {
    opts.class = cls;
  }
  return h("a", opts);
}

function chev() {
  return document.getElementById("tpl-chev").content.firstElementChild.cloneNode(true);
}


/* ---------- render layer ---------- */

function renderEvent(ev) {
  var time = h("time", { class: "time", attrs: { datetime: ev.datetime } }, [
    ev.time,
    h("span", { class: "tz", text: ev.tz })
  ]);

  var locDetail = ev.location.link ? link(ev.location.link.href, ev.location.link.text) : ev.location.text;
  var where = h("span", { class: "where" }, [
    h("span", { class: "badge-loc", text: ev.location.badge }),
    " ",
    locDetail
  ]);

  var detailValue = ev.detail.link ? link(ev.detail.link.href, ev.detail.link.text) : ev.detail.text;
  var detailLine = h("p", { class: "meta" }, [
    h("span", { class: "k", text: ev.detail.label }),
    " ",
    detailValue
  ]);

  var col = h("div", null, [
    h("p", { class: "etitle", text: ev.title }),
    h("p", { class: "meta" }, [where]),
    detailLine
  ]);

  return h("li", { class: "event" }, [time, col]);
}

function renderWorkItem(wi) {
  var titleSlot = wi.titleUrl
    ? h("span", { class: "wtitle" }, [link(wi.titleUrl, wi.title)])
    : h("span", { class: "wtitle", text: wi.title });

  var state = wi.state ? h("span", { class: "state " + wi.state.cls, text: wi.state.label }) : null;
  var note = wi.note ? h("span", { class: "note", text: wi.note }) : null;

  return h("li", { class: "wi" }, [
    h("span", { class: "type " + wi.typeClass, text: wi.type }),
    link(wi.url, wi.id, "id"),
    titleSlot,
    state,
    note
  ]);
}

function renderCheck(item) {
  var titleKids = [item.text];
  if (item.link) {
    titleKids.push(link(item.link.href, item.link.text));
  }

  return h("li", { class: "wi" }, [
    h("span", { class: "check", attrs: { "aria-hidden": "true" } }),
    h("span", { class: "wtitle" }, titleKids)
  ]);
}

function renderRow(item) {
  return item.check ? renderCheck(item) : renderWorkItem(item);
}

function renderGroup(group) {
  var attrs = group.open ? { open: "" } : null;

  var summary = h("summary", null, [
    chev(),
    h("span", { class: "glabel", text: group.label }),
    h("span", { class: "count", text: group.items.length })
  ]);

  var list = h("ul", { class: "glist" }, group.items.map(renderRow));

  return h("details", { class: "group", attrs: attrs }, [summary, list]);
}

function renderPrimary(primary) {
  var col = h("div", null, [
    h("p", { class: "ptitle" }, [link(primary.url, primary.title)]),
    h("p", { class: "psub", text: primary.sub })
  ]);

  return h("div", { class: "primary" }, [
    h("span", { class: "star", attrs: { "aria-hidden": "true" }, text: "★" }),
    col
  ]);
}

// tile count badge — derived from the tile's own top-level blocks, never a literal.
function tileCount(key, data) {
  if (key === "agenda") {
    return data.events.length;
  }
  if (key === "focus") {
    return (data.primary ? 1 : 0) + data.groups.length;
  }
  return data.groups.length;
}

function fillBody(body, key, data) {
  if (key === "agenda") {
    body.appendChild(h("ul", { class: "events" }, data.events.map(renderEvent)));
    return;
  }

  if (data.primary) {
    body.appendChild(renderPrimary(data.primary));
  }
  data.groups.forEach(function (group) {
    body.appendChild(renderGroup(group));
  });
}

function renderTile(key) {
  var data = model.tiles[key];
  var tile = document.getElementById("tile-" + key);
  if (!tile) {
    return;
  }

  var body = tile.querySelector(".body");
  var count = tile.querySelector(".tt .count");
  count.textContent = tileCount(key, data);

  fillBody(body, key, data);
}

function renderStats() {
  var strip = document.getElementById("stats");

  statDefs.forEach(function (def) {
    var stat = h("button", { class: "stat " + def.cls, attrs: { type: "button", "data-target": def.target } }, [
      h("span", { class: "n", text: def.value() }),
      h("span", { class: "l", text: def.label })
    ]);

    strip.appendChild(stat);
  });
}

function render() {
  renderStats();
  Object.keys(model.tiles).forEach(renderTile);
}

render();


/* ---------- controls (operate on the rendered DOM) ---------- */

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
    var tile = document.getElementById(stat.dataset.target);
    if (!tile) return;

    var details = tile.querySelector("details");
    if (details) {
      details.open = true;
    }

    tile.scrollIntoView({ behavior: "smooth", block: "start" });
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

  document.querySelectorAll(".tile").forEach(function (tile) {
    var rows = tile.querySelectorAll(".wi, .event");
    var anyVisible = false;

    rows.forEach(function (row) {
      var match = !q || row.textContent.toLowerCase().indexOf(q) !== -1;
      row.classList.toggle("hide", !match);
      if (match) {
        anyVisible = true;
        matchTotal++;
      }
    });

    tile.querySelectorAll(".group").forEach(function (group) {
      var visible = group.querySelectorAll(".wi:not(.hide), .event:not(.hide)").length;
      group.classList.toggle("hide", !!q && visible === 0);
    });

    tile.classList.toggle("empty", !!q && !anyVisible);
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
