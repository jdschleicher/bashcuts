"use strict";

// Behavior + view layer for the Azure Resource Viewer. Each tile is a function
// of its /api/tiles/<name> payload: one render pass builds every row, and the
// count badge + summary stat are derived from the records array (they can't
// drift). Every cached string — display names, group / app names, scopes, mail —
// reaches the DOM through `el()` (textContent / setAttribute), so untrusted
// directory text is escaped by construction; there is no innerHTML path.


// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

var API = "/api/tiles/";
var CONTEXT_API = "/api/context";
var REFRESH_SUFFIX = "/refresh";
var HTTP_NOT_FOUND = 404;

// The refresh POST must carry a JSON content type: the server rejects anything
// else, which is what keeps a cross-site simple-request from triggering it.
var JSON_TYPE = "application/json";
var ACCEPT_JSON = { "Accept": JSON_TYPE };
var JSON_HEADERS = { "Accept": JSON_TYPE, "Content-Type": JSON_TYPE };
var EMPTY_JSON_BODY = "{}";

// Portal links are built server-side from fixed constants, but the cache is a
// plain file any local process could rewrite — so only https links to the
// Azure portal ever become clickable.
var PORTAL_ORIGIN = "https://portal.azure.com";

var STATE_NOT_PERMITTED = "notPermitted";
var SELF_PRINCIPAL = "me";
var RELATIONSHIP_OWNER = "owner";
var TILE_DETAILS = ".tile > details";
var SCOPE_ROOT = "/";
var META_SEP = " · ";
var ROLE_SCOPE_SEP = " @ ";
var MISSING_STAT = "–";

// Relative-age buckets — kept identical to Get-LocalViewerRelativeTime
// (localhost_viewer.ps1) and daily-viewer/app.js so every surface prints the
// same "cached Nm ago" for the same age.
var JUST_NOW_SECONDS = 45;
var SECONDS_PER_MINUTE = 60;
var MINUTES_PER_HOUR = 60;
var HOURS_PER_DAY = 24;

// Credential expiry — keep EXPIRY_WINDOW_DAYS in step with
// $script:AzResourcesExpiryWindowDays (azresources_views.ps1) so the dashboard
// and az-Show-AzExpiringCredentials flag the same credentials. A credential
// with no end date never expires, so it is always "ok".
var EXPIRY_WINDOW_DAYS = 30;
var MS_PER_SECOND = 1000;
var MS_PER_DAY = MS_PER_SECOND * SECONDS_PER_MINUTE * MINUTES_PER_HOUR * HOURS_PER_DAY;
var CRED_EXPIRED = "expired";
var CRED_EXPIRING = "expiring";
var CRED_OK = "ok";
var EXPIRY_STAT = '.stat[data-stat="expiring"]';
var EXPIRY_STAT_LABEL_PREFIX = "Credentials expired or expiring in ";
var EXPIRY_STAT_LABEL_SUFFIX = " days";
var LABEL_EXPIRED = "Expired";
var LABEL_EXPIRED_COUNT_SUFFIX = " expired";
var LABEL_EXPIRES_TODAY = "Expires today";
var LABEL_EXPIRES_IN_PREFIX = "Expires in ";
var LABEL_EXPIRING_COUNT_SUFFIX = " expiring";
var LABEL_SOONEST_IN_PREFIX = "soonest in ";
var LABEL_SOONEST_TODAY = "soonest today";
var CRED_KIND_CERTIFICATE = "certificate";

var SCOPE_TYPE_LABELS = {
  managementGroup: "Mgmt group",
  root: "Tenant root",
  subscription: "Subscription",
  resourceGroup: "Resource group",
  resource: "Resource"
};

var RELATIONSHIP_LABELS = { member: "Member", owner: "Owner" };
var APP_KIND_LABELS = { appRegistration: "App registration", servicePrincipal: "Service principal" };
var IDENTITY_TYPE_LABELS = { userAssigned: "User-assigned", systemAssigned: "System-assigned" };

