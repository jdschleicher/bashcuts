"use strict";

// Behavior for the daily viewer. Content is still hardcoded in index.html
// (data-driven rendering lands separately); this wires the controls only.

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
  iconMoon.style.display = dark ? "block" : "none";
  iconSun.style.display = dark ? "none" : "block";
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
