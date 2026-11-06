const status = document.querySelector('#status');
const screen = document.querySelector('#screen');
const labels = { overview: '总览', devices: '设备', bridge: '家庭桥接', settings: '应用设置', diagnostics: '诊断', updates: '软件更新' };
let queue = Promise.resolve();
function action(path, input, label) {
  queue = queue.catch(() => {}).then(async () => {
    status.textContent = '正在' + label + '…';
    try {
      const response = await fetch('/api/' + path, {
        method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Preview-Action': '1' }, body: JSON.stringify(input)
      });
      const result = await response.json();
      if (!response.ok) throw new Error(result.error);
      status.textContent = label + ' · 画面稍后刷新';
    } catch (error) { status.textContent = error.message; }
  });
}
document.querySelector('#open').onclick = () => action('open', {}, '打开应用');
const download = document.querySelector('#download-report');
const reportStatus = document.querySelector('#report-status');
async function checkReport() {
  try {
    const report = await (await fetch('/api/report-status')).json();
    download.disabled = !report.available;
    if (report.available) {
      const source = { designPreview: '示例数据', liveRuntime: '运行时采集', savedRuntime: '历史记录', notRunning: '服务未运行' }[report.source] ?? report.source;
      reportStatus.textContent = `最近报告：${source} · ${new Date(report.recordedAt).toLocaleString('zh-CN')}。需要最新数据时，请在电视诊断页重新生成。`;
    }
  } catch { download.disabled = true; }
}
download.onclick = async () => {
  try {
    const response = await fetch('/diagnostics.json');
    if (!response.ok) throw new Error((await response.json()).error);
    const url = URL.createObjectURL(await response.blob());
    const link = document.createElement('a');
    link.href = url; link.download = 'MijiaLAN-TV-Diagnostics.json'; link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    status.textContent = '诊断报告已下载';
  } catch (error) { status.textContent = error.message; }
};
checkReport();
setInterval(checkReport, 2000);
for (const button of document.querySelectorAll('[data-page]')) button.onclick = () => action('navigate', { page: button.dataset.page }, '进入' + labels[button.dataset.page]);
for (const button of document.querySelectorAll('[data-key]')) button.onclick = () => action('key', { key: button.dataset.key }, '发送' + button.textContent);
const keys = { ArrowLeft: 'left', ArrowRight: 'right', ArrowUp: 'up', ArrowDown: 'down', Enter: 'select', Escape: 'back' };
window.addEventListener('keydown', event => {
  const key = keys[event.key];
  if (!key || event.repeat || event.altKey || event.metaKey || event.ctrlKey) return;
  // Let keyboard users activate a focused browser control normally.
  if (event.key === 'Enter' && event.target instanceof HTMLButtonElement) return;
  event.preventDefault();
  action('key', { key }, '发送遥控操作');
});
screen.onload = () => { status.textContent = '实时画面已连接'; };
screen.onerror = () => { status.textContent = '实时画面未连接，请重新启动本机镜像服务。'; };
const firstFrame = setInterval(() => {
  if (screen.naturalWidth > 0) {
    status.textContent = '实时画面已连接';
    clearInterval(firstFrame);
  }
}, 200);