// Apps tile scope (items.scope, written by az-Sync-AzResources): "owned" is the
// --show-mine default, "all" is a -AllApps sync. A cache without a scope
// predates the field and was owned-only.
var APP_SCOPE_OWNED = "owned";
var APP_SCOPE_ALL = "all";
var APP_SCOPE_LABELS = {};
APP_SCOPE_LABELS[APP_SCOPE_OWNED] = "Owned";
APP_SCOPE_LABELS[APP_SCOPE_ALL] = "All in tenant";
var SCOPE_LABEL_SR_PREFIX = "Scope: ";
var EXPIRY_STAT_OWNED_SUFFIX = " (apps you own)";
var APPS_EMPTY_OWNED = "No app registrations or service principals list you as an Owner. " +
  "Apps created by others won't appear unless you're added as an owner; " +
  "run az-Sync-AzResources -AllApps to list every app you can read.";
var APPS_EMPTY_ALL = "No app registrations or service principals in this tenant are readable by your account.";

var LABEL_DIRECT = "Direct";
var LABEL_VIA_GROUP = "Via group";
var LABEL_REFRESHING = "refreshing…";
var LABEL_REFRESH_FAILED = "refresh failed";
var LABEL_OFFLINE = "server offline";
var LABEL_NO_CACHE = "no cache yet";
var LABEL_UNREADABLE = "unreadable cache";
var SYNCED_ONLINE = "Local cache";
var CACHED_PREFIX = "cached ";
var REFRESH_FAILED_PREFIX = "Refresh failed: ";
var NO_ROLES_TEXT = "No role assignments";
var ANNOUNCE_REFRESHING_ALL = "Refreshing all tiles…";
var SYNCED_OFFLINE = "Server offline";

// setStaleLabel modes — each maps to one .stale modifier class (ok = none).
var STALE_MODES = ["warn", "none", "busy"];

var NOMATCH_TEXT = "No matching rows in this tile.";
var UNREADABLE_NOTE = "This tile's cache file couldn't be read — refresh it, or run az-Sync-AzResources.";
var EMPTY_RESPONSE = "the server returned an empty response";
var MISSING_NOTE = "No cache yet — refresh this tile, or run az-Sync-AzResources in PowerShell.";
var OFFLINE_NOTE = "The viewer server isn't reachable — start it with az-Start-AzResourceViewer.";
var NOT_PERMITTED_FALLBACK = "Your account isn't permitted to read this in the current tenant.";


// ---------------------------------------------------------------------------
// DOM builder — the single, escaping-safe path from data to page. `text` sets
// textContent and every other key goes through setAttribute, so a malicious
// name renders as inert text. Children may be nodes or plain strings.
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

function portalHref(url) {
  try {
    var parsed = new URL(url);
    if (parsed.origin === PORTAL_ORIGIN) {
      return parsed.href;
    }
  } catch (err) {
    return null;
  }

  return null;
}

// A row title: a new-tab portal link when the URL is a genuine portal URL,
// otherwise plain text (never a dead or unsafe href).
function portalLink(text, url) {
  var href = portalHref(url);
  if (!href) {
    return el("span", { text: text });
  }

  return el("a", { href: href, target: "_blank", rel: "noopener noreferrer", text: text });
}

function chip(text, accent) {
  return el("span", { "class": accent ? "chip accent" : "chip", text: text });
}

function asArray(value) {
  if (Array.isArray(value)) {
    return value;
  }

  if (value === null || value === undefined) {
    return [];
  }

  return [value];
}

function labelFor(map, key) {
  return map[key] || key || "";
}

function joinMeta(parts) {
  return parts.filter(function (part) { return !!part; }).join(META_SEP);
}

// Last segment of an ARM scope ("rg-payments", a subscription GUID, a resource
// name); the tenant root stays "/".
function scopeName(scope) {
  var segments = String(scope || "").split("/").filter(function (s) { return !!s; });
  return segments.length ? segments[segments.length - 1] : SCOPE_ROOT;
}

function formatAge(sec) {
  if (sec < JUST_NOW_SECONDS) {
    return "just now";
  }

  var min = Math.round(sec / SECONDS_PER_MINUTE);
  if (min < MINUTES_PER_HOUR) {
    return min + "m ago";
  }

  var hr = Math.round(min / MINUTES_PER_HOUR);
  if (hr < HOURS_PER_DAY) {
    return hr + "h ago";
  }

  var day = Math.round(hr / HOURS_PER_DAY);
  return day + "d ago";
}

function dateLabel(iso) {
  var when = new Date(iso);
  if (isNaN(when.getTime())) {
    return "";
  }

  return when.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}

