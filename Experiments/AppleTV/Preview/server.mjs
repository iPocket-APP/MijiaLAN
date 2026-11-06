// Loopback-only native tvOS preview. No arbitrary shell, device, or bundle input.
import http from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const run = promisify(execFile);
const simulator = process.env.MIJIALAN_TV_SIMULATOR ?? '17F26DCA-8995-4C1E-AB4A-3740301FD679';
if (!/^[0-9A-F-]{36}$/i.test(simulator)) throw new Error('Invalid simulator UDID');
const bundle = 'com.ipocket.MijiaLAN.TVPrototype';
const port = Number(process.env.MIJIALAN_TV_PREVIEW_PORT ?? 3202);
const source = new URL(process.env.MIJIALAN_TV_STREAM ?? 'http://127.0.0.1:3200');
if (!['localhost', '127.0.0.1'].includes(source.hostname)) throw new Error('Stream must be local');
const helper = `/helper/${simulator}`;
const keyUsages = { up: 0x52, down: 0x51, left: 0x50, right: 0x4f, select: 0x28, back: 0x29 };
const pages = new Set(['overview', 'devices', 'bridge', 'settings', 'diagnostics', 'updates']);
let socket;
let inputQueue = Promise.resolve();
let reportPath;

async function diagnosticReport() {
  if (!reportPath) {
    const { stdout } = await run('xcrun', ['simctl', 'get_app_container', simulator, bundle, 'data'], { timeout: 5000 });
    reportPath = join(stdout.trim(), 'Library/Caches/Diagnostics/MijiaLAN-Diagnostics.json');
  }
  if ((await stat(reportPath)).size > 8 * 1024 * 1024) throw new Error('报告超过本机预览下载大小限制。');
  const data = await readFile(reportPath);
  const report = JSON.parse(data.toString('utf8'));
  if (report.schemaVersion !== 1 || report.platform !== 'tvOS' || !Array.isArray(report.devices)) throw new Error('诊断报告格式无效。');
  return { data, report };
}

async function openPreview(restart = false) {
  const flags = restart ? ['--terminate-running-process'] : [];
  await run('xcrun', ['simctl', 'launch', ...flags, simulator, bundle, '--design-preview'], { timeout: 15000 });
}

async function pressKey(key) {
  if (!socket || socket.readyState > 1) {
    const url = new URL(helper + '/ws', source);
    url.protocol = 'ws:';
    socket = new WebSocket(url);
  }
  const current = socket;
  if (current.readyState !== 1) {
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('遥控器连接超时，请重新打开应用。')), 4000);
      current.addEventListener('open', () => { clearTimeout(timer); resolve(); }, { once: true });
      current.addEventListener('error', () => { clearTimeout(timer); reject(new Error('遥控器未连接。')); }, { once: true });
    });
  }
  for (const type of ['down', 'up']) {
    current.send(Buffer.concat([Buffer.from([0x06]), Buffer.from(JSON.stringify({ type, usage: keyUsages[key] }))]));
    await new Promise(resolve => setTimeout(resolve, 45));
  }
}

function send(res, status, value, type = 'application/json') {
  res.writeHead(status, { 'Content-Type': type + '; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
  res.end(type === 'application/json' ? JSON.stringify(value) : value);
}

const server = http.createServer(async (req, res) => {
  try {
    if (![ `localhost:${port}`, `127.0.0.1:${port}` ].includes(req.headers.host)) return send(res, 403, { error: '仅限本机预览。' });
    const path = new URL(req.url, `http://localhost:${port}`).pathname;
    if (req.method === 'GET' && path === '/api/report-status') {
      try {
        const { report } = await diagnosticReport();
        return send(res, 200, { available: true, source: report.source, recordedAt: report.recordedAt, exportedAt: report.exportedAt });
      } catch { return send(res, 200, { available: false }); }
    }
    if (req.method === 'GET' && path === '/diagnostics.json') {
      try {
        const { data } = await diagnosticReport();
        res.writeHead(200, { 'Content-Type': 'application/json', 'Content-Disposition': 'attachment; filename="MijiaLAN-TV-Diagnostics.json"', 'Cache-Control': 'no-store' });
        return res.end(data);
      } catch { return send(res, 404, { error: '请先在电视诊断页生成报告。' }); }
    }
    if (req.method === 'GET' && path === '/stream') {
      const upstream = http.get(new URL(helper + '/stream.mjpeg', source), response => {
        res.writeHead(response.statusCode ?? 502, { 'Content-Type': response.headers['content-type'] ?? 'application/octet-stream', 'Cache-Control': 'no-store' });
        response.pipe(res);
      });
      upstream.on('error', () => { if (!res.headersSent) send(res, 502, { error: '实时画面尚未连接。' }); else res.destroy(); });
      res.on('close', () => upstream.destroy());
      return;
    }
    if (req.method === 'GET' && ['/', '/client.js', '/icon.png'].includes(path)) {
      const file = path === '/' ? 'index.html' : path === '/icon.png' ? '../Design/tvos-app-icon.png' : 'client.js';
      const data = await readFile(new URL(file, import.meta.url));
      if (path === '/icon.png') { res.writeHead(200, { 'Content-Type': 'image/png' }); return res.end(data); }
      return send(res, 200, data, path === '/' ? 'text/html' : 'text/javascript');
    }
    if (req.method !== 'POST' || !path.startsWith('/api/')) return send(res, 404, { error: 'Unknown route' });
    const origins = [`http://localhost:${port}`, `http://127.0.0.1:${port}`];
    if (!origins.includes(req.headers.origin) || req.headers['x-preview-action'] !== '1') return send(res, 403, { error: '仅接受本页的预览操作。' });
    let text = '';
    for await (const chunk of req) {
      text += chunk;
      if (text.length > 1024) return send(res, 413, { error: 'Request too large' });
    }
    const input = JSON.parse(text || '{}');
    const action = async () => {
      if (path === '/api/open') return openPreview(true);
      if (path === '/api/navigate' && pages.has(input.page)) {
        await openPreview();
        return run('xcrun', ['simctl', 'openurl', simulator, `mijialantv-preview://navigate/${input.page}`], { timeout: 15000 });
      }
      if (path === '/api/key' && Object.hasOwn(keyUsages, input.key)) return pressKey(input.key);
      throw new Error('不支持这个预览操作。');
    };
    inputQueue = inputQueue.catch(() => {}).then(action);
    await inputQueue;
    send(res, 200, { ok: true });
  } catch (error) { send(res, 400, { error: error.message }); }
});

await openPreview(true);
server.listen(port, '127.0.0.1', () => console.log(`tvOS native preview: http://localhost:${port}/`));
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => {
  socket?.close();
  server.close();
  process.exit(0);
});
