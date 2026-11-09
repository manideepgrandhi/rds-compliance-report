// Headless check of the v1.2.0 compliance exceptions in the combined HTML (report built with the tests' exceptions fixture).
// Usage: node browser_exceptions.js <report.html> [screenshot-dir] -> JSON {checks, fails}; exit 1 on any failure.
const p = require('puppeteer-core'); const path = require('path'), fs = require('fs');
const fails = []; let n = 0; const ok = (c, m) => { n++; if (!c) fails.push(m); };
const sleep = ms => new Promise(x => setTimeout(x, ms));
(async () => {
  const file = path.resolve(process.argv[2]), shots = process.argv[3];
  if (shots) fs.mkdirSync(shots, {recursive: true});
  const b = await p.launch({executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox']});
  const g = await b.newPage(); const errs = [];
  g.on('pageerror', e => errs.push(e.message)); g.on('console', m => m.type() === 'error' && errs.push(m.text()));
  g.on('dialog', d => { errs.push('dialog: ' + d.message()); d.dismiss(); });
  await g.setViewport({width: 1440, height: 1000});
  await g.goto('file://' + file, {waitUntil: 'load'});
  await g.evaluate(() => { window.__csv = []; const o = URL.createObjectURL; URL.createObjectURL = b => { b.arrayBuffer().then(a => window.__csv.push(new TextDecoder('utf-8', {ignoreBOM: true}).decode(a))); return o(b); }; });
  const sel = async (id, v) => { await g.select('#' + id, v); await sleep(50); };
  const st = () => g.evaluate(() => {
    const ths = [...document.querySelectorAll('#ts thead th')].map(t => t.textContent), xi = ths.indexOf('Exception');
    const rows = [...document.querySelectorAll('#ts tbody tr')].filter(r => r.children.length > 1);
    const pop = id => [...document.querySelectorAll('#' + id + ' .pop div')].map(d => d.textContent);
    return {ths, xi, rows: rows.length, ids: rows.map(r => r.children[0].textContent + ' ' + r.children[3].textContent),
      xcells: rows.map(r => xi >= 0 ? r.children[xi].textContent : ''), patch: document.querySelector('#c-patch .v').textContent,
      backup: document.querySelector('#c-backup .v').textContent, psub: (document.querySelector('#c-patch .xs') || {}).textContent || '',
      bsub: (document.querySelector('#c-backup .xs') || {}).textContent || '', ppop: pop('c-patch'), bpop: pop('c-backup'),
      badges: document.querySelectorAll('#ts .b.exc').length, note: (document.getElementById('exc-note') || {textContent: ''}).textContent,
      acc: [...document.querySelectorAll('#ta tbody tr')].map(t => t.textContent), cnt: document.getElementById('cnt').textContent}; });
  let s = await st();
  ok(errs.length === 0, 'no JS errors: ' + errs.join('; '));
  ok(s.xi === 7, 'Exception column last (' + s.ths.join('|') + ')');
  ok(!!(await g.$('#fx')), 'Exceptions quick filter present');
  ok(s.patch === '69%' && s.backup === '60%', 'cards 69% / 60% (got ' + s.patch + ' / ' + s.backup + ')');
  ok(/incl\. 3 exceptions/.test(s.psub) && /incl\. 3 exceptions/.test(s.bsub), 'card sub-lines incl. 3 exceptions');
  ok(s.ppop.length === 3 && /Compliant\s*20 \(incl\. 3 exceptions\)/.test(s.ppop[0]) && /Non-compliant\s*8/.test(s.ppop[1]) && /no longer needed\s*1/.test(s.ppop[2]), 'patch pop-up: ' + s.ppop.join(' / '));
  ok(s.bpop.length === 3 && /Compliant\s*6 \(incl\. 3 exceptions\)/.test(s.bpop[0]) && /Non-compliant\s*4/.test(s.bpop[1]) && /no longer needed\s*1/.test(s.bpop[2]), 'backup pop-up: ' + s.bpop.join(' / '));
  ok(s.badges === 6, 'six Compliant (exception) badges (' + s.badges + ')');
  ok(/1 expired/.test(s.note) && /1 not applied: no data/.test(s.note) && /ghost-db \(line \d+\)/.test(s.note), 'notice: expired + unmatched (' + s.note + ')');
  ok(await g.evaluate(() => !document.body.innerHTML.includes('<i>backup</i>') && document.body.textContent.includes('Old <i>backup</i> waiver')), 'reason escaped');
  ok(s.xcells.some(t => /Patch:.*expiring soon/.test(t)) && s.xcells.some(t => /Backup:.*no longer needed/.test(t)) && s.xcells.some(t => /exception expired/.test(t)) && s.xcells.some(t => /Backup:.*no data, not applied/.test(t)), 'flag badges in Exception column (incl. no data, not applied)');
  ok(await g.evaluate(() => [...document.querySelectorAll('#ts tbody tr')].some(r => /cms-aurora-mysql/.test(r.textContent) && /No data/.test(r.children[5].textContent) && !r.querySelector('.b.exc'))), 'No data + exception: Backup stays No data, no exception badge');
  ok(s.xcells.some(t => /Patch:.*Backup:/.test(t)), 'both scopes listed for reports-pg');
  await sel('fx', 'yes'); s = await st();
  ok(s.rows === 5 && s.cnt === '5 of 32 server(s)', 'Exceptions only: 5 servers (' + s.cnt + ')');
  ok(s.patch === '100%' && s.backup === '100%', 'cards follow the filter (' + s.patch + ', ' + s.backup + ')');
  ok(s.acc.length === 2, 'account table follows the filter');
  await sel('fx', 'no'); s = await st();
  ok(s.rows === 27 && !s.ppop.some(t => /expiring/.test(t)) && /incl\. 0 exceptions/.test(s.psub), 'Non-exceptions: 27 rows, no attention line');
  await sel('fx', 'attn'); s = await st();
  ok(s.rows === 2 && s.ids.some(t => /legacy-aurora-pg12/.test(t)) && s.ids.some(t => /orders-aurora-pg15/.test(t)), 'Expiring soon or no longer needed: 2 rows');
  await sel('fx', 'expired'); s = await st();
  ok(s.rows === 1 && /hr-sql/.test(s.ids[0]) && /111111111111/.test(s.ids[0]), 'Expired: 1 row');
  await sel('fx', 'yes'); await sel('fa', '222222222222'); s = await st();
  ok(s.rows === 2, 'Exceptions only + account 222222222222: 2 rows (' + s.rows + ')');
  await sel('fa', ''); await sel('fs', 'pbad'); s = await st();
  ok(s.rows === 0, 'Exceptions only + Patch: not compliant: 0 rows (excepted = compliant)');
  await sel('fs', ''); await g.type('#fq', 'vendor freeze'); await sleep(50); s = await st();
  ok(s.rows === 1 && /reports-pg/.test(s.ids[0]), 'search matches the exception reason');
  await g.click('#reset'); await sleep(50); s = await st();
  ok(s.rows === 32 && (await g.evaluate(() => document.getElementById('fx').value)) === '', 'Reset clears the exception filter');
  await sel('fx', 'yes'); await g.click('#csv'); await sleep(300);
  const csv = await g.evaluate(() => window.__csv[window.__csv.length - 1] || ''); const lines = csv.replace(/^\uFEFF/, '').trim().split(/\r?\n/);
  ok(/"backup_reason","patch_exception","patch_exception_reason","patch_exception_expires","patch_exception_flag","patch_actual_status","backup_exception","backup_exception_reason","backup_exception_expires","backup_exception_flag","backup_actual_status"$/.test(lines[0]), 'CSV header has the exception columns');
  ok(lines.length === 6 && lines.slice(1).every(l => /Compliant \(exception\)/.test(l)), 'CSV export follows the filter: 5 rows with the label (' + (lines.length - 1) + ')');
  const srv = fs.readdirSync(path.dirname(file)).find(f => f.endsWith('_servers.csv'));
  if (srv) { const L = fs.readFileSync(path.join(path.dirname(file), srv), 'utf8').replace(/^\uFEFF/, '').trim().split(/\r?\n/), want = new Set(lines.slice(1));
    ok(L[0] === lines[0] && L.slice(1).filter(l => want.has(l)).length === 5, 'browser CSV rows identical to the _servers.csv rows'); }
  if (shots) { await sel('fx', ''); await g.screenshot({path: path.join(shots, 'exceptions_all.png'), fullPage: true});
    await g.hover('#c-patch'); await sleep(100); await g.screenshot({path: path.join(shots, 'exceptions_pop.png')}); }
  await b.close();
  console.log(JSON.stringify({checks: n, fails}));
  process.exit(fails.length ? 1 : 0);
})().catch(e => { console.log(JSON.stringify({error: String(e)})); process.exit(1); });