// One credential against the expiry window: { status, end, days }. days is
// whole days left (negative once expired); end / days are null with no end date.
function credentialStatus(cred, now) {
  var end = new Date(cred && cred.endDateTime);
  if (isNaN(end.getTime())) {
    return { status: CRED_OK, end: null, days: null };
  }

  var msLeft = end.getTime() - now.getTime();
  var days = Math.floor(msLeft / MS_PER_DAY);
  var status = CRED_OK;

  if (msLeft < 0) {
    status = CRED_EXPIRED;
  } else if (msLeft <= EXPIRY_WINDOW_DAYS * MS_PER_DAY) {
    status = CRED_EXPIRING;
  }

  return { status: status, end: end, days: days };
}

// One entry per real credential. Graph stores a SAML signing certificate as
// several entries (a Sign key, a Verify key and a password credential) sharing
// one customKeyId thumbprint; counting each would report one certificate as
// three. Grouped by thumbprint, else key id; a group keeps its certificate.
// Mirrors Get-AzResourcesDistinctCredentials (azresources_views.ps1).
function distinctCredentials(credentials) {
  var byKey = {};
  var order = [];

  asArray(credentials).forEach(function (cred, index) {
    if (!cred) {
      return;
    }

    var key = cred.customKeyId ? "thumbprint:" + cred.customKeyId : (cred.keyId ? "key:" + cred.keyId : "entry:" + index);

    if (!byKey[key]) {
      byKey[key] = cred;
      order.push(key);
    } else if (byKey[key].kind !== CRED_KIND_CERTIFICATE && cred.kind === CRED_KIND_CERTIFICATE) {
      byKey[key] = cred;
    }
  });

  return order.map(function (key) { return byKey[key]; });
}

// An app's credentials rolled up: how many are expired / expiring, the soonest
// end date still ahead (an old expired secret mustn't mask the one about to
// lapse), and the days left on the soonest expiring one.
function appExpiry(credentials, now) {
  var summary = { expired: 0, expiring: 0, nextEnd: null, expiringDays: null };

  distinctCredentials(credentials).forEach(function (cred) {
    var c = credentialStatus(cred, now);

    if (c.status === CRED_EXPIRED) {
      summary.expired++;
      return;
    }

    if (c.end && (summary.nextEnd === null || c.end < summary.nextEnd)) {
      summary.nextEnd = c.end;
    }

    if (c.status === CRED_EXPIRING) {
      summary.expiring++;

      if (summary.expiringDays === null || c.days < summary.expiringDays) {
        summary.expiringDays = c.days;
      }
    }
  });

  return summary;
}

// "1 day" / "5 days" — spelled out so screen readers and the uppercase chip
// style don't turn it into "5D".
function daysLabel(days) {
  return days === 1 ? "1 day" : days + " days";
}

// Expiry badges: the words carry the meaning ("Expired", "Expires in 5 days"), and
// color only reinforces them, so they read without color and in both themes.
function expiryBadges(expiry) {
  var badges = [];

  if (expiry.expired) {
    var expiredText = expiry.expired === 1 ? LABEL_EXPIRED : expiry.expired + LABEL_EXPIRED_COUNT_SUFFIX;
    badges.push(el("span", { "class": "chip expired", text: expiredText }));
  }

  if (expiry.expiring) {
    var isToday = expiry.expiringDays <= 0;
    var expiringText;

    if (expiry.expiring === 1) {
      expiringText = isToday ? LABEL_EXPIRES_TODAY : LABEL_EXPIRES_IN_PREFIX + daysLabel(expiry.expiringDays);
    } else {
      // Several expiring: say how many, so the rows add up to the summary stat.
      var soonest = isToday ? LABEL_SOONEST_TODAY : LABEL_SOONEST_IN_PREFIX + daysLabel(expiry.expiringDays);
      expiringText = expiry.expiring + LABEL_EXPIRING_COUNT_SUFFIX + META_SEP + soonest;
    }
    badges.push(el("span", { "class": "chip expiring", text: expiringText }));
  }

  return badges;
}

// Records cached before isOwner existed came from --show-mine, so they're owned.
function isOwnedApp(a) {
  return a.isOwner !== false;
}

// Mirrors Resolve-AzResourcesAppScope (azresources_views.ps1): an unknown or
// missing scope is "owned".
function appScope(items) {
  var isKnown = !!items && Object.prototype.hasOwnProperty.call(APP_SCOPE_LABELS, items.scope);
  return isKnown ? items.scope : APP_SCOPE_OWNED;
}

function isAllAppsScope(items) {
  return appScope(items) === APP_SCOPE_ALL;
}

