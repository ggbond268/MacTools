export type LocalizedText = { zh: string; en: string };

const labels: Record<string, LocalizedText> = {
  accessibility: { zh: "辅助功能", en: "Accessibility" },
  automation: { zh: "自动化", en: "Automation" },
  calendarFullAccess: { zh: "完整日历访问", en: "Full Calendar Access" },
  inputMonitoring: { zh: "输入监控", en: "Input Monitoring" },
  "screen-recording": { zh: "屏幕录制", en: "Screen Recording" },
  "system-audio-recording": { zh: "系统音频录制", en: "System Audio Recording" },
  "unified-search": { zh: "统一搜索", en: "Unified Search" },
  "global-shortcut": { zh: "全局快捷键", en: "Global Shortcut" },
  "run-link": { zh: "运行链接", en: "Run Link" },
  workflow: { zh: "工作流", en: "Workflow" },
  "automatic-rule": { zh: "自动规则", en: "Automatic Rule" },
  "action-grid": { zh: "操作面板", en: "Action Grid" },
  "trackpad-gesture": { zh: "触控板手势", en: "Trackpad Gesture" },
  "app-intent": { zh: "App Intent", en: "App Intent" },
  manual: { zh: "手动", en: "Manual" },
  safe: { zh: "安全", en: "Safe" },
  confirmationRequired: { zh: "需要确认", en: "Confirmation Required" },
  none: { zh: "无", en: "None" },
  simple: { zh: "简单", en: "Simple" },
  guided: { zh: "引导式", en: "Guided" },
  advanced: { zh: "高级", en: "Advanced" },
  optional: { zh: "可选", en: "Optional" },
  required: { zh: "必需", en: "Required" },
  session: { zh: "会话期间", en: "Session" },
  "until-disabled": { zh: "直到停用", en: "Until disabled" },
  "until-uninstalled": { zh: "直到卸载", en: "Until uninstalled" },
  "user-controlled": { zh: "由用户控制", en: "User-controlled" },
};

export function localizedToken(token: string): LocalizedText {
  return labels[token] ?? { zh: token, en: token };
}

export function localizedTokenList(tokens: string[]): LocalizedText {
  return {
    zh: tokens.map((token) => localizedToken(token).zh).join("、"),
    en: tokens.map((token) => localizedToken(token).en).join(", "),
  };
}
