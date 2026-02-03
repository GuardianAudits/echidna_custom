{-# LANGUAGE OverloadedStrings #-}

module Echidna.MCP.UI (mcpDashboardHtml) where

import Data.ByteString.Lazy (ByteString)

mcpDashboardHtml :: ByteString
mcpDashboardHtml = "<!doctype html>\n\
\<html lang=\"en\">\n\
\<head>\n\
\  <meta charset=\"utf-8\" />\n\
\  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />\n\
\  <title>Echidna MCP Dashboard</title>\n\
\  <style>\n\
\    :root {\n\
\      --bg: #0b0f14;\n\
\      --panel: #111824;\n\
\      --panel-2: #0f1420;\n\
\      --text: #e6edf6;\n\
\      --muted: #9aa8b6;\n\
\      --accent: #5eead4;\n\
\      --accent-2: #f97316;\n\
\      --danger: #ef4444;\n\
\      --good: #22c55e;\n\
\      --warn: #facc15;\n\
\      --grid: rgba(255,255,255,0.05);\n\
\    }\n\
\    * { box-sizing: border-box; }\n\
\    body {\n\
\      margin: 0;\n\
\      background: radial-gradient(1200px 600px at 10% -10%, rgba(94,234,212,0.15), transparent 70%),\n\
\                  radial-gradient(1000px 600px at 110% 0%, rgba(249,115,22,0.18), transparent 65%),\n\
\                  var(--bg);\n\
\      color: var(--text);\n\
\      font-family: \"Space Grotesk\", \"IBM Plex Sans\", \"Trebuchet MS\", sans-serif;\n\
\    }\n\
\    header {\n\
\      position: sticky;\n\
\      top: 0;\n\
\      z-index: 10;\n\
\      background: linear-gradient(180deg, rgba(11,15,20,0.95), rgba(11,15,20,0.75));\n\
\      border-bottom: 1px solid var(--grid);\n\
\      backdrop-filter: blur(10px);\n\
\    }\n\
\    .wrap { max-width: 1400px; margin: 0 auto; padding: 20px 24px; }\n\
\    .title {\n\
\      display: flex;\n\
\      align-items: center;\n\
\      justify-content: space-between;\n\
\      gap: 16px;\n\
\    }\n\
\    .title h1 { margin: 0; font-size: 24px; letter-spacing: 0.5px; }\n\
\    .badge {\n\
\      padding: 6px 10px;\n\
\      border-radius: 999px;\n\
\      border: 1px solid var(--grid);\n\
\      color: var(--muted);\n\
\      font-size: 12px;\n\
\    }\n\
\    .controls { display: flex; gap: 8px; flex-wrap: wrap; }\n\
\    .btn {\n\
\      background: var(--panel);\n\
\      border: 1px solid var(--grid);\n\
\      color: var(--text);\n\
\      padding: 8px 12px;\n\
\      border-radius: 10px;\n\
\      font-size: 13px;\n\
\      cursor: pointer;\n\
\      transition: transform 0.08s ease, border-color 0.2s ease;\n\
\    }\n\
\    .btn:hover { transform: translateY(-1px); border-color: rgba(94,234,212,0.4); }\n\
\    .btn.danger { border-color: rgba(239,68,68,0.4); color: #fecaca; }\n\
\    .btn.good { border-color: rgba(34,197,94,0.4); color: #bbf7d0; }\n\
\    .layout {\n\
\      display: grid;\n\
\      grid-template-columns: repeat(12, 1fr);\n\
\      gap: 16px;\n\
\      padding: 20px 24px 60px;\n\
\    }\n\
\    .card {\n\
\      background: linear-gradient(180deg, rgba(17,24,36,0.85), rgba(15,20,32,0.85));\n\
\      border: 1px solid var(--grid);\n\
\      border-radius: 14px;\n\
\      padding: 16px;\n\
\      box-shadow: 0 10px 30px rgba(0,0,0,0.25);\n\
\    }\n\
\    .card h2 { margin: 0 0 10px; font-size: 16px; }\n\
\    .grid { display: grid; gap: 10px; }\n\
\    .kpis { display: grid; grid-template-columns: repeat(auto-fit,minmax(160px,1fr)); gap: 10px; }\n\
\    .kpi {\n\
\      background: var(--panel-2);\n\
\      border: 1px solid var(--grid);\n\
\      border-radius: 12px;\n\
\      padding: 12px;\n\
\    }\n\
\    .kpi .label { font-size: 11px; color: var(--muted); letter-spacing: 0.6px; }\n\
\    .kpi .value { font-size: 20px; margin-top: 4px; }\n\
\    .table {\n\
\      width: 100%;\n\
\      border-collapse: collapse;\n\
\      font-size: 12px;\n\
\    }\n\
\    .table th, .table td {\n\
\      border-bottom: 1px solid var(--grid);\n\
\      padding: 6px 8px;\n\
\      text-align: left;\n\
\      vertical-align: top;\n\
\    }\n\
\    .muted { color: var(--muted); }\n\
\    .pill {\n\
\      display: inline-block;\n\
\      padding: 2px 8px;\n\
\      border-radius: 999px;\n\
\      background: rgba(94,234,212,0.1);\n\
\      border: 1px solid rgba(94,234,212,0.25);\n\
\      color: #b5fff3;\n\
\      font-size: 11px;\n\
\    }\n\
\    .pill.warn { background: rgba(250,204,21,0.1); border-color: rgba(250,204,21,0.3); color: #fef08a; }\n\
\    .pill.bad { background: rgba(239,68,68,0.1); border-color: rgba(239,68,68,0.3); color: #fecaca; }\n\
\    .split { display: grid; grid-template-columns: 2fr 1fr; gap: 12px; }\n\
\    pre {\n\
\      background: #0c121b;\n\
\      border: 1px solid var(--grid);\n\
\      padding: 12px;\n\
\      border-radius: 10px;\n\
\      overflow: auto;\n\
\      max-height: 320px;\n\
\    }\n\
\    .search { width: 100%; background: #0c121b; border: 1px solid var(--grid); border-radius: 10px; padding: 8px; color: var(--text); }\n\
\    .select { width: 100%; background: #0c121b; border: 1px solid var(--grid); border-radius: 10px; padding: 8px; color: var(--text); }\n\
\    .section-title { display:flex; align-items:center; justify-content:space-between; gap:10px; }\n\
\    .status-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--warn); display:inline-block; margin-right:6px; }\n\
\    .status-good { background: var(--good); }\n\
\    .status-bad { background: var(--danger); }\n\
\    .small { font-size: 11px; }\n\
\    @media (max-width: 1100px) {\n\
\      .layout { grid-template-columns: repeat(6, 1fr); }\n\
\      .split { grid-template-columns: 1fr; }\n\
\    }\n\
\  </style>\n\
\</head>\n\
\<body>\n\
\  <header>\n\
\    <div class=\"wrap\">\n\
\      <div class=\"title\">\n\
\        <div>\n\
\          <h1>Echidna MCP Dashboard</h1>\n\
\          <div class=\"muted small\">Live view of fuzzing activity, coverage, and reverts.</div>\n\
\        </div>\n\
\        <div class=\"controls\">\n\
\          <button class=\"btn\" id=\"refreshBtn\">Refresh now</button>\n\
\          <button class=\"btn good\" id=\"resumeBtn\">Resume</button>\n\
\          <button class=\"btn\" id=\"pauseBtn\">Pause</button>\n\
\          <button class=\"btn danger\" id=\"stopBtn\">Stop</button>\n\
\        </div>\n\
\      </div>\n\
\      <div class=\"title\" style=\"margin-top:12px;\">\n\
\        <div class=\"badge\" id=\"connBadge\">Connecting…</div>\n\
\        <div class=\"controls\">\n\
\          <label class=\"badge\">Auto refresh <input type=\"checkbox\" id=\"autoRefresh\" checked></label>\n\
\          <label class=\"badge\">Interval <input type=\"number\" id=\"interval\" value=\"3\" min=\"1\" max=\"30\" style=\"width:48px\"></label>\n\
\        </div>\n\
\      </div>\n\
\    </div>\n\
\  </header>\n\
\  <div class=\"layout\">\n\
\    <section class=\"card\" style=\"grid-column: span 12;\">\n\
\      <div class=\"section-title\">\n\
\        <h2>Run Status</h2>\n\
\        <span class=\"badge\" id=\"phaseBadge\">phase: unknown</span>\n\
\      </div>\n\
\      <div class=\"kpis\" id=\"kpis\"></div>\n\
\    </section>\n\
\    <section class=\"card\" style=\"grid-column: span 7;\">\n\
\      <div class=\"section-title\">\n\
\        <h2>Handlers (All calls)</h2>\n\
\        <input class=\"search\" id=\"handlerSearch\" placeholder=\"Filter handlers…\" />\n\
\      </div>\n\
\      <div style=\"max-height:360px; overflow:auto;\">\n\
\        <table class=\"table\" id=\"handlersTable\"></table>\n\
\      </div>\n\
\    </section>\n\
\    <section class=\"card\" style=\"grid-column: span 5;\">\n\
\      <div class=\"section-title\">\n\
\        <h2>Cheatcode Stats</h2>\n\
\      </div>\n\
\      <div style=\"max-height:360px; overflow:auto;\">\n\
\        <table class=\"table\" id=\"cheatTable\"></table>\n\
\      </div>\n\
\    </section>\n\
\    <section class=\"card\" style=\"grid-column: span 7;\">\n\
\      <div class=\"section-title\">\n\
\        <h2>Logical Coverage</h2>\n\
\        <input class=\"search\" id=\"logicalSearch\" placeholder=\"Filter methods…\" />\n\
\      </div>\n\
\      <div style=\"max-height:360px; overflow:auto;\">\n\
\        <table class=\"table\" id=\"logicalTable\"></table>\n\
\      </div>\n\
\    </section>\n\
\    <section class=\"card\" style=\"grid-column: span 5;\">\n\
\      <div class=\"section-title\">\n\
\        <h2>Coverage Summary</h2>\n\
\      </div>\n\
\      <div id=\"coverageSummary\" class=\"grid\"></div>\n\
\      <div style=\"margin-top:12px;\" class=\"section-title\">\n\
\        <h2>Coverage Hits</h2>\n\
\      </div>\n\
\      <select class=\"select\" id=\"coverageFile\"></select>\n\
\      <label class=\"badge\" style=\"margin-top:6px; display:inline-block;\">Only hits &gt; 0 <input type=\"checkbox\" id=\"hitsOnly\" checked></label>\n\
\      <div style=\"max-height:260px; overflow:auto; margin-top:8px;\">\n\
\        <table class=\"table\" id=\"coverageTable\"></table>\n\
\      </div>\n\
\    </section>\n\
\    <section class=\"card\" style=\"grid-column: span 12;\">\n\
\      <div class=\"split\">\n\
\        <div>\n\
\          <div class=\"section-title\">\n\
\            <h2>Reverts</h2>\n\
\            <span class=\"badge\" id=\"revertCount\">0</span>\n\
\          </div>\n\
\          <div style=\"max-height:320px; overflow:auto;\">\n\
\            <table class=\"table\" id=\"revertTable\"></table>\n\
\          </div>\n\
\        </div>\n\
\        <div>\n\
\          <div class=\"section-title\">\n\
\            <h2>Trace</h2>\n\
\            <span class=\"badge\" id=\"traceBadge\">no trace selected</span>\n\
\          </div>\n\
\          <pre id=\"traceView\">Select a revert to view its trace.</pre>\n\
\        </div>\n\
\      </div>\n\
\    </section>\n\
\    <section class=\"card\" style=\"grid-column: span 12;\">\n\
\      <div class=\"section-title\">\n\
\        <h2>Events Stream</h2>\n\
\        <span class=\"badge\" id=\"eventCount\">0</span>\n\
\      </div>\n\
\      <div style=\"max-height:300px; overflow:auto;\">\n\
\        <table class=\"table\" id=\"eventsTable\"></table>\n\
\      </div>\n\
\    </section>\n\
\  </div>\n\
\  <script>\n\
\    const API = '/mcp';\n\
\    let lastEventId = 0;\n\
\    let lastRevertId = 0;\n\
\    let lastTraceId = 0;\n\
\    let traceById = new Map();\n\
\    let coverageLines = null;\n\
\    const qs = (s) => document.querySelector(s);\n\
\    async function mcp(method, params) {\n\
\      const body = JSON.stringify({ jsonrpc: '2.0', id: Date.now(), method, params });\n\
\      const res = await fetch(API, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body });\n\
\      const json = await res.json();\n\
\      if (json.error) throw new Error(json.error.message || 'MCP error');\n\
\      return json.result;\n\
\    }\n\
\    async function readResource(uri) {\n\
\      const result = await mcp('resources/read', { uri });\n\
\      const text = result?.contents?.[0]?.text;\n\
\      if (!text) return {};\n\
\      try { return JSON.parse(text); } catch { return {}; }\n\
\    }\n\
\    async function callTool(name, args = {}) {\n\
\      return mcp('tools/call', { name, arguments: args });\n\
\    }\n\
\    function setConn(ok, msg) {\n\
\      const badge = qs('#connBadge');\n\
\      badge.textContent = msg;\n\
\      badge.style.borderColor = ok ? 'rgba(34,197,94,0.4)' : 'rgba(239,68,68,0.4)';\n\
\    }\n\
\    function renderKpis(status) {\n\
\      const kpis = qs('#kpis');\n\
\      const c = status.counters || {};\n\
\      const successRate = c.totalCalls ? ((c.successCalls / c.totalCalls) * 100).toFixed(1) : '0.0';\n\
\      kpis.innerHTML = [\n\
\        ['Phase', status.phase || 'unknown'],\n\
\        ['Total Calls', c.totalCalls ?? 0],\n\
\        ['Success', c.successCalls ?? 0],\n\
\        ['Failures', c.failedCalls ?? 0],\n\
\        ['Success Rate', successRate + '%'],\n\
\        ['Coverage Points', status.coveragePoints ?? 0],\n\
\        ['Unique Codehashes', status.uniqueCodehashes ?? 0],\n\
\        ['Corpus Size', status.corpusSize ?? 0],\n\
\      ].map(([label, value]) => `\n\
\        <div class=\"kpi\">\n\
\          <div class=\"label\">${label}</div>\n\
\          <div class=\"value\">${value}</div>\n\
\        </div>\n\
\      `).join('');\n\
\      qs('#phaseBadge').textContent = `phase: ${status.phase || 'unknown'}`;\n\
\    }\n\
\    function renderHandlers(handlers) {\n\
\      const search = qs('#handlerSearch').value.toLowerCase();\n\
\      const rows = Object.entries(handlers || {})\n\
\        .filter(([name]) => name.toLowerCase().includes(search))\n\
\        .sort((a,b) => (b[1].totalCalls||0) - (a[1].totalCalls||0))\n\
\        .map(([name, st]) => `\n\
\          <tr>\n\
\            <td><span class=\"pill\">${name}</span></td>\n\
\            <td>${st.totalCalls || 0}</td>\n\
\            <td>${st.successCalls || 0}</td>\n\
\            <td>${st.failedCalls || 0}</td>\n\
\            <td class=\"muted\">${(st.lastArgs || []).join(', ')}</td>\n\
\            <td class=\"muted\">${st.lastSeen || ''}</td>\n\
\          </tr>\n\
\        `).join('');\n\
\      qs('#handlersTable').innerHTML = `\n\
\        <tr><th>Handler</th><th>Total</th><th>Success</th><th>Failed</th><th>Last Args</th><th>Last Seen</th></tr>\n\
\        ${rows || '<tr><td colspan=\"6\" class=\"muted\">No handlers recorded yet.</td></tr>'}\n\
\      `;\n\
\    }\n\
\    function renderCheatStats(stats) {\n\
\      const rows = (stats || [])\n\
\        .sort((a,b) => (b.totalCalls||0) - (a.totalCalls||0))\n\
\        .map(st => `\n\
\          <tr>\n\
\            <td><span class=\"pill\">${st.selector}</span></td>\n\
\            <td>${st.totalCalls || 0}</td>\n\
\            <td>${st.successCalls || 0}</td>\n\
\            <td>${st.failedCalls || 0}</td>\n\
\          </tr>\n\
\        `).join('');\n\
\      qs('#cheatTable').innerHTML = `\n\
\        <tr><th>Selector</th><th>Total</th><th>Success</th><th>Failed</th></tr>\n\
\        ${rows || '<tr><td colspan=\"4\" class=\"muted\">No cheatcode stats yet.</td></tr>'}\n\
\      `;\n\
\    }\n\
\    function renderLogicalCoverage(coverage) {\n\
\      const methods = coverage.methods || {};\n\
\      const search = qs('#logicalSearch').value.toLowerCase();\n\
\      const rows = Object.entries(methods)\n\
\        .filter(([name]) => name.toLowerCase().includes(search))\n\
\        .sort((a,b) => (b[1].totalCalls||0) - (a[1].totalCalls||0))\n\
\        .map(([name, st]) => {\n\
\          const total = st.totalCalls || 0;\n\
\          const ok = st.successCalls || 0;\n\
\          const pct = total ? ((ok/total)*100).toFixed(1) : '0.0';\n\
\          const reasons = st.revertReasons ? Object.entries(st.revertReasons).map(([k,v]) => `${k} x${v}`).join(', ') : '';\n\
\          return `\n\
\            <tr>\n\
\              <td><span class=\"pill\">${name}</span></td>\n\
\              <td>${ok}/${total} (${pct}%)</td>\n\
\              <td class=\"muted\">${reasons || '—'}</td>\n\
\            </tr>\n\
\          `;\n\
\        }).join('');\n\
\      qs('#logicalTable').innerHTML = `\n\
\        <tr><th>Method</th><th>Success</th><th>Revert Reasons</th></tr>\n\
\        ${rows || '<tr><td colspan=\"3\" class=\"muted\">No logical coverage yet.</td></tr>'}\n\
\      `;\n\
\    }\n\
\    function renderCoverageSummary(summary) {\n\
\      qs('#coverageSummary').innerHTML = `\n\
\        <div class=\"kpi\"><div class=\"label\">Coverage Points</div><div class=\"value\">${summary.points ?? 0}</div></div>\n\
\        <div class=\"kpi\"><div class=\"label\">Unique Codehashes</div><div class=\"value\">${summary.uniqueCodehashes ?? 0}</div></div>\n\
\      `;\n\
\    }\n\
\    function renderCoverageLines() {\n\
\      if (!coverageLines) return;\n\
\      const fileSelect = qs('#coverageFile');\n\
\      const file = fileSelect.value;\n\
\      const hitsOnly = qs('#hitsOnly').checked;\n\
\      const lines = coverageLines[file] || {};\n\
\      const rows = Object.entries(lines)\n\
\        .filter(([,hits]) => !hitsOnly || Number(hits) > 0)\n\
\        .sort((a,b) => Number(a[0]) - Number(b[0]))\n\
\        .slice(0, 500)\n\
\        .map(([line,hits]) => `\n\
\          <tr><td>${line}</td><td>${hits}</td></tr>\n\
\        `).join('');\n\
\      qs('#coverageTable').innerHTML = `\n\
\        <tr><th>Line</th><th>Hits</th></tr>\n\
\        ${rows || '<tr><td colspan=\"2\" class=\"muted\">No lines to show.</td></tr>'}\n\
\      `;\n\
\    }\n\
\    function renderEvents(events) {\n\
\      const rows = (events || []).map(ev => `\n\
\        <tr>\n\
\          <td>${ev.ts || ''}</td>\n\
\          <td>${ev.type || ''}</td>\n\
\          <td class=\"muted\">${JSON.stringify(ev.payload || {})}</td>\n\
\        </tr>\n\
\      `).join('');\n\
\      qs('#eventsTable').insertAdjacentHTML('afterbegin', rows);\n\
\      qs('#eventCount').textContent = String(Number(qs('#eventCount').textContent || 0) + (events || []).length);\n\
\    }\n\
\    function renderReverts(reverts) {\n\
\      const rows = (reverts || []).map(rv => {\n\
\        const trace = rv.traceId != null ? `<button class=\"btn\" data-trace=\"${rv.traceId}\">Trace</button>` : '';\n\
\        return `\n\
\          <tr>\n\
\            <td>${rv.ts || ''}</td>\n\
\            <td><span class=\"pill bad\">${rv.reason || ''}</span></td>\n\
\            <td class=\"muted\">${rv.selector || ''}</td>\n\
\            <td class=\"muted\">${rv.contract || ''}</td>\n\
\            <td>${trace}</td>\n\
\          </tr>\n\
\        `;\n\
\      }).join('');\n\
\      qs('#revertTable').insertAdjacentHTML('afterbegin', rows);\n\
\      qs('#revertCount').textContent = String(Number(qs('#revertCount').textContent || 0) + (reverts || []).length);\n\
\    }\n\
\    function wireTraceButtons() {\n\
\      qs('#revertTable').addEventListener('click', (e) => {\n\
\        const btn = e.target.closest('button[data-trace]');\n\
\        if (!btn) return;\n\
\        const id = btn.getAttribute('data-trace');\n\
\        const trace = traceById.get(Number(id));\n\
\        qs('#traceView').textContent = trace?.trace || 'Trace not found.';\n\
\        qs('#traceBadge').textContent = `trace ${id}`;\n\
\      });\n\
\    }\n\
\    async function refreshStatic() {\n\
\      const [status, handlers, logical, coverageSummary, cheat] = await Promise.all([\n\
\        readResource('echidna://run/status'),\n\
\        readResource('echidna://run/handlers'),\n\
\        readResource('echidna://stats/logical-coverage'),\n\
\        readResource('echidna://coverage/summary'),\n\
\        readResource('echidna://stats/cheatcodes')\n\
\      ]);\n\
\      renderKpis(status);\n\
\      renderHandlers(handlers.handlers || {});\n\
\      renderLogicalCoverage(logical);\n\
\      renderCoverageSummary(coverageSummary);\n\
\      renderCheatStats(cheat.stats || []);\n\
\    }\n\
\    async function refreshCoverageLinesOnce() {\n\
\      if (coverageLines) return;\n\
\      const lines = await readResource('echidna://coverage/lines');\n\
\      coverageLines = lines || {};\n\
\      const fileSelect = qs('#coverageFile');\n\
\      fileSelect.innerHTML = Object.keys(coverageLines).map(f => `<option value=\"${f}\">${f}</option>`).join('');\n\
\      renderCoverageLines();\n\
\    }\n\
\    async function refreshStreams() {\n\
\      const events = await readResource(`echidna://run/events?since=${lastEventId}&limit=200`);\n\
\      if (events.events?.length) {\n\
\        lastEventId = Math.max(...events.events.map(e => e.id || 0), lastEventId);\n\
\        renderEvents(events.events);\n\
\      }\n\
\      const traces = await readResource(`echidna://run/traces?since=${lastTraceId}&limit=200`);\n\
\      if (traces.traces?.length) {\n\
\        lastTraceId = Math.max(...traces.traces.map(t => t.id || 0), lastTraceId);\n\
\        traces.traces.forEach(t => traceById.set(t.id, t));\n\
\      }\n\
\      const reverts = await readResource(`echidna://run/reverts?since=${lastRevertId}&limit=200`);\n\
\      if (reverts.reverts?.length) {\n\
\        lastRevertId = Math.max(...reverts.reverts.map(r => r.id || 0), lastRevertId);\n\
\        renderReverts(reverts.reverts);\n\
\      }\n\
\    }\n\
\    async function refreshAll() {\n\
\      try {\n\
\        await refreshStatic();\n\
\        await refreshCoverageLinesOnce();\n\
\        await refreshStreams();\n\
\        setConn(true, 'Connected');\n\
\      } catch (e) {\n\
\        setConn(false, 'Disconnected');\n\
\      }\n\
\    }\n\
\    let timer = null;\n\
\    function schedule() {\n\
\      if (timer) clearInterval(timer);\n\
\      if (!qs('#autoRefresh').checked) return;\n\
\      const sec = Math.max(1, Number(qs('#interval').value) || 3);\n\
\      timer = setInterval(refreshAll, sec * 1000);\n\
\    }\n\
\    qs('#refreshBtn').addEventListener('click', refreshAll);\n\
\    qs('#autoRefresh').addEventListener('change', schedule);\n\
\    qs('#interval').addEventListener('change', schedule);\n\
\    qs('#handlerSearch').addEventListener('input', refreshStatic);\n\
\    qs('#logicalSearch').addEventListener('input', refreshStatic);\n\
\    qs('#coverageFile').addEventListener('change', renderCoverageLines);\n\
\    qs('#hitsOnly').addEventListener('change', renderCoverageLines);\n\
\    qs('#pauseBtn').addEventListener('click', () => callTool('pause'));\n\
\    qs('#resumeBtn').addEventListener('click', () => callTool('resume'));\n\
\    qs('#stopBtn').addEventListener('click', () => callTool('stop'));\n\
\    wireTraceButtons();\n\
\    refreshAll();\n\
\    schedule();\n\
\  </script>\n\
\</body>\n\
\</html>\n"