// Expired + expiring credentials across the apps you own, for the summary
// strip — an all-in-tenant sync mustn't flood it with other teams' secrets.
function countFlaggedCredentials(records, now) {
  return records.filter(isOwnedApp).reduce(function (total, a) {
    var expiry = appExpiry(a.credentials, now);
    return total + expiry.expired + expiry.expiring;
  }, 0);
}


// ---------------------------------------------------------------------------
// Row builders — one per tile, each returning a single <li>.
// ---------------------------------------------------------------------------

function roleRow(r) {
  var isMine = r.principal === SELF_PRINCIPAL;

  var head = el("div", { "class": "row-head" }, [
    el("span", { "class": "row-title" }, [portalLink(r.roleName, r.portalUrl)]),
    chip(isMine ? LABEL_DIRECT : LABEL_VIA_GROUP, isMine),
    chip(labelFor(SCOPE_TYPE_LABELS, r.scopeType))
  ]);

  var meta = el("div", { "class": "row-meta", text: joinMeta([
    scopeName(r.scope),
    r.subscriptionName,
    isMine ? "" : "via " + r.principal
  ]) });

  return el("li", { "class": "row" }, [head, meta]);
}

function groupRow(g) {
  var isOwner = g.relationship === RELATIONSHIP_OWNER;

  var head = el("div", { "class": "row-head" }, [
    el("span", { "class": "row-title" }, [portalLink(g.displayName, g.portalUrl)]),
    chip(labelFor(RELATIONSHIP_LABELS, g.relationship), isOwner)
  ]);

  var meta = el("div", { "class": "row-meta", text: joinMeta([g.groupType, g.mail]) });

  return el("li", { "class": "row" }, [head, meta]);
}

// now: one timestamp per render pass, shared with the summary stat so a
// credential on a boundary can't be "expiring" in the row but not the stat.
// Expiry badges sit on owned apps only, so the rows add up to that stat; in an
// all-in-tenant sync an Owner chip marks which apps are yours.
function appRow(a, now, items) {
  var credentials = distinctCredentials(a.credentials);
  var expiry = appExpiry(credentials, now);
  var isOwned = isOwnedApp(a);

  var credentialText = credentials.length === 1 ? "1 credential" : credentials.length + " credentials";
  var expiryText = isOwned && expiry.nextEnd ? "next expiry " + dateLabel(expiry.nextEnd.toISOString()) : "";

  var chips = [chip(labelFor(APP_KIND_LABELS, a.kind))];

  if (isAllAppsScope(items) && isOwned) {
    chips.push(chip(RELATIONSHIP_LABELS.owner, true));
  }

  if (isOwned) {
    chips = chips.concat(expiryBadges(expiry));
  }

  var head = el("div", { "class": "row-head" }, [
    el("span", { "class": "row-title" }, [portalLink(a.displayName, a.portalUrl)])
  ].concat(chips));

  var meta = el("div", { "class": "row-meta" }, [joinMeta([credentialText, expiryText])]);

  if (a.appId) {
    meta.appendChild(document.createTextNode(META_SEP));
    meta.appendChild(el("span", { "class": "mono", text: a.appId }));
  }

  return el("li", { "class": "row" }, [head, meta]);
}

function identityRow(i) {
  var roles = asArray(i.roles);

  var head = el("div", { "class": "row-head" }, [
    el("span", { "class": "row-title" }, [portalLink(i.name, i.portalUrl)]),
    chip(labelFor(IDENTITY_TYPE_LABELS, i.type))
  ]);

  var meta = el("div", { "class": "row-meta", text: joinMeta([i.resourceGroup, i.subscriptionName]) });

  var roleItems;
  if (roles.length) {
    roleItems = roles.map(function (role) {
      return el("li", { text: role.roleName + ROLE_SCOPE_SEP + scopeName(role.scope) });
    });
  } else {
    roleItems = [el("li", { text: NO_ROLES_TEXT })];
  }

  var roleList = el("ul", { "class": "role-list", "aria-label": "Roles held" }, roleItems);

  return el("li", { "class": "row" }, [head, meta, roleList]);
}

function appsEmptyNote(items) {
  return isAllAppsScope(items) ? APPS_EMPTY_ALL : APPS_EMPTY_OWNED;
}

function appsScopeLabel(items) {
  return APP_SCOPE_LABELS[appScope(items)];
}

