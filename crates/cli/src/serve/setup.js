const element = id => document.getElementById(id);
let interval;
let polling = false;
let completed = false;
let devices = new Map();

async function request(path, body) {
  const response = await fetch(path, body === undefined ? {} : {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
  });
  if (!response.ok) {
    const error = new Error(await response.text());
    error.status = response.status;
    throw error;
  }
  if (response.headers.get('Content-Type')?.includes('application/json')) return response.json();
}

function qr(id, svg) {
  const img = element(id);
  const src = svg ? 'data:image/svg+xml,' + encodeURIComponent(svg) : '';
  if (src && img.getAttribute('src') !== src) img.src = src;
  if (!src) img.removeAttribute('src');
  img.hidden = !src;
}

function renderDevices(list) {
  const next = new Map();
  for (const device of list) {
    let row = devices.get(device.id);
    if (!row) {
      const entry = document.createElement('div');
      entry.className = 'device';
      const label = document.createElement('label');
      const box = document.createElement('input');
      box.type = 'checkbox';
      box.checked = device.selected;
      const title = document.createElement('span');
      label.append(box, title);
      const details = document.createElement('details');
      const summary = document.createElement('summary');
      const main = document.createElement('div');
      const advanced = document.createElement('details');
      const advancedTitle = document.createElement('summary');
      advanced.append(advancedTitle);
      details.append(summary, main, advanced);
      entry.append(label, details);
      element('devices').append(entry);
      row = { entry, box, title, details, summary, main, advanced, advancedTitle, choices: new Map(), edited: false };
      const target = row;
      box.addEventListener('change', () => {
        if (box.checked && ![...target.choices.values()].some(choice => choice.box.checked)) {
          for (const choice of target.choices.values()) choice.box.checked = true;
          target.edited = true;
        }
        updateServiceControls(target);
      });
    }
    row.box.disabled = !device.available;
    const detail = device.available ? (device.online ? '' : ' · 离线') : ' · 暂无可用的家庭服务';
    const title = (device.room ? device.room + ' · ' : '') + device.name + detail;
    if (row.title.textContent !== title) row.title.textContent = title;
    renderServices(row, device.services);
    next.set(device.id, row);
  }
  for (const [id, row] of devices) if (!next.has(id)) row.entry.remove();
  devices = next;
  element('devices-hint').textContent = list.length
    ? '展开设备可逐项选择控件和传感器。关闭某项会将它从「家庭」的场景和自动化中移除。'
    : '设备导入后会显示在这里。';
}

function renderServices(row, services) {
  const next = new Map();
  for (const service of services) {
    let choice = row.choices.get(service.key);
    if (!choice) {
      const label = document.createElement('label');
      const box = document.createElement('input');
      box.type = 'checkbox';
      box.checked = service.selected;
      const title = document.createElement('span');
      label.append(box, title);
      choice = { label, box, title };
      box.addEventListener('change', () => {
        row.edited = true;
        if (![...row.choices.values()].some(item => item.box.checked)) row.box.checked = false;
        updateServiceControls(row);
      });
    }
    const parent = service.advanced ? row.advanced : row.main;
    if (choice.label.parentNode !== parent) parent.append(choice.label);
    const title = service.title + ' · ' + service.detail;
    if (choice.title.textContent !== title) choice.title.textContent = title;
    next.set(service.key, choice);
  }
  for (const [key, choice] of row.choices) if (!next.has(key)) choice.label.remove();
  row.choices = next;
  row.details.hidden = !services.length;
  const advancedCount = services.filter(service => service.advanced).length;
  row.advanced.hidden = !advancedCount;
  row.advancedTitle.textContent = '高级项目（' + advancedCount + '）';
  updateServiceControls(row);
}

function updateServiceControls(row) {
  let shown = 0;
  for (const choice of row.choices.values()) {
    choice.box.disabled = !row.box.checked || row.box.disabled;
    if (!choice.box.disabled && choice.box.checked) shown++;
  }
  row.summary.textContent = '家庭控件（显示 ' + shown + '/' + row.choices.size + ' 项）';
}

async function refresh() {
  if (polling) return;
  polling = true;
  try {
    const state = await request('/api/state');
    if (completed) return;
    element('unlock').hidden = true;
    element('wizard').hidden = false;
    const labels = {
      fetching: '正在获取二维码…', waiting: '请用手机「米家」App 扫码并确认。', importing: '正在导入设备…',
    };
    const busy = Object.hasOwn(labels, state.import.progress);
    element('import-status').textContent = state.import.detail ?? labels[state.import.progress] ?? '';
    element('region').disabled = element('import-button').disabled = busy;
    qr('login-qr', state.import.qr);
    renderDevices(state.devices);
    element('bridge-button').disabled = busy || !state.devices.some(device => device.available);
    element('bridge-button').textContent = state.bridge.running ? '更新配件选择' : '启用家庭桥';
    qr('pair-qr', state.bridge.qr);
    element('pin').textContent = state.bridge.pin ?? '';
    element('pair-status').textContent = state.bridge.paired ? '已配对。完成设置后可关闭页面。' :
      state.bridge.running ? '打开 iPhone 的「家庭 → 添加配件」，扫描下方二维码。' : '启用家庭桥后会显示配对码。';
    element('finish').hidden = !state.bridge.paired;
    element('finish').disabled = busy;
  } catch (error) {
    if (completed) return;
    if (error.status === 401) {
      element('unlock').hidden = false;
      element('wizard').hidden = true;
    } else {
      element('notice').textContent = '向导连接已断开。请在 DSM 查看桥接状态或重新打开向导。';
    }
  } finally {
    polling = false;
  }
}

function submit(id, action) {
  element(id).addEventListener('submit', async event => {
    event.preventDefault();
    if (event.submitter) event.submitter.disabled = true;
    element('notice').textContent = '';
    try {
      await action();
    } catch (error) {
      element('notice').textContent = error.message;
    } finally {
      if (event.submitter) event.submitter.disabled = false;
      await refresh();
    }
  });
}

submit('unlock', async () => {
  await request('/api/unlock', { code: element('code').value.trim() });
  element('code').value = '';
});
submit('import', () => request('/api/import', { region: element('region').value }));
submit('bridge', async () => {
  const available = [...devices].filter(([, row]) => !row.box.disabled);
  const selected = available.filter(([, row]) => row.box.checked).map(([id]) => id);
  const services = Object.fromEntries(available.filter(([, row]) => row.edited).map(([id, row]) => [
    id, [...row.choices].filter(([, choice]) => choice.box.checked).map(([key]) => key),
  ]));
  await request('/api/bridge', { devices: selected, services });
  element('notice').textContent = '已保存配件选择。';
});
element('finish').addEventListener('click', async () => {
  try {
    await request('/api/finish', {});
    completed = true;
    clearInterval(interval);
    element('wizard').hidden = true;
    element('notice').textContent = '设置完成。群晖家庭桥正在运行，可以关闭此页面。';
  } catch (error) {
    element('notice').textContent = error.message;
  }
});
element('notice').textContent = '';
refresh();
interval = setInterval(refresh, 1500);
