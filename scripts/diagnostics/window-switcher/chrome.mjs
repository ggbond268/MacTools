// Run only against an isolated, temporary Chrome profile owned by this process.
import { spawn, spawnSync } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import assert from 'node:assert/strict';

const repository = fileURLToPath(new URL('../../../', import.meta.url));
const products = path.resolve(repository, process.argv[2] ?? 'build/WindowSwitcherRedesign/Build/Products/Debug');
const folder = await mkdtemp('/private/tmp/mactools-switcher-fixture-');
const executable = path.join(folder, 'probe');
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
let child, socket, verifiedOwner = false;
let nextID = 0;
const calls = new Map();

function request(method, params = {}) {
  const id = ++nextID;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      calls.delete(id);
      reject(new Error(`Timed out: ${method}`));
    }, 10000);
    calls.set(id, {
      resolve: value => { clearTimeout(timer); resolve(value); },
      reject: error => { clearTimeout(timer); reject(error); }
    });
    socket.send(JSON.stringify({ id, method, params }));
  });
}

function hasExited() {
  return !child || child.exitCode !== null || child.signalCode !== null;
}

try {
  const compilation = spawnSync('xcrun', [
    'swiftc', '-parse-as-library', '-module-cache-path', path.join(folder, 'modules'),
    '-I', products, '-F', products, '-L', products, '-lWindowSwitcherPluginCore',
    '-framework', 'MacToolsPluginKit', '-Xlinker', '-rpath', '-Xlinker', products,
    fileURLToPath(new URL('Probe.swift', import.meta.url)), '-o', executable
  ], { encoding: 'utf8', timeout: 120000 });
  assert.equal(compilation.status, 0, compilation.stderr || 'Probe compilation failed');
  child = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
    `--user-data-dir=${folder}`, '--remote-debugging-port=0', '--no-startup-window', '--no-first-run',
    '--no-default-browser-check', '--disable-sync', '--disable-background-networking',
    '--disable-component-update', '--disable-default-apps', '--disable-extensions', '--disable-session-crashed-bubble'
  ], { stdio: 'ignore' });
  let address;
  for (let attempt = 0; attempt < 100; attempt++) {
    try {
      const [port, endpoint] = (await readFile(path.join(folder, 'DevToolsActivePort'), 'utf8')).trim().split('\n');
      address = `ws://127.0.0.1:${port}${endpoint}`;
      break;
    } catch { await pause(100); }
  }
  assert.ok(address, 'Fixture browser did not start');
  socket = new WebSocket(address);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
  socket.onmessage = event => {
    const value = JSON.parse(event.data);
    const pending = calls.get(value.id);
    if (!pending) return;
    calls.delete(value.id);
    if (value.error) pending.reject(new Error(value.error.message));
    else pending.resolve(value.result);
  };
  const info = await request('SystemInfo.getProcessInfo');
  assert.equal(info.processInfo.find(process => process.type === 'browser')?.id, child.pid, 'Fixture PID mismatch');
  verifiedOwner = true;

  let count = 0;
  for (const total of [1, 10, 30, 60]) {
    while (count < total) {
      count++;
      const html = `<title>Window Switcher Fixture</title><h1>Window Switcher Fixture ${count}</h1><p>Synthetic local test content.</p>`;
      await request('Target.createTarget', { url: `data:text/html,${encodeURIComponent(html)}`, newWindow: true, background: true });
    }
    await pause(400);
    console.log(`phase=${total}`);
    const probe = spawnSync(executable, [String(child.pid), ...(total === 60 ? ['--exercise'] : [])], {
      encoding: 'utf8', timeout: 30000,
      env: { ...process.env, WINDOW_SWITCHER_FIXTURE_PID: String(child.pid), WINDOW_SWITCHER_FIXTURE_COUNT: String(total) }
    });
    console.log(probe.stdout.trim());
    assert.equal(probe.status, 0, probe.stderr || 'Probe failed');
    assert.ok(probe.stdout.includes('discoveryReady=true'), 'Chrome window startup did not finish');
    const scans = probe.stdout.split('\n').filter(line => line.startsWith('scan='));
    assert.equal(scans.length, 4, 'Four scans must complete');
    for (const scan of scans) {
      assert.ok(scan.includes(`raw=${total} windows=${total} unique=${total} unavailable=false titleGroups=1`), scan);
      assert.ok(scan.includes('retained=true'), scan);
    }
    if (total === 1) assert.ok(probe.stdout.includes('singleWindowPreview=true permission=true'), 'Single-window capture failed');
    if (total === 60) {
      assert.equal(probe.stdout.match(/catalogActivation=succeeded exactFocus=true frontmost=true/g)?.length, 3);
      assert.equal(probe.stdout.match(/cancelPreservedFrontmost=true exactWindow=true/g)?.length, 2);
      for (const expected of ['catalogWindows=60', 'mruExact=true', 'externalFocusMRU=true', 'resetAfterExternalFocus=succeeded', 'restore=succeeded restored=true',
        'observedHidden=true', 'activationAfterHide=succeeded visible=true', 'close=requested removed=true remaining=59']) {
        assert.ok(probe.stdout.includes(expected), expected);
      }
    }
  }
} finally {
  // Never send Browser.close before establishing that this is our own instance.
  if (verifiedOwner && socket?.readyState === WebSocket.OPEN) {
    try { await request('Browser.close'); } catch { /* The browser may already have exited. */ }
  }
  socket?.close();
  for (let attempt = 0; attempt < 50 && !hasExited(); attempt++) await pause(100);
  if (!hasExited()) { child.kill('SIGTERM'); await pause(500); }
  if (hasExited()) {
    await rm(folder, { recursive: true, force: true });
    console.log('fixture-cleanup=complete');
  } else {
    console.error(`Fixture still running; retained its temporary profile: ${folder}`);
    process.exitCode = 1;
  }
}