// emptyNote is a string, or a function of the tile's items (see
// resolveEmptyNote); scopeLabel (apps only) names the sync mode in the header.
var TILES = {
  roles:      { name: "role assignments",            emptyNote: "No role assignments in the cache.",           row: roleRow },
  groups:     { name: "Entra groups",                emptyNote: "No group memberships in the cache.",          row: groupRow },
  apps:       { name: "apps and service principals", emptyNote: appsEmptyNote,                                 row: appRow, summary: setExpiryStat, scopeLabel: appsScopeLabel },
  identities: { name: "managed identities",          emptyNote: "No managed identities in readable subscriptions.", row: identityRow }
};

var TILE_KEYS = Object.keys(TILES);


// ---------------------------------------------------------------------------
// Render — the view is a function of tileState[key]
// ---------------------------------------------------------------------------

// tileState[key] = { model: <payload> } | { missing: true } | { offline: true },
// plus refreshError: <server reason> while the last refresh of that tile failed.
var tileState = {};

function tile(key) {
  return document.getElementById("tile-" + key);
}

// :not([data-stat]) — the apps tile also feeds the expiry stat, which shares
// its data-tile so clicking it jumps to the apps tile.
function setStat(key, text) {
  var stat = document.querySelector('.stat[data-tile="' + key + '"]:not([data-stat]) .n');
  if (stat) {
    stat.textContent = text;
  }
}

// The summary strip's expired + expiring count, derived from the apps records
// (null while they're unavailable). .alert highlights a non-zero count. After
// an all-in-tenant sync the label says it covers only the apps you own.
function setExpiryStat(records, now, items) {
  var stat = document.querySelector(EXPIRY_STAT);
  if (!stat) {
    return;
  }

  var flagged = records ? countFlaggedCredentials(records, now) : null;

  var ownedSuffix = isAllAppsScope(items) ? EXPIRY_STAT_OWNED_SUFFIX : "";
  stat.querySelector(".l").textContent = EXPIRY_STAT_LABEL_PREFIX + EXPIRY_WINDOW_DAYS + EXPIRY_STAT_LABEL_SUFFIX + ownedSuffix;
  stat.querySelector(".n").textContent = flagged === null ? MISSING_STAT : String(flagged);
  stat.classList.toggle("alert", flagged > 0);
}

function renderSummary(spec, records, now, items) {
  if (spec.summary) {
    spec.summary(records, now, items);
  }
}

function setStaleLabel(key, text, mode) {
  var stale = tile(key).querySelector(".stale");

  STALE_MODES.forEach(function (m) {
    stale.classList.toggle(m, m === mode);
  });

  stale.querySelector(".stale-label").textContent = text;
}

// The header's sync-mode label, for tiles that have one (empty hides it). The
// visually hidden prefix tells a screen reader what "Owned" refers to.
function setScopeLabel(spec, t, items) {
  var label = t.querySelector(".scope-label");
  if (!label) {
    return;
  }

  var text = spec.scopeLabel && items ? spec.scopeLabel(items) : "";

  if (text) {
    label.replaceChildren(el("span", { "class": "sr-only", text: SCOPE_LABEL_SR_PREFIX }), document.createTextNode(text));
  } else {
    label.replaceChildren();
  }
}

function resolveEmptyNote(spec, items) {
  return typeof spec.emptyNote === "function" ? spec.emptyNote(items) : spec.emptyNote;
}

function renderNote(body, text, className) {
  body.appendChild(el("p", { "class": className || "empty-note", text: text }));
}

