// Headless check of the compliance HTML. Usage: node browser_check.js <report.html> [screenshot-dir]
// Prints JSON {checks, fails}; exit 1 on any failure. Needs puppeteer-core (NODE_PATH) and Chrome ($CHROME).
const p = require('puppeteer-core'); const path = require('path'), fs = require('fs');
const fails = []; let n = 0; const ok = (c, m) => { n++; if (!c) fails.push(m); };
const sleep = ms => new Promise(x => setTimeout(x, ms));
(async () => {
  const file = path.resolve(process.argv[2]), shots = process.argv[3];
  if (shots) fs.mkdirSync(shots, {recursive: true});
  const b = await p.launch({executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox']});
  const g = await b.newPage(); const errs = [], net = [];
  g.on('pageerror', e => errs.push(e.message)); g.on('console', m => m.type() === 'error' && errs.push(m.text()));
  g.on('dialog', d => { errs.push('dialog: ' + d.message()); d.dismiss(); });
  await g.setRequestInterception(true);
  g.on('request', q => { if (!/^(file|blob|data):/.test(q.url())) net.push(q.url()); q.continue(); });
  await g.setViewport({width: 1440, height: 1000});
  await g.goto('file://' + file, {waitUntil: 'load'});
  await g.evaluate(() => { window.__csv = []; const o = URL.createObjectURL; URL.createObjectURL = b => { b.arrayBuffer().then(a => window.__csv.push(new TextDecoder('utf-8', {ignoreBOM: true}).decode(a))); return o(b); }; });
  const st = () => g.evaluate(() => ({
    rows: document.querySelectorAll('#ts tbody tr').length, patch: document.querySelector('#c-patch .v').textContent,
    backup: document.querySelector('#c-backup .v').textContent, servers: +document.querySelector('#c-servers .v').textContent,
    acc: document.querySelectorAll('#ta tbody tr').length, reg: document.querySelectorAll('#tr tbody tr').length, eng: document.querySelectorAll('#te tbody tr').length,
    cnt: document.getElementById('cnt').textContent, details: document.querySelectorAll('details,[aria-expanded]').length,
    js: (() => { const t = window.__rcr.tot(window.__rcr.cur()); return {pp: t.pp, bp: t.bp}; })() }));
  const sel = async (id, v) => { await g.select('#' + id, v); await sleep(50); };
  const exp = JSON.parse(process.env.EXPECT || '{}');
  let s = await st();
  ok(s.rows > 0 && s.rows === s.servers, 'rows = servers card');
  ok(s.details === 0, 'no expandable rows');
  if (exp.servers) ok(s.servers === exp.servers, 'servers ' + s.servers + ' != ' + exp.servers);
  if (exp.patch) ok(s.patch === exp.patch, 'patch card ' + s.patch + ' != ' + exp.patch);
  if (exp.backup) ok(s.backup === exp.backup, 'backup card ' + s.backup + ' != ' + exp.backup);
  if (shots) { await g.screenshot({path: path.join(shots, 'desktop.png'), fullPage: true}); }
  const all = s.rows;
  // filters recompute cards and tables
  const accts = await g.$$eval('#fa option', o => o.map(x => x.value).filter(Boolean));
  await sel('fa', accts[accts.length - 1]); s = await st();
  ok(s.rows < all && s.acc === 1 && s.rows === s.servers, 'account filter narrows rows, cards and account table');
  ok(s.patch === (s.js.pp == null ? 'No data' : s.js.pp + '%'), 'patch card follows filter');
  await g.click('#reset'); await sleep(50); s = await st(); ok(s.rows === all, 'reset restores all rows');
  await sel('fe', 'Neptune'); s = await st(); ok(s.eng === 1 && s.rows >= 1, 'engine filter');
  await g.click('#reset'); await sleep(50);
  await sel('fs', 'bfail'); s = await st(); ok(s.rows > 0 && s.rows < all, 'status filter backup fail');
  const bads = await g.$$eval('#ts tbody tr td:nth-child(6)', t => t.map(x => x.textContent));
  ok(bads.every(x => x === 'Fail' || x === 'Unknown'), 'status filter only fail/unknown');
  await g.click('#reset'); await sleep(50);
  const regs = await g.$$eval('#fr option', o => o.map(x => x.value).filter(Boolean));
  await sel('fr', regs[0]); s = await st(); ok(s.reg >= 1 && s.rows < all, 'region filter');
  await g.click('#reset'); await sleep(50);
  await g.type('#fq', 'neptune'); await sleep(80); s = await st(); ok(s.rows >= 1 && s.rows < all, 'search');
  // CSV of the filtered rows
  await g.click('#csv'); await sleep(300);
  let csv = await g.evaluate(() => window.__csv.pop() || '');
  ok(csv.charCodeAt(0) === 0xfeff, 'csv BOM'); ok(/\r\n/.test(csv), 'csv CRLF');
  const lines = csv.replace(/^\ufeff/, '').trim().split('\r\n');
  ok(lines.length === s.rows + 1, 'csv rows = filtered rows (' + (lines.length - 1) + ' vs ' + s.rows + ')');
  ok(lines[0].startsWith('"account_id","region","engine"'), 'csv header');
  await g.click('#reset'); await sleep(50);
  await g.click('#csv'); await sleep(300); csv = await g.evaluate(() => window.__csv.pop() || '');
  ok(!/,"\d+\.\d+(\.\d+)*",/.test(csv), 'no bare dotted versions in csv (Excel dates)');
  ok(!/,"[=+@-][^"]/.test(csv.replace(/,"=""[0-9.]+"""/g, ',x')), 'formula cells prefixed');
  if (exp.inject) ok(await g.evaluate(() => [...document.querySelectorAll('#ts td')].some(t => t.textContent.startsWith('<script>alert(1)')) && !document.querySelector('#ts script')), 'injected id shown as text, not markup');
  ok(await g.evaluate(() => window.__rcr.csvCell('=1+1') === '"\'=1+1"' && window.__rcr.csvCell('15.10') === '"=""15.10"""'), 'csv cell rules');
  if (shots) {
    await g.setViewport({width: 390, height: 844, isMobile: true, deviceScaleFactor: 2}); await sleep(150);
    const w = await g.evaluate(() => document.documentElement.scrollWidth); ok(w <= 400, 'mobile: no page-level horizontal scroll (' + w + ')');
    await g.screenshot({path: path.join(shots, 'mobile.png'), fullPage: false});
  }
  ok(errs.length === 0, 'js errors: ' + errs.join(' | ')); ok(net.length === 0, 'network requests: ' + net.join(' '));
  await b.close();
  console.log(JSON.stringify({checks: n, fails})); process.exit(fails.length ? 1 : 0);
})().catch(e => { console.log(JSON.stringify({checks: n, fails: fails.concat(String(e))})); process.exit(1); });
