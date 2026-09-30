import { readFileSync, writeFileSync } from 'node:fs';

const SRC = 'deepseek-harness/packages/client/ui-theme/src/styles/';
const B = '<launcher-root>/runtime/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/';
const P = (pkg, file) => B + 'dsh-client-ui-' + pkg + '/lib/' + file;

const minify = (css) => css
  .replace(/\/\*[\s\S]*?\*\//g, '')
  .replace(/\s+/g, ' ')
  .replace(/\s*([{}:;,>])\s*/g, '$1')
  .trim();

function rep(s, oldS, newS, label) {
  const n = s.split(oldS).length - 1;
  if (n !== 1) throw new Error(`${label}: count ${n}`);
  return s.replace(oldS, newS);
}

// ---------- A. ui-theme ----------
{
  let s = readFileSync(P('theme', 'client.js'), 'utf8');
  const baseCss = minify(readFileSync(SRC + 'base.css', 'utf8'));
  const platformCss = minify(readFileSync(SRC + 'design-platform.css', 'utf8'));
  const shadowCss = minify(readFileSync(SRC + 'gradient-shadow-text.css', 'utf8'));
  const frameCss = minify(readFileSync(SRC + 'harness-frame.css', 'utf8'));
  function replaceByVar(varName, regionNeedle, css) {
    const region = s.indexOf(regionNeedle);
    if (region < 0) throw new Error(varName + ': region missing');
    const assign = s.indexOf(`var ${varName} = "`, region);
    if (assign < 0) throw new Error(varName + ': assign missing');
    const start = assign + `var ${varName} = "`.length;
    const endRegion = s.indexOf('//#endregion', start);
    const end = s.lastIndexOf('"', endRegion);
    s = s.slice(0, start) + css + s.slice(end);
  }
  replaceByVar('base_css_default', 'ui-theme/src/styles/base.css.mjs', baseCss);
  replaceByVar('design_platform_css_default', 'ui-theme/src/styles/design-platform.css.mjs', platformCss);
  replaceByVar('gradient_shadow_text_css_default', 'ui-theme/src/styles/gradient-shadow-text.css.mjs', shadowCss + frameCss);
  s = rep(s, 'const DEFAULT_PREFERENCE = "system";', 'const DEFAULT_PREFERENCE = "dark";', 'theme default const');
  s = rep(s, 'preference: "system",\n\t\t\t\t\trevision: -1', 'preference: "dark",\n\t\t\t\t\trevision: -1', 'theme store init');
  writeFileSync(P('theme', 'client.js'), s, 'utf8');
  console.log('OK ui-theme client.js');
}
{
  let s = readFileSync(P('theme', 'index.js'), 'utf8');
  s = rep(s, 'const LIGHT_BACKGROUND = "#fff";\nconst DARK_BACKGROUND = "#151517";', 'const LIGHT_BACKGROUND = "#f5f7fa";\nconst DARK_BACKGROUND = "#0a0e14";', 'theme boot colors');
  s = rep(s, 'const DEFAULT_PREFERENCE = "system";', 'const DEFAULT_PREFERENCE = "dark";', 'theme host default');
  writeFileSync(P('theme', 'index.js'), s, 'utf8');
  console.log('OK ui-theme index.js');
}

// ---------- B. ui-layout: skip link + status dots + mobile ----------
{
  let s = readFileSync(P('layout', 'client.js'), 'utf8');
  // B1 skip link (7 patches)
  const skipCss =
    '.pI_x6G_skipLink{position:fixed;top:12px;left:50%;z-index:1001;padding:8px 14px;border:.5px solid var(--dsw-alias-border-l4);border-radius:var(--dsw-radius-sm);background:var(--dsw-alias-bg-layer-1);color:var(--dsw-alias-label-primary);font-size:13px;line-height:18px;text-decoration:none;transform:translate(-50%,calc(-100% - 24px));transition:transform var(--ds-transition-duration-fast) var(--ds-ease-in-out)}' +
    '.pI_x6G_skipLink:focus-visible{transform:translate(-50%,0)}' +
    '@media (prefers-reduced-motion:reduce){.pI_x6G_skipLink{transition:none}}';
  s = rep(s, '.pI_x6G_overlayLayer>*{pointer-events:auto}"', '.pI_x6G_overlayLayer>*{pointer-events:auto}' + skipCss + '"', 'layout skip css');
  s = rep(s, '\t\t\t"sidebarCol": "pI_x6G_sidebarCol"\n\t\t};', '\t\t\t"sidebarCol": "pI_x6G_sidebarCol",\n\t\t\t"skipLink": "pI_x6G_skipLink"\n\t\t};', 'layout css map');
  s = rep(s, 'className: AppFrame_module_css_default.centerCol,\n\t\t\t\tchildren: props.children', 'className: AppFrame_module_css_default.centerCol,\n\t\t\t\tid: "dsh-main",\n\t\t\t\ttabIndex: -1,\n\t\t\t\tchildren: props.children', 'layout landmark');
  s = rep(s, 'function AppFrame({ useStore, useSessions, usePanelInfo, actions, renderSlot, t })', 'function AppFrame({ useStore, useSessions, usePanelInfo, actions, renderSlot, skipToContent, t })', 'layout props');
  s = rep(s, 'children: [\n\t\t\t\t\t(0, react_jsx_runtime.jsx)(DocumentTitle, {', 'children: [\n\t\t\t\t\t(0, react_jsx_runtime.jsx)("a", {\n\t\t\t\t\t\tclassName: AppFrame_module_css_default.skipLink,\n\t\t\t\t\t\thref: "#dsh-main",\n\t\t\t\t\t\tchildren: skipToContent\n\t\t\t\t\t}),\n\t\t\t\t\t(0, react_jsx_runtime.jsx)(DocumentTitle, {', 'layout skip element');
  s = rep(s, 'const zh = { toggle: "展开／收起左侧栏" };', 'const zh = { toggle: "展开／收起左侧栏", skipToContent: "跳到主内容", "status.aria": "服务状态", "status.ok": "正常", "status.warn": "检测中", "status.err": "离线", "status.dsh": "dsh", "status.openviking": "OpenViking", "status.ollama": "Ollama" };', 'layout zh');
  s = rep(s, 'const en = { toggle: "Toggle left sidebar" };', 'const en = { toggle: "Toggle left sidebar", skipToContent: "Skip to main content", "status.aria": "Service status", "status.ok": "Up", "status.warn": "Checking", "status.err": "Down", "status.dsh": "dsh", "status.openviking": "OpenViking", "status.ollama": "Ollama" };', 'layout en');
  s = rep(s, 'store\n\t\t\t\t}, AppFrame);', 'store,\n\t\t\t\t\tinject: () => ({ skipToContent: t("skipToContent") })\n\t\t\t\t}, AppFrame);', 'layout inject');
  // B2 status dots
  s = rep(s, 'let _deepseek_ai_dsh_client_store = require("@deepseek-ai/dsh-client-store");', 'let _deepseek_ai_dsh_client_store = require("@deepseek-ai/dsh-client-store");\n\t\tlet _primitives = require("@deepseek-ai/dsh-client-ui-primitives");', 'layout primitives require');
  const cssText =
    '.svcDot_root{position:absolute;top:6px;right:12px;display:flex;align-items:center;gap:10px;-webkit-app-region:no-drag}' +
    '.svcDot_item{display:inline-flex;align-items:center;gap:5px;-webkit-app-region:no-drag}' +
    '.svcDot_label{font-family:var(--ds-font-family-code);font-size:10px;font-weight:500;line-height:14px;letter-spacing:.04em;font-variant-numeric:tabular-nums;color:var(--dsw-alias-label-tertiary)}';
  const block =
    '//#region lib/types/client/ServiceStatusDots.js\n' +
    '\t\tconst SERVICES$1 = [\n\t\t\t{ id: "dsh" },\n\t\t\t{ id: "openviking", url: "http://127.0.0.1:1933/" },\n\t\t\t{ id: "ollama", url: "http://127.0.0.1:11434/api/tags" }\n\t\t];\n' +
    '\t\tasync function probeLatency$1(url, timeoutMs) {\n\t\t\tconst started = performance.now();\n\t\t\tconst controller = new AbortController();\n\t\t\tconst timer = setTimeout(() => { controller.abort(); }, timeoutMs);\n\t\t\ttry {\n\t\t\t\tawait fetch(url, { mode: "no-cors", cache: "no-store", signal: controller.signal });\n\t\t\t\treturn Math.round(performance.now() - started);\n\t\t\t} finally {\n\t\t\t\tclearTimeout(timer);\n\t\t\t}\n\t\t}\n' +
    '\t\tfunction portOf$1(service) {\n\t\t\tif (service.url !== void 0) return new URL(service.url).port;\n\t\t\treturn location.port !== "" ? location.port : location.protocol === "https:" ? "443" : "80";\n\t\t}\n' +
    '\t\tfunction stateLabel$1(state, t) {\n\t\t\treturn state === "done" ? t("status.ok") : state === "error" ? t("status.err") : t("status.warn");\n\t\t}\n' +
    '\t\tconst ServiceStatusDots = (0, react.memo)(function ServiceStatusDots$1({ t }) {\n' +
    '\t\t\tconst [readings, setReadings] = (0, react.useState)(() => ({\n\t\t\t\tdsh: { state: "done", latencyMs: null },\n\t\t\t\topenviking: { state: "warning", latencyMs: null },\n\t\t\t\tollama: { state: "warning", latencyMs: null }\n\t\t\t}));\n' +
    '\t\t\t(0, react.useEffect)(() => {\n\t\t\t\tlet disposed = false;\n\t\t\t\tconst sample = async () => {\n\t\t\t\t\tconst next = {};\n\t\t\t\t\tfor (const service of SERVICES$1) {\n\t\t\t\t\t\tif (service.url === void 0) { next[service.id] = { state: "done", latencyMs: null }; continue; }\n\t\t\t\t\t\ttry {\n\t\t\t\t\t\t\tconst latencyMs = await probeLatency$1(service.url, 2500);\n\t\t\t\t\t\t\tnext[service.id] = { state: "done", latencyMs };\n\t\t\t\t\t\t} catch {\n\t\t\t\t\t\t\tnext[service.id] = { state: "error", latencyMs: null };\n\t\t\t\t\t\t}\n\t\t\t\t\t}\n\t\t\t\t\tif (!disposed) setReadings(next);\n\t\t\t\t};\n\t\t\t\tvoid sample();\n\t\t\t\tconst timer = setInterval(() => { void sample(); }, 3e4);\n\t\t\t\treturn () => { disposed = true; clearInterval(timer); };\n\t\t\t}, []);\n' +
    '\t\t\treturn (0, react_jsx_runtime.jsx)("div", {\n\t\t\t\tclassName: ServiceStatusDots_module_css_default.root,\n\t\t\t\trole: "status",\n\t\t\t\t"aria-label": t("status.aria"),\n\t\t\t\tchildren: SERVICES$1.map((service) => {\n\t\t\t\t\tconst reading = readings[service.id];\n\t\t\t\t\tconst state = reading?.state ?? "warning";\n\t\t\t\t\tconst latencyText = reading?.latencyMs == null ? "" : `${reading.latencyMs}ms`;\n\t\t\t\t\tconst label = `${t(`status.${service.id}`)} ${portOf$1(service)} ${stateLabel$1(state, t)} ${latencyText}`.trim();\n\t\t\t\t\treturn (0, react_jsx_runtime.jsx)(_primitives.Tooltip, {\n\t\t\t\t\t\tkey: service.id, label, side: "bottom", delayMs: 300,\n\t\t\t\t\t\tchildren: (0, react_jsx_runtime.jsxs)("span", {\n\t\t\t\t\t\t\tclassName: ServiceStatusDots_module_css_default.item,\n\t\t\t\t\t\t\t"data-service-status": service.id,\n\t\t\t\t\t\t\tchildren: [\n\t\t\t\t\t\t\t\t(0, react_jsx_runtime.jsx)(_primitives.StateDot, { state, size: 8 }),\n\t\t\t\t\t\t\t\t(0, react_jsx_runtime.jsx)("span", { className: ServiceStatusDots_module_css_default.label, children: t(`status.${service.id}`) })\n\t\t\t\t\t\t\t]\n\t\t\t\t\t\t})\n\t\t\t\t\t});\n\t\t\t\t})\n\t\t\t});\n\t\t});\n' +
    '\t\t//#endregion\n' +
    '\t\t//#region \\0dsh-css:/home/runner/work/deepseek-harness/deepseek-harness/packages/client/ui-layout/src/client/ServiceStatusDots.module.css.mjs\n' +
    '\t\tconst css$2 = "' + cssText + '";\n' +
    '\t\tconst tagId$2 = "@deepseek-ai/dsh-client-ui-layout/ServiceStatusDots.module.css";\n' +
    '\t\tif (typeof document !== "undefined" && document.querySelector("style[data-plugin-css=" + JSON.stringify(tagId$2) + "]") === null) {\n' +
    '\t\t\tconst tag$2 = document.createElement("style");\n\t\t\ttag$2.dataset.plugin = "@deepseek-ai/dsh-client-ui-layout";\n\t\t\ttag$2.dataset.pluginCss = tagId$2;\n\t\t\ttag$2.textContent = css$2;\n\t\t\tdocument.head.appendChild(tag$2);\n\t\t}\n' +
    '\t\tvar ServiceStatusDots_module_css_default = {\n\t\t\t"root": "svcDot_root",\n\t\t\t"item": "svcDot_item",\n\t\t\t"label": "svcDot_label"\n\t\t};\n' +
    '\t\t//#endregion\n';
  s = rep(s, '//#region lib/types/client/theme-presenter.js', block + '\t\t//#region lib/types/client/theme-presenter.js', 'layout dots block');
  s = rep(s, '\t\t\t\t}, AppFrame);\n\t\t\t\tconst disposeShortcut = ctx.shortcuts.register({', '\t\t\t\t}, AppFrame);\n\t\t\t\tconst disposeStatusDots = ctx.slots.register({\n\t\t\t\t\tname: "shell.overlay",\n\t\t\t\t\tid: "service-status",\n\t\t\t\t\torder: -1000,\n\t\t\t\t\tlocale: "shortcuts.layout"\n\t\t\t\t}, ServiceStatusDots);\n\t\t\t\tconst disposeShortcut = ctx.shortcuts.register({', 'layout dots register');
  s = rep(s, 'return () => {\n\t\t\t\t\tdisposeShortcut();', 'return () => {\n\t\t\t\t\tdisposeShortcut();\n\t\t\t\t\tdisposeStatusDots();', 'layout dots dispose');
  // B3 mobile
  const mobile =
    '@media (max-width:768px){.pI_x6G_frame{grid-template-columns:100%!important;grid-template-rows:minmax(0,1fr) auto}' +
    '.pI_x6G_sidebarCol{grid-row:2;grid-column:1;border-right:none;border-top:.5px solid var(--dsw-alias-border-l3)}' +
    '.pI_x6G_centerCol{grid-row:1;grid-column:1}' +
    '.pI_x6G_rightbarCol{grid-row:1;grid-column:1}' +
    '.pI_x6G_handle{display:none}}';
  s = rep(s, '.pI_x6G_skipLink{transition:none}}"', '.pI_x6G_skipLink{transition:none}}' + mobile + '"', 'layout mobile css');
  writeFileSync(P('layout', 'client.js'), s, 'utf8');
  console.log('OK ui-layout client.js');
}

// ---------- C. ui-conversation ----------
{
  let s = readFileSync(P('conversation', 'client.js'), 'utf8');
  s = rep(s, 'clsx(InputBar_module_css_default.card, workspaceTrigger && InputBar_module_css_default.cardWorkspaceTrigger)', 'clsx(InputBar_module_css_default.card, "frame", workspaceTrigger && InputBar_module_css_default.cardWorkspaceTrigger)', 'conv frame class');
  s = rep(s, 'padding-top:8px;display:flex;position:relative}.uV2eYG_cardWorkspaceTrigger', 'padding-top:8px;display:flex;position:relative}.uV2eYG_card:focus-within{--dsw-elevation-stroke-color:var(--dsw-static-deepseek-500)}.uV2eYG_cardWorkspaceTrigger', 'conv focus rule');
  s = rep(s, 'padding:0 var(--dsh-composer-side-clearance) 4px', 'padding:0 var(--dsh-composer-side-clearance) calc(4px + env(safe-area-inset-bottom,0px))', 'conv safe-area');
  writeFileSync(P('conversation', 'client.js'), s, 'utf8');
  console.log('OK ui-conversation client.js');
}

// ---------- D. ui-sidebar ----------
{
  let s = readFileSync(P('sidebar', 'client.js'), 'utf8');
  const needle = '.hHd-Xa_collapsed .hHd-Xa_settingsArea,.hHd-Xa_collapsed .hHd-Xa_footerActions{justify-content:center;width:auto;display:flex}';
  const mobile =
    '@media (max-width:768px){.hHd-Xa_collapsed{flex-direction:row;align-items:center;justify-content:space-between;width:100%;height:56px;padding:0 8px;gap:6px}' +
    '.hHd-Xa_collapsed .hHd-Xa_logoRow,.hHd-Xa_collapsed .hHd-Xa_regionArea{display:none}' +
    '.hHd-Xa_collapsed .hHd-Xa_panelList{flex-direction:row;flex:1;justify-content:space-around;gap:4px;margin:0}' +
    '.hHd-Xa_collapsed .hHd-Xa_panelRow{width:44px;height:44px}' +
    '.hHd-Xa_collapsed .hHd-Xa_footArea{flex-direction:row;align-items:center;gap:6px}' +
    '.hHd-Xa_collapsed .hHd-Xa_settingsArea,.hHd-Xa_collapsed .hHd-Xa_footerActions{flex-direction:row}}';
  s = rep(s, needle, needle + mobile, 'sidebar tab bar');
  writeFileSync(P('sidebar', 'client.js'), s, 'utf8');
  console.log('OK ui-sidebar client.js');
}

// ---------- E. ui-chat: bubble 88% ----------
{
  let s = readFileSync(P('chat', 'client.js'), 'utf8');
  s = rep(s, '.702), 82%);flex-direction:column;align-items:flex-end;gap:8px;display:flex}', '.702), 82%);flex-direction:column;align-items:flex-end;gap:8px;display:flex}@media (max-width:768px){.Sixlwa_userStack{max-width:88%}}', 'chat bubble mobile');
  writeFileSync(P('chat', 'client.js'), s, 'utf8');
  console.log('OK ui-chat client.js');
}

// ---------- F. ui-commands: palette frame ----------
{
  let s = readFileSync(P('commands', 'client.js'), 'utf8');
  s = rep(s, 'className: PopupSelectView_module_css_default.card,\n\t\t\t\tstyle: { maxHeight }', 'className: PopupSelectView_module_css_default.card + " frame",\n\t\t\t\tstyle: { maxHeight }', 'commands frame class');
  writeFileSync(P('commands', 'client.js'), s, 'utf8');
  console.log('OK ui-commands client.js');
}

console.log('ALL PATCHES APPLIED');