function renderTile(key) {
  var spec = TILES[key];
  var state = tileState[key] || {};
  var t = tile(key);
  var body = t.querySelector(".body");
  var count = t.querySelector(".count");
  var now = new Date();

  body.replaceChildren();
  count.textContent = "";
  setScopeLabel(spec, t, null);
  renderSummary(spec, null, now);

  if (state.refreshError) {
    renderNote(body, REFRESH_FAILED_PREFIX + state.refreshError, "notice");
  }

  if (state.offline) {
    renderNote(body, OFFLINE_NOTE);
    setStat(key, MISSING_STAT);
    setStaleLabel(key, LABEL_OFFLINE, "warn");
    return;
  }

  if (state.missing || !state.model) {
    renderNote(body, MISSING_NOTE);
    setStat(key, MISSING_STAT);
    setStaleLabel(key, LABEL_NO_CACHE, "none");
    return;
  }

  if (!state.model.items) {
    renderNote(body, UNREADABLE_NOTE);
    setStat(key, MISSING_STAT);
    setStaleLabel(key, LABEL_UNREADABLE, "warn");
    return;
  }

  var model = state.model;
  var items = model.items;
  setScopeLabel(spec, t, items);
  if (state.refreshError) {
    setStaleLabel(key, LABEL_REFRESH_FAILED, "warn");
  } else {
    setStaleLabel(key, CACHED_PREFIX + formatAge(model.ageSeconds), model.stale ? "warn" : "ok");
  }

  if (items.state === STATE_NOT_PERMITTED) {
    renderNote(body, items.message || NOT_PERMITTED_FALLBACK, "notice");
    setStat(key, MISSING_STAT);
    return;
  }

  if (items.message) {
    renderNote(body, items.message, "notice");
  }

  var records = asArray(items.records);
  count.textContent = String(records.length);
  setStat(key, String(records.length));
  renderSummary(spec, records, now, items);

  if (!records.length) {
    renderNote(body, resolveEmptyNote(spec, items));
    return;
  }

  body.appendChild(el("ul", { "class": "rows" }, records.map(function (record) { return spec.row(record, now, items); })));
  renderNote(body, NOMATCH_TEXT, "nomatch");
}


// Re-render one tile and re-apply the active filter, so a refresh (successful
// or not) never silently drops the user's search.
function repaintTile(key) {
  renderTile(key);
  applyFilter(searchBox.value);
}


// ---------------------------------------------------------------------------
// Data layer — cheap GET on load, expensive POST /refresh on demand
// ---------------------------------------------------------------------------

function request(url, options) {
  return fetch(url, options).then(function (res) {
    return res.json().catch(function () { return null; }).then(function (data) {
      return { ok: res.ok, status: res.status, data: data };
    });
  });
}

function loadTile(key) {
  return request(API + key, { headers: ACCEPT_JSON })
    .then(function (res) {
      if (res.ok) {
        tileState[key] = { model: res.data };
      } else if (res.status === HTTP_NOT_FOUND) {
        tileState[key] = { missing: true };
      } else {
        tileState[key] = { offline: true };
      }
    })
    .catch(function () {
      tileState[key] = { offline: true };
    })
    .then(function () {
      renderTile(key);
    });
}

function loadContext() {
  return request(CONTEXT_API, { headers: ACCEPT_JSON })
    .then(function (res) {
      if (res.ok && res.data && res.data.tenantId) {
        document.getElementById("tenant-id").textContent = "tenant " + res.data.tenantId;
      }
    })
    .catch(function () {
      // Offline preview: keep the static fallback text.
    });
}


// ---------------------------------------------------------------------------
// Controls — announce, refresh, expand/collapse, stat jump, theme, filter.
// ---------------------------------------------------------------------------

// Named liveRegion, not `status`: a top-level `var status` in a classic script
// aliases the built-in window.status string and breaks under strict mode.
var liveRegion = document.getElementById("sr-status");

function announce(message) {
  if (liveRegion) {
    liveRegion.textContent = message;
  }
}

// Refresh one tile. Resolves to { name, ok, reason } so "Refresh all" can
// announce one summary; a single refresh announces its own outcome. A failure
// keeps the previous rows and shows the server's reason in the tile itself, not
// only to screen readers.
function refreshTile(btn, quiet) {
  var key = btn.getAttribute("data-tile");
  if (btn.disabled || !TILES[key]) {
    return Promise.resolve(null);
  }

  var name = TILES[key].name;

  btn.disabled = true;
  btn.classList.add("spinning");
  setStaleLabel(key, LABEL_REFRESHING, "busy");

  if (!quiet) {
    announce("Refreshing " + name + "…");
  }

  // Repaint BEFORE announcing: the repaint re-applies the filter, which
  // announces its own match count and would otherwise overwrite the outcome.
  function settle(ok, reason) {
    if (!ok) {
      tileState[key] = Object.assign({}, tileState[key], { refreshError: reason });
    }

    repaintTile(key);
    btn.classList.remove("spinning");
    btn.disabled = false;

    if (ok) {
      announceIf(quiet, "Refreshed " + name + " — cached just now.");
    } else {
      announceIf(quiet, "Couldn't refresh " + name + ": " + reason);
    }

    return { name: name, ok: ok, reason: reason };
  }

  return request(API + key + REFRESH_SUFFIX, { method: "POST", headers: JSON_HEADERS, body: EMPTY_JSON_BODY })
    .then(function (res) {
      setSyncedOffline(false);

      if (res.ok && res.data) {
        tileState[key] = { model: res.data };
        return settle(true, "");
      }

      return settle(false, failureReason(res));
    })
    .catch(function () {
      setSyncedOffline(true);
      return settle(false, OFFLINE_NOTE);
    });
}

