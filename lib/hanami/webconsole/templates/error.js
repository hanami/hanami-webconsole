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
  var varsLoad = {}; // frame index → {loading: true} or {error: "..."} while a frame's variables aren't loaded

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
  var showAllFrames = q("[data-webconsole-show-all-frames]");
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
  }

  function setFilter(appOnly) {
    if (frameList) { frameList.classList.toggle("app-only", appOnly); }
    if (showAllFrames) { showAllFrames.checked = !appOnly; }
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

  function reloadButton() {
    var reload = el("button", "btn-ghost", "Refresh the page");
    reload.type = "button";
    reload.setAttribute("data-webconsole-reload", "");
    reload.addEventListener("click", function () { window.location.reload(); });
    return reload;
  }

  function emptyPanel(node) {
    varsPanel.textContent = "";
    varsPanel.appendChild(node);
  }

  function bindingsMissing() {
    var p = el("p", "empty");
    p.setAttribute("data-webconsole-no-bindings", "");
    /* binding_of_caller is a dependency, so it is installed. Bindings are only missing when it
       can't capture them on this Ruby (see Webconsole.probe_bindings). */
    p.appendChild(document.createTextNode("Variables and the console aren't available on this Ruby."));
    p.appendChild(document.createElement("br"));
    p.appendChild(document.createTextNode("They rely on the binding_of_caller gem, which can't capture bindings here."));
    return p;
  }

  /* Loads a frame's variables from the server, once. The page includes them only for the initial
     frame, since inspecting them can be slow, and most frames are never looked at. A failed load
     is not retried: its message stays until the page is refreshed. */
  function loadVars(index) {
    if (varsLoad[index]) { return; }
    if (!DATA.variablesPath || !window.fetch) {
      varsLoad[index] = {error: "Variables can't be loaded in this browser."};
      return;
    }

    varsLoad[index] = {loading: true};
    window.fetch(DATA.variablesPath, {
      method: "POST",
      credentials: "same-origin",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({csrfToken: csrfToken(), index: index})
    }).then(function (response) {
      if (response.status === 410) {
        expired = true;
        delete varsLoad[index];
        return;
      }
      return response.json().then(function (body) {
        if (!response.ok) { throw {explanation: body.explanation}; }
        frames[index].locals = body.locals || [];
        frames[index].ivars = body.ivars || [];
        delete varsLoad[index];
      });
    }).catch(function (error) {
      varsLoad[index] = {
        error: (error && error.explanation) || "The variables for this frame could not be loaded."
      };
    }).then(function () {
      if (index === current) { renderVars(); }
    });
  }

  function renderVars() {
    if (!varsPanel) { return; }
    var f = frames[current] || {locals: [], ivars: []};
    var available = !!(DATA.bindingsAvailable && f.binding);
    var loaded = f.locals !== undefined;
    if (available && !loaded && !expired) { loadVars(current); }

    var state = varsLoad[current] || {};
    var locals = available && loaded ? f.locals : [];
    var ivars = available && loaded ? f.ivars : [];
    var logged = (replLog[current] || []).length;

    function count(rows) {
      if (!available) { return "—"; }
      if (loaded) { return rows.length; }
      return state.loading ? "…" : "—";
    }

    if (tabCount("locals")) { tabCount("locals").textContent = count(locals); }
    if (tabCount("ivars")) { tabCount("ivars").textContent = count(ivars); }
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

    if (!loaded) {
      if (expired) {
        var gone = el("p", "empty", "This page's variables are gone, since the application reloaded. ");
        gone.appendChild(reloadButton());
        emptyPanel(gone);
      } else {
        emptyPanel(el("p", "empty", state.error || "Loading variables…"));
      }
      return;
    }

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
    return DATA.csrfToken || "";
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
      gone.appendChild(reloadButton());
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
      if (label) { label.textContent = msg; } else if (!use) { btn.textContent = msg; }
      if (use && ok) { use.setAttribute("href", "#i-check"); }
      window.setTimeout(function () {
        if (label) { label.textContent = restore; } else if (!use) { btn.textContent = restore; }
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

  // One filter for every panel. Each panel shows its own matches, and says when it has none.
  function wireContext() {
    var input = q("[data-webconsole-search]");
    var clear = q("[data-webconsole-search-clear]");
    var panels = qa("[data-webconsole-context-panel]").map(function (panel) {
      var count = q("[data-webconsole-context-count]", panel);
      return {
        panel: panel,
        empty: q("[data-webconsole-context-empty]", panel),
        count: count,
        total: count ? count.textContent : "",
        rows: qa("[data-webconsole-row]", panel).map(function (row) {
          var cells = qa("[data-webconsole-cell]", row).map(function (cell) {
            return {cell: cell, text: cell.textContent};
          });
          return {
            row: row,
            cells: cells,
            text: cells.map(function (entry) { return entry.text; }).join(" ").toLowerCase()
          };
        })
      };
    });

    function apply() {
      var needle = input ? input.value.trim().toLowerCase() : "";
      panels.forEach(function (entry) {
        var matched = 0;
        entry.rows.forEach(function (row) {
          var hit = !needle || row.text.indexOf(needle) !== -1;
          row.row.hidden = !hit;
          if (hit) { matched += 1; }
          row.cells.forEach(function (cell) {
            cell.cell.innerHTML = mark(cell.text, needle);
            // A match past the third line would be clamped out of sight, so open the value.
            if (cell.cell.classList.contains("clamp")) {
              cell.cell.classList.toggle("is-open", !!needle && cell.text.toLowerCase().indexOf(needle) !== -1);
            }
          });
        });
        if (entry.empty) { entry.empty.hidden = matched !== 0; }
        if (entry.count) { entry.count.textContent = needle ? matched + "/" + entry.total : entry.total; }
      });
      if (clear) { clear.hidden = !needle; }
      markClamped();
    }

    if (input) {
      input.addEventListener("input", apply);
      input.addEventListener("keydown", function (event) {
        if (event.key === "Escape") { input.value = ""; apply(); input.blur(); }
      });
    }
    if (clear) {
      clear.addEventListener("click", function () {
        input.value = "";
        apply();
        input.focus();
      });
    }
  }

  // Values clamp to three lines. Only a value that overflows is marked, so only it reacts to a
  // click. The full value is always in the page, for copying and filtering.
  function markClamped() {
    qa(".clamp").forEach(function (cell) {
      var open = cell.classList.contains("is-open");
      cell.classList.add("is-measuring");
      cell.classList.remove("is-open");
      var overflows = cell.scrollHeight > cell.clientHeight + 1;
      cell.classList.remove("is-measuring");
      cell.classList.toggle("is-open", open);
      cell.classList.toggle("is-clamped", overflows);
    });
  }

  function wirePanelToggles() {
    var KEY = "hanami-webconsole:hidden-panels";
    var hidden = [];
    try { hidden = JSON.parse(window.localStorage.getItem(KEY) || "[]"); } catch (e) { hidden = []; }
    if (!Array.isArray(hidden)) { hidden = []; }

    qa("[data-webconsole-panel-toggle]").forEach(function (toggle) {
      var title = toggle.getAttribute("data-webconsole-panel-toggle");
      var panel = q('[data-webconsole-context-panel="' + title.replace(/"/g, '\\"') + '"]');
      if (!panel) { return; }

      function show(visible) {
        toggle.checked = visible;
        panel.hidden = !visible;
      }

      show(hidden.indexOf(title) === -1);
      toggle.addEventListener("change", function () {
        show(toggle.checked);
        hidden = hidden.filter(function (name) { return name !== title; });
        if (!toggle.checked) { hidden.push(title); }
        try { window.localStorage.setItem(KEY, JSON.stringify(hidden)); } catch (e) { /* storage off */ }
        markClamped();
      });
    });
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

  if (showAllFrames) {
    showAllFrames.addEventListener("change", function () { setFilter(!showAllFrames.checked); });
  }

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
        // Scoped to this button's own block: a diagnostic's text can hold several commands and
        // snippets, and copying a neighbour's would be silent.
        var scope = (btn.closest && btn.closest(".cmd, .snippet-wrap")) || document;
        var target = scope.querySelector("[data-webconsole-" + kind + "]");
        text = target ? target.textContent : "";
      }
      copyText(text, btn, restore);
    });
  });

  if (context) {
    wireContext();
    wirePanelToggles();
    markClamped();

    context.addEventListener("click", function (event) {
      var copy = event.target.closest && event.target.closest("[data-webconsole-copy-cell]");
      if (copy) {
        var value = copy.parentNode.querySelector("[data-webconsole-cell]");
        copyText(value ? value.textContent : "", copy, "");
        return;
      }
      // Clicking a clamped value opens or closes it, unless the click ends a text selection.
      var cell = event.target.closest && event.target.closest(".clamp.is-clamped, .clamp.is-open");
      if (cell && !String(window.getSelection && window.getSelection()).length) {
        cell.classList.toggle("is-open");
      }
    });
  }

  // "/" focuses the filter, the way a dev tool should behave.
  document.addEventListener("keydown", function (event) {
    if (event.key !== "/" || event.metaKey || event.ctrlKey || event.altKey) { return; }
    var tag = (event.target.tagName || "").toLowerCase();
    if (tag === "input" || tag === "textarea") { return; }
    var first = q("[data-webconsole-search]");
    if (first) { event.preventDefault(); first.focus(); first.select(); }
  });

  // Only Ruby gets Ruby highlighting. Other code (e.g. a fenced block with no language) stays plain.
  qa("[data-webconsole-snippet][data-webconsole-highlight]").forEach(function (snippet) {
    snippet.innerHTML = snippet.textContent.split("\n").map(highlight).join("\n");
  });

  /* ── running the fix ───────────────────────────────────── */
  /* One click runs the fix: fixes are meant to be safe to run, and safe to run twice. */
  var runButton = q("[data-webconsole-run]");
  var runOutput = q("[data-webconsole-run-output]");

  function showRunResult(status, ok, output) {
    if (!runOutput) { return; }

    runOutput.textContent = "";
    var box = el("div", ok ? "run-done" : "repl-expired");
    box.appendChild(el("span", ok ? "run-status is-ok" : "run-status", status));
    if (ok && DATA.retryable) {
      var retry = el("button", "btn-ghost", "Retry request");
      retry.type = "button";
      retry.setAttribute("data-webconsole-retry", "");
      retry.addEventListener("click", function () { window.location.reload(); });
      box.appendChild(retry);
    } else if (ok) {
      // Reloading a non-GET request would ask to resubmit it, or repeat an action without asking.
      box.appendChild(el("span", "fix-note", "Go back and submit the form again."));
    }
    runOutput.appendChild(box);
    if (output) { runOutput.appendChild(el("div", "run-output", output)); }
  }

  function runFailure(status, body) {
    if (status === 410) {
      return "The fix didn't run: this page is from before a code reload. Reload the page, then try again.";
    }
    if (status === 409) {
      return "The fix didn't run: another fix is still running. Try again when it finishes.";
    }
    var reason = (body && (body.explanation || body.error)) || "the server responded " + status;
    return "The fix didn't run: " + reason.replace(/\.$/, "") + ".";
  }

  function runFix() {
    var label = runButton.querySelector(".label");
    var original = label ? label.textContent : "";

    function finish() {
      runButton.disabled = false;
      if (label) { label.textContent = original; }
    }

    runButton.disabled = true;
    if (label) { label.textContent = "Running…"; }

    if (!DATA.runPath || !window.fetch) {
      showRunResult("This browser can't run fixes from the page. Do it yourself, below.", false);
      finish();
      return;
    }

    window.fetch(DATA.runPath, {
      method: "POST",
      credentials: "same-origin",
      headers: {"Content-Type": "application/json", "Accept": "application/json"},
      body: JSON.stringify({csrfToken: csrfToken()})
    }).then(function (response) {
      return response.json().then(
        function (body) { return {status: response.status, body: body}; },
        function () { return {status: response.status, body: null}; }
      );
    }).then(function (result) {
      var body = result.body || {};
      if (result.status !== 200) {
        showRunResult(runFailure(result.status, result.body), false);
        return;
      }
      var name = body.name || "The fix";
      showRunResult(body.ok ? name + " finished." : name + " failed.", !!body.ok, body.output);
    }).catch(function (error) {
      showRunResult("Could not reach the server: " + error, false);
    }).then(finish);
  }

  // A destructive fix needs a second click. The first click asks for confirmation, and the button
  // goes back to normal after a few seconds.
  var CONFIRM_MS = 5000;
  var confirmTimer = null;

  function cancelConfirm() {
    clearTimeout(confirmTimer);
    confirmTimer = null;
    var label = runButton.querySelector(".label");
    if (label && runButton.dataset.label) { label.textContent = runButton.dataset.label; }
    delete runButton.dataset.label;
  }

  function onRunClick() {
    if (!runButton.hasAttribute("data-destructive")) { return runFix(); }

    if (confirmTimer) {
      cancelConfirm();
      return runFix();
    }

    var label = runButton.querySelector(".label");
    if (label) {
      runButton.dataset.label = label.textContent;
      label.textContent = "Click again to confirm: " + label.textContent;
    }
    confirmTimer = setTimeout(cancelConfirm, CONFIRM_MS);
  }

  if (runButton) { runButton.addEventListener("click", onRunClick); }

  setFilter(frames.some(function (f) { return f.kind === "app"; }));
  renderSource();
  renderVars();
}());
