(function () {
  "use strict";

  var DATA = {frames: []};
  var dataNode = document.querySelector("[data-webconsole-frames]");
  if (dataNode) {
    try { DATA = JSON.parse(dataNode.textContent); } catch (e) { DATA = {frames: []}; }
  }

  var frames = DATA.frames || [];
  var current = DATA.initialFrame || 0;
  var activeTab = "locals";
  var replLog = {};
  var expired = false;

  /* Console state lives out here, keyed by frame index, because renderConsole() rebuilds the
     input element from scratch — including when a pending evaluation resolves under you. */
  var replHistory = {}; // submitted expressions, oldest first
  var replCursor = {};  // position in that history, or null when not navigating
  var replDraft = {};   // what was typed before navigating, restored on the way back down
  var replValue = {};   // what is in the box right now, so a re-render cannot clear it

  function q(sel, root) { return (root || document).querySelector(sel); }
  function qa(sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }

  function esc(s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }

  function el(tag, className, text) {
    var node = document.createElement(tag);
    if (className) { node.className = className; }
    if (text !== undefined && text !== null) { node.textContent = text; }
    return node;
  }

  function icon(name, cls) {
    var svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("class", "icon" + (cls ? " " + cls : ""));
    svg.setAttribute("aria-hidden", "true");
    var use = document.createElementNS("http://www.w3.org/2000/svg", "use");
    use.setAttribute("href", "#i-" + name);
    svg.appendChild(use);
    return svg;
  }

  /* Ruby highlighter, ported verbatim from the design mockup. */
  var KEYWORDS = "def|end|module|class|if|unless|else|elsif|while|until|do|then|return|yield|self|nil|true|false|require|require_relative|include|extend|attr_reader|attr_writer|attr_accessor|begin|rescue|ensure|raise|new|case|when|in|next|break|and|or|not|super|lambda|proc|private|public|protected";
  var TOKENS = new RegExp(
    "(#[^\\n]*)" +
    "|(\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*')" +
    "|(@@?[A-Za-z_][A-Za-z0-9_]*)" +
    "|(:[A-Za-z_][A-Za-z0-9_]*[?!]?)" +
    "|\\b(" + KEYWORDS + ")\\b" +
    "|\\b([A-Z][A-Za-z0-9_]*)\\b" +
    "|\\b(\\d+(?:\\.\\d+)?)\\b", "g");

  function highlight(line) {
    var out = "", last = 0, m;
    TOKENS.lastIndex = 0;
    while ((m = TOKENS.exec(line)) !== null) {
      out += esc(line.slice(last, m.index));
      var cls = m[1] ? "c" : m[2] ? "s" : m[3] ? "v" : m[4] ? "y" : m[5] ? "k" : m[6] ? "t" : "n";
      out += '<span class="' + cls + '">' + esc(m[0]) + "</span>";
      last = m.index + m[0].length;
    }
    return out + esc(line.slice(last));
  }

  var frameList = q("[data-webconsole-frame-list]");
  var framesNote = q("[data-webconsole-frames-note]");
  var codeEl = q("[data-webconsole-code]");
  var srcPath = q("[data-webconsole-source-path]");
  var openEditor = q("[data-webconsole-open-editor]");
  var varsPanel = q("[data-webconsole-panel]");
  var workbench = q("[data-webconsole-workbench]");
  var context = q("[data-webconsole-context]");

  function tab(name) { return q('[data-webconsole-tab="' + name + '"]'); }
  function tabCount(name) { return q('[data-webconsole-tab-count="' + name + '"]'); }

  /* ── frames ────────────────────────────────────────────── */
  function renderFrames() {
    qa("[data-webconsole-frame]").forEach(function (btn) {
      var index = Number(btn.getAttribute("data-webconsole-frame-index"));
      btn.setAttribute("aria-current", index === current ? "true" : "false");
    });

    if (!framesNote || !frameList) { return; }
    var appCount = frames.filter(function (f) { return f.kind === "app"; }).length;
    var hidden = frames.length - appCount;
    framesNote.textContent = frameList.classList.contains("app-only")
      ? hidden + (hidden === 1 ? " framework or gem frame hidden" : " framework and gem frames hidden")
      : frames.length + (frames.length === 1 ? " frame · " : " frames · ") + appCount + " in your application";
  }

  function setFilter(appOnly) {
    if (frameList) { frameList.classList.toggle("app-only", appOnly); }
    var app = q('[data-webconsole-filter="app"]');
    var all = q('[data-webconsole-filter="all"]');
    if (app) { app.setAttribute("aria-pressed", appOnly ? "true" : "false"); }
    if (all) { all.setAttribute("aria-pressed", appOnly ? "false" : "true"); }
    renderFrames();
  }

  /* ── source ────────────────────────────────────────────── */
  function renderSource() {
    var f = frames[current];
    if (!f || !codeEl) { return; }

    if (srcPath) {
      srcPath.innerHTML = f.kind === "app"
        ? esc(f.displayPath) + '<span class="dim">:' + esc(f.line) + "</span>"
        : '<span class="dim">' + esc(f.displayPath) + ":" + esc(f.line) + "</span>";
    }

    if (openEditor) {
      if (f.editorUrl) {
        openEditor.hidden = false;
        openEditor.setAttribute("href", f.editorUrl);
      } else {
        openEditor.hidden = true;
      }
    }

    if (!f.src || !f.src.length) {
      codeEl.textContent = "";
      codeEl.appendChild(el("p", "empty", "Source is not available for this frame."));
      return;
    }

    codeEl.innerHTML = f.src.map(function (line, idx) {
      var no = f.start + idx;
      return '<div class="row' + (no === f.line ? " err" : "") + '">' +
        '<span class="gutter">' + esc(no) + "</span>" +
        '<span class="txt">' + highlight(line) + "</span></div>";
    }).join("");
  }

  /* ── variables ─────────────────────────────────────────── */
  function varsTable(rows) {
    var wrap = el("div", "vars-wrap");
    var table = el("table", "vars");
    var thead = document.createElement("thead");
    var headRow = document.createElement("tr");
    ["Name", "Class", "Value"].forEach(function (label) {
      headRow.appendChild(el("th", null, label));
    });
    thead.appendChild(headRow);
    table.appendChild(thead);

    var tbody = document.createElement("tbody");
    tbody.setAttribute("data-webconsole-vars", "");
    rows.forEach(function (row) {
      var tr = document.createElement("tr");
      tr.appendChild(el("td", "vname", row[0]));
      tr.appendChild(el("td", "vtype", row[1]));
      tr.appendChild(el("td", "vval", row[2]));
      tbody.appendChild(tr);
    });
    table.appendChild(tbody);
    wrap.appendChild(table);
    return wrap;
  }

  function emptyPanel(node) {
    varsPanel.textContent = "";
    varsPanel.appendChild(node);
  }

  function bindingsMissing() {
    var p = el("p", "empty");
    p.setAttribute("data-webconsole-no-bindings", "");
    p.appendChild(document.createTextNode("Variable capture and the console are off."));
    p.appendChild(document.createElement("br"));
    p.appendChild(document.createTextNode('Add gem "binding_of_caller" to your :development group '));
    p.appendChild(document.createTextNode("to inspect frames and evaluate in their bindings."));
    return p;
  }

  function renderVars() {
    if (!varsPanel) { return; }
    var f = frames[current] || {locals: [], ivars: []};
    var available = !!(DATA.bindingsAvailable && f.binding);
    var locals = available ? (f.locals || []) : [];
    var ivars = available ? (f.ivars || []) : [];
    var logged = (replLog[current] || []).length;

    if (tabCount("locals")) { tabCount("locals").textContent = available ? locals.length : "—"; }
    if (tabCount("ivars")) { tabCount("ivars").textContent = available ? ivars.length : "—"; }
    if (tabCount("console")) { tabCount("console").textContent = available ? (logged || "") : "—"; }

    ["locals", "ivars", "console"].forEach(function (name) {
      var button = tab(name);
      if (button) { button.setAttribute("aria-selected", activeTab === name ? "true" : "false"); }
    });

    if (!available) {
      emptyPanel(DATA.bindingsAvailable
        ? el("p", "empty", "No binding was captured for this frame.")
        : bindingsMissing());
      return;
    }

    if (activeTab === "console") { renderConsole(); return; }

    var rows = activeTab === "locals" ? locals : ivars;
    if (!rows.length) {
      emptyPanel(el("p", "empty", "No " + (activeTab === "locals" ? "local" : "instance") +
        " variables in this frame."));
      return;
    }
    emptyPanel(varsTable(rows));
  }

  /* ── console ───────────────────────────────────────────── */
  function csrfToken() {
    if (DATA.csrfToken) { return DATA.csrfToken; }
    var name = (DATA.csrfCookie || "") + "=";
    var parts = document.cookie ? document.cookie.split(";") : [];
    for (var i = 0; i < parts.length; i++) {
      var cookie = parts[i].trim();
      if (cookie.indexOf(name) === 0) { return decodeURIComponent(cookie.slice(name.length)); }
    }
    return "";
  }

  function evaluate(index, source) {
    if (!DATA.evalPath || !window.fetch) {
      return Promise.resolve({output: "The console is unavailable in this browser.", error: true});
    }
    return window.fetch(DATA.evalPath, {
      method: "POST",
      credentials: "same-origin",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({csrfToken: csrfToken(), index: index, source: source})
    }).then(function (response) {
      if (response.status === 410) { return {expired: true}; }
      return response.json().then(function (body) {
        return {output: body.output, error: !!body.error};
      }, function () {
        return {output: "The console received a malformed response.", error: true};
      });
    }, function () {
      return {output: "The console could not reach the development server.", error: true};
    });
  }

  function replLine(prefix, text, cls) {
    var line = el("div", "repl-line " + cls);
    line.appendChild(el("span", "pr", prefix));
    line.appendChild(el("span", "body", text));
    return line;
  }

  function replHint(frame) {
    var p = el("p", "repl-hint");
    p.appendChild(document.createTextNode("Evaluates in this frame's binding. Try "));
    p.appendChild(el("code", null, (frame.locals && frame.locals.length) ? frame.locals[0][0] : "self"));
    p.appendChild(document.createTextNode(" or "));
    p.appendChild(el("code", null, "local_variables"));
    p.appendChild(document.createTextNode("."));
    return p;
  }

  /* Sets the box and parks the caret at the end, the way a shell does. */
  function replSetValue(input, value) {
    input.value = value;
    replValue[current] = value;
    try {
      input.setSelectionRange(value.length, value.length);
    } catch (e) {
      /* setSelectionRange is not supported on every input type; harmless. */
    }
  }

  function replHistoryBack(input) {
    var history = replHistory[current] || [];
    if (!history.length) { return; }

    var position = replCursor[current];
    if (position === null || position === undefined) {
      // Entering history: stash the draft so ArrowDown can bring it back.
      replDraft[current] = input.value;
      position = history.length;
    }
    if (position === 0) { return; }

    replCursor[current] = position - 1;
    replSetValue(input, history[position - 1]);
  }

  function replHistoryForward(input) {
    var history = replHistory[current] || [];
    var position = replCursor[current];
    if (position === null || position === undefined) { return; }

    position += 1;
    if (position >= history.length) {
      // Past the newest entry, back to whatever was being typed.
      replCursor[current] = null;
      replSetValue(input, replDraft[current] || "");
      return;
    }

    replCursor[current] = position;
    replSetValue(input, history[position]);
  }

  function renderConsole() {
    var f = frames[current] || {locals: []};
    var log = replLog[current] || [];

    var repl = el("div", "repl");
    repl.setAttribute("data-webconsole-repl", "");

    var scroll = el("div", "repl-scroll");
    scroll.setAttribute("data-webconsole-repl-log", "");
    if (!log.length) {
      scroll.appendChild(replHint(f));
    } else {
      log.forEach(function (entry) {
        scroll.appendChild(replLine(">>", entry.input, "repl-in"));
        var cls = entry.pending ? "repl-pending" : (entry.error ? "repl-err" : "repl-out");
        entry.lines.forEach(function (line, i) {
          scroll.appendChild(replLine(i === 0 ? (entry.error ? "!" : "=>") : " ", line, cls));
        });
      });
    }
    repl.appendChild(scroll);

    if (expired) {
      var gone = el("div", "repl-expired");
      gone.setAttribute("data-webconsole-repl-expired", "");
      gone.appendChild(document.createTextNode(
        "This console session ended when the application reloaded."
      ));
      var reload = el("button", "btn-ghost", "Refresh the page");
      reload.type = "button";
      reload.setAttribute("data-webconsole-reload", "");
      reload.addEventListener("click", function () { window.location.reload(); });
      gone.appendChild(reload);
      repl.appendChild(gone);
    } else {
      var form = el("div", "repl-form");
      form.appendChild(el("span", "pr", ">>"));
      var input = document.createElement("input");
      input.type = "text";
      input.setAttribute("data-webconsole-repl-input", "");
      input.setAttribute("placeholder", "Ruby expression");
      input.setAttribute("autocomplete", "off");
      input.setAttribute("autocapitalize", "off");
      input.setAttribute("spellcheck", "false");
      input.setAttribute("aria-label", "Ruby expression");
      input.value = replValue[current] || "";
      input.addEventListener("input", function () {
        // Typing leaves history navigation and makes this the new draft.
        replValue[current] = input.value;
        replDraft[current] = input.value;
        replCursor[current] = null;
      });
      input.addEventListener("keydown", function (event) {
        if (event.key === "Enter") {
          event.preventDefault();
          submitExpression(input.value);
        } else if (event.key === "ArrowUp") {
          event.preventDefault();
          replHistoryBack(input);
        } else if (event.key === "ArrowDown") {
          event.preventDefault();
          replHistoryForward(input);
        }
      });
      form.appendChild(input);
      var enter = el("span", "enter");
      enter.appendChild(icon("corner-down-left"));
      form.appendChild(enter);
      repl.appendChild(form);
    }

    var note = el("p", "repl-note");
    note.appendChild(icon("lock"));
    note.appendChild(document.createTextNode(
      "localhost only · CSRF-protected · session ends at the next code reload"
    ));
    repl.appendChild(note);

    varsPanel.textContent = "";
    varsPanel.appendChild(repl);

    scroll.scrollTop = scroll.scrollHeight;
    if (activeTab === "console" && !expired) {
      var live = q("[data-webconsole-repl-input]");
      if (live) { live.focus(); }
    }
  }

  function submitExpression(value) {
    var source = value.trim();
    if (!source || expired) { return; }

    var index = current;

    // Record it for ArrowUp, skipping an immediate repeat, and reset the box.
    var history = replHistory[index] || (replHistory[index] = []);
    if (history[history.length - 1] !== source) { history.push(source); }
    replCursor[index] = null;
    replDraft[index] = "";
    replValue[index] = "";

    var entry = {input: source, lines: ["…"], error: false, pending: true};
    replLog[index] = (replLog[index] || []).concat([entry]);
    renderVars();

    evaluate(index, source).then(function (result) {
      if (result.expired) {
        expired = true;
        entry.pending = false;
        entry.error = true;
        entry.lines = ["This page's console session has expired."];
      } else {
        entry.pending = false;
        entry.error = !!result.error;
        entry.lines = String(result.output === undefined || result.output === null ? "" : result.output).split("\n");
      }
      if (index === current && activeTab === "console") { renderConsole(); }
    });
  }

  /* ── clipboard ─────────────────────────────────────────── */
  function copyText(text, btn, restore) {
    function done(ok) {
      var label = btn.querySelector(".label");
      var use = btn.querySelector("use");
      var msg = ok ? "Copied" : "Copy failed";
      if (label) { label.textContent = msg; } else { btn.textContent = msg; }
      if (use && ok) { use.setAttribute("href", "#i-check"); }
      window.setTimeout(function () {
        if (label) { label.textContent = restore; } else { btn.textContent = restore; }
        if (use) { use.setAttribute("href", "#i-copy"); }
      }, 1600);
    }
    function fallback() {
      var ta = document.createElement("textarea");
      ta.value = text;
      ta.setAttribute("readonly", "");
      ta.style.position = "fixed";
      ta.style.top = "-1000px";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      var ok = false;
      try { ok = document.execCommand("copy"); } catch (e) { ok = false; }
      document.body.removeChild(ta);
      done(ok);
    }
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(function () { done(true); }, fallback);
    } else {
      fallback();
    }
  }

  /* ── context panel search ──────────────────────────────── */
  function mark(text, needle) {
    if (!needle) { return esc(text); }
    var idx = text.toLowerCase().indexOf(needle);
    if (idx === -1) { return esc(text); }
    return esc(text.slice(0, idx)) + "<mark>" + esc(text.slice(idx, idx + needle.length)) +
      "</mark>" + esc(text.slice(idx + needle.length));
  }

  function wireSearch(panel) {
    var input = q("[data-webconsole-search]", panel);
    if (!input) { return; }
    var clear = q("[data-webconsole-search-clear]", panel);
    var empty = q("[data-webconsole-context-empty]", panel);
    var count = q("[data-webconsole-context-count]", panel);
    var noun = (count && count.getAttribute("data-webconsole-noun")) || "rows";

    var rows = qa("[data-webconsole-row]", panel).map(function (row) {
      var key = q("[data-webconsole-row-key]", row);
      var value = q("[data-webconsole-row-value]", row);
      return {
        row: row,
        key: key,
        value: value,
        keyText: key ? key.textContent : "",
        valueText: value ? value.textContent : "",
        near: row.hasAttribute("data-webconsole-near")
      };
    });

    function apply() {
      var needle = input.value.trim().toLowerCase();
      var matched = 0;
      rows.forEach(function (entry) {
        var hit = !needle ||
          (entry.keyText + " " + entry.valueText).toLowerCase().indexOf(needle) !== -1;
        entry.row.hidden = !hit;
        if (hit) { matched += 1; }
        if (entry.key) { entry.key.innerHTML = mark(entry.keyText, needle); }
        if (entry.value) { entry.value.innerHTML = mark(entry.valueText, needle); }
        // Near-match emphasis is a property of the unfiltered view; searching supersedes it.
        entry.row.classList.toggle("is-near", entry.near && !needle);
      });
      if (empty) { empty.hidden = matched !== 0; }
      if (clear) { clear.hidden = !needle; }
      if (count) {
        count.textContent = needle
          ? matched + " of " + rows.length + " " + noun
          : rows.length + " " + noun + " · press / to filter";
      }
    }

    input.addEventListener("input", apply);
    input.addEventListener("keydown", function (event) {
      if (event.key === "Escape") { input.value = ""; apply(); }
    });
    if (clear) {
      clear.addEventListener("click", function () {
        input.value = "";
        apply();
        input.focus();
      });
    }
  }

  /* ── wiring ────────────────────────────────────────────── */
  qa("[data-webconsole-frame]").forEach(function (btn) {
    btn.addEventListener("click", function () {
      current = Number(btn.getAttribute("data-webconsole-frame-index"));
      renderFrames();
      renderSource();
      renderVars();
    });
  });

  qa("[data-webconsole-filter]").forEach(function (btn) {
    btn.addEventListener("click", function () {
      setFilter(btn.getAttribute("data-webconsole-filter") === "app");
    });
  });

  ["locals", "ivars", "console"].forEach(function (name) {
    var button = tab(name);
    if (!button) { return; }
    button.addEventListener("click", function () {
      activeTab = name;
      renderVars();
    });
  });

  var disclosureToggle = q("[data-webconsole-disclosure-toggle]");
  if (disclosureToggle && workbench) {
    disclosureToggle.addEventListener("click", function () {
      var open = disclosureToggle.getAttribute("aria-expanded") === "true";
      disclosureToggle.setAttribute("aria-expanded", open ? "false" : "true");
      var label = q("[data-webconsole-disclosure-label]");
      if (label) { label.textContent = open ? "Show backtrace" : "Hide backtrace"; }
      workbench.hidden = open;
    });
  }

  qa("[data-webconsole-copy]").forEach(function (btn) {
    var label = btn.querySelector(".label");
    var restore = label ? label.textContent : btn.textContent;
    btn.addEventListener("click", function () {
      var kind = btn.getAttribute("data-webconsole-copy");
      var text = "";
      if (kind === "text") {
        text = DATA.text || "";
      } else {
        // Scoped to this button's own card: with a card per resolution there can be several
        // commands and snippets on the page, and copying a neighbour's would be silent.
        var scope = (btn.closest && btn.closest("[data-webconsole-fix]")) || document;
        var target = scope.querySelector("[data-webconsole-" + kind + "]");
        text = target ? target.textContent : "";
      }
      copyText(text, btn, restore);
    });
  });

  if (context) { qa("[data-webconsole-context-panel]", context).forEach(wireSearch); }

  // "/" focuses the first searchable panel, the way a dev tool should behave.
  document.addEventListener("keydown", function (event) {
    if (event.key !== "/" || event.metaKey || event.ctrlKey || event.altKey) { return; }
    var tag = (event.target.tagName || "").toLowerCase();
    if (tag === "input" || tag === "textarea") { return; }
    var first = q("[data-webconsole-search]");
    if (first) { event.preventDefault(); first.focus(); first.select(); }
  });

  qa("[data-webconsole-snippet]").forEach(function (snippet) {
    snippet.innerHTML = snippet.textContent.split("\n").map(highlight).join("\n");
  });

  /* ── resolutions ───────────────────────────────────────── */
  function resolutionOutput(index, text, ok) {
    var out = q('[data-webconsole-resolution-output="' + index + '"]');
    if (!out) { return; }

    out.textContent = "";
    var box = el("div", ok ? "run-done" : "repl-expired");
    box.appendChild(el("span", ok ? "run-status is-ok" : "", text));
    if (ok) {
      var reload = el("button", "btn-ghost", "Reload this page");
      reload.type = "button";
      reload.setAttribute("data-webconsole-reload", "");
      reload.addEventListener("click", function () { window.location.reload(); });
      box.appendChild(reload);
    }
    out.appendChild(box);
  }

  function runResolution(button, index, label, original) {
    button.disabled = true;
    if (label) { label.textContent = "Running…"; }

    if (!DATA.resolvePath || !window.fetch) {
      resolutionOutput(index, "This browser cannot run resolutions.", false);
      button.disabled = false;
      if (label) { label.textContent = original; }
      return;
    }

    window.fetch(DATA.resolvePath, {
      method: "POST",
      credentials: "same-origin",
      headers: {"Content-Type": "application/json", "Accept": "application/json"},
      body: JSON.stringify({csrfToken: csrfToken(), index: index})
    }).then(function (response) {
      if (response.status === 410) { return {expired: true}; }
      return response.json();
    }).then(function (result) {
      if (result.expired) {
        resolutionOutput(index, "This page is from before a reload. Refresh and try again.", false);
        return;
      }
      var detail = result.output && result.output.length ? " — " + result.output : "";
      var name = result.name || "The resolution";
      resolutionOutput(index, (result.ok ? name + " finished." : name + " failed.") + detail, !!result.ok);
    }).catch(function (error) {
      resolutionOutput(index, "Could not reach the server: " + error, false);
    }).then(function () {
      button.disabled = false;
      if (label) { label.textContent = original; }
    });
  }

  /* Destructive resolutions confirm inline rather than through a modal: this page appears by
     itself when something breaks, and a one-click rollback is too easy to hit by accident. */
  qa("[data-webconsole-resolution]").forEach(function (button) {
    var index = Number(button.getAttribute("data-webconsole-resolution"));
    var destructive = button.getAttribute("data-webconsole-resolution-destructive") === "true";
    var label = button.querySelector(".label");
    var original = label ? label.textContent : "";
    var armed = false;
    var timer = null;

    button.addEventListener("click", function () {
      if (destructive && !armed) {
        armed = true;
        if (label) { label.textContent = "This cannot be undone — click again"; }
        timer = window.setTimeout(function () {
          armed = false;
          if (label) { label.textContent = original; }
        }, 4000);
        return;
      }

      armed = false;
      if (timer) { window.clearTimeout(timer); }
      if (label) { label.textContent = original; }
      runResolution(button, index, label, original);
    });
  });

  setFilter(frames.some(function (f) { return f.kind === "app"; }));
  renderSource();
  renderVars();
}());