// The server's own explanation when it gave one, else the HTTP status; a 200
// with no body is its own failure.
function failureReason(res) {
  if (res.ok) {
    return EMPTY_RESPONSE;
  }

  if (res.data && res.data.error) {
    return res.data.error;
  }

  return "HTTP " + res.status;
}

function announceIf(quiet, message) {
  if (!quiet) {
    announce(message);
  }
}

document.querySelectorAll(".refresh-btn").forEach(function (btn) {
  btn.addEventListener("click", function (e) {
    // The button sits inside <summary>; don't let the click toggle the tile.
    e.preventDefault();
    e.stopPropagation();
    refreshTile(btn);
  });
});

// Refresh every tile, then announce ONE summary — four overlapping
// announcements would overwrite each other in the single live region.
document.getElementById("refreshAll").addEventListener("click", function () {
  var buttons = Array.prototype.slice.call(document.querySelectorAll(".refresh-btn"));

  announce(ANNOUNCE_REFRESHING_ALL);

  Promise.all(buttons.map(function (btn) { return refreshTile(btn, true); })).then(function (results) {
    var ran = results.filter(function (r) { return r !== null; });
    var failed = ran.filter(function (r) { return !r.ok; });

    if (!failed.length) {
      announce("Refreshed all " + ran.length + " tiles.");
      return;
    }

    var names = failed.map(function (r) { return r.name; }).join(", ");
    announce("Refreshed " + (ran.length - failed.length) + " of " + ran.length + " tiles. Failed: " + names + ".");
  });
});

function setAllTilesOpen(open) {
  document.querySelectorAll(TILE_DETAILS).forEach(function (d) { d.open = open; });
}

document.getElementById("expandAll").addEventListener("click", function () {
  setAllTilesOpen(true);
});

document.getElementById("collapseAll").addEventListener("click", function () {
  setAllTilesOpen(false);
});

// The "Local cache" chip doubles as the connection indicator: any answer from
// the server flips it back online, a network failure flips it offline.
var syncedChip = document.querySelector(".synced");
var syncedLabel = syncedChip.querySelector(".synced-label");

function setSyncedOffline(offline) {
  syncedChip.classList.toggle("offline", offline);
  syncedLabel.textContent = offline ? SYNCED_OFFLINE : SYNCED_ONLINE;
}

var reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

document.querySelectorAll(".stat").forEach(function (stat) {
  stat.addEventListener("click", function () {
    var target = tile(stat.getAttribute("data-tile"));
    if (!target) {
      return;
    }

    target.querySelector("details").open = true;
    target.scrollIntoView({ behavior: reducedMotion.matches ? "auto" : "smooth", block: "start" });
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


// Live filter across every tile's rows. A tile whose rows are all filtered out
// shows its "no matching rows" note; the count badges keep the full totals.
function applyFilter(raw) {
  var q = raw.trim().toLowerCase();
  var matchTotal = 0;

  if (q) {
    setAllTilesOpen(true);
  }

  document.querySelectorAll(".tile").forEach(function (t) {
    var rows = t.querySelectorAll(".row");
    var anyVisible = false;

    rows.forEach(function (row) {
      var match = !q || row.textContent.toLowerCase().indexOf(q) !== -1;
      row.classList.toggle("hide", !match);

      if (match) {
        anyVisible = true;
        matchTotal++;
      }
    });

    t.classList.toggle("empty", !!q && rows.length > 0 && !anyVisible);
  });

  if (q) {
    announce(matchTotal + (matchTotal === 1 ? " row matches." : " rows match."));
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
// Boot — cache-first: every tile paints from its cheap GET. No az call runs
// until the user presses a refresh button.
// ---------------------------------------------------------------------------

loadContext();

Promise.all(TILE_KEYS.map(loadTile)).then(function () {
  var offline = TILE_KEYS.some(function (key) { return tileState[key] && tileState[key].offline; });
  if (offline) {
    setSyncedOffline(true);
    announce("The viewer server isn't reachable.");
  }
});
