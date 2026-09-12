import generatedPluginData from "@/generated/plugins.json";

export type PluginCatalog = {
  generatedAt: string;
  minimumHostVersion: string;
  plugins: Plugin[];
};

export type Plugin = {
  id: string;
  displayName: string;
  summary: string;
  localizedMetadata?: Record<string, PluginLocalizedMetadata | undefined> | null;
  version: string;
  category: string | null;
  releaseChannel?: string | null;
  releaseNotesURL?: string;
  package?: {
    url: string;
    size: number;
  };
  capabilities: {
    primaryPanel: boolean;
    componentPanel: boolean;
    configuration?: boolean;
    settings?: "none" | "form" | "workspace";
  };
  product?: Record<string, unknown>;
  openInMacToolsURL?: string;
  route?: string;
};

export type PluginLocalizedMetadata = {
  displayName?: string | null;
  summary?: string | null;
};

export type PluginLocalizedText = {
  displayName: string;
  summary: string;
};

export async function loadPluginCatalog(): Promise<PluginCatalog> {
  return {
    generatedAt: "repository-generated",
    minimumHostVersion: "",
    plugins: generatedPluginData.plugins as unknown as Plugin[],
  };
}

export function hasPluginSettings(plugin: Plugin): boolean {
  if (plugin.capabilities.settings !== undefined) {
    return plugin.capabilities.settings !== "none";
  }
  return plugin.capabilities.configuration === true;
}

export function categoryLabel(category: string | null): { zh: string; en: string } {
  switch (category) {
    case "display":
      return { zh: "显示与桌面", en: "Display" };
    case "productivity":
      return { zh: "效率", en: "Productivity" };
    case "monitoring":
      return { zh: "监控", en: "Monitoring" };
    case "storage":
      return { zh: "清理与存储", en: "Storage" };
    case "system":
      return { zh: "系统", en: "System" };
    case "audio":
      return { zh: "音频", en: "Audio" };
    default:
      return { zh: "其他", en: "Other" };
  }
}

export function localizedPluginText(plugin: Plugin): { zh: PluginLocalizedText; en: PluginLocalizedText } {
  return {
    zh: textForLocale(plugin, ["zh-Hans", "zh-CN", "zh", "zh-Hant", "zh-TW"]),
    en: textForLocale(plugin, ["en", "en-US", "en-GB"]),
  };
}

function textForLocale(plugin: Plugin, localeCandidates: string[]): PluginLocalizedText {
  const metadata = pickLocalizedMetadata(plugin.localizedMetadata, localeCandidates);
  return {
    displayName: nonEmpty(metadata?.displayName) ?? plugin.displayName,
    summary: nonEmpty(metadata?.summary) ?? plugin.summary,
  };
}

function pickLocalizedMetadata(
  localizedMetadata: Plugin["localizedMetadata"],
  localeCandidates: string[],
): PluginLocalizedMetadata | undefined {
  if (!localizedMetadata) return undefined;

  for (const locale of localeCandidates) {
    const metadata = localizedMetadata[locale];
    if (metadata) return metadata;
  }

  return undefined;
}

function nonEmpty(value?: string | null): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}

export function formatSize(size?: number): string {
  if (!size) return "";
  if (size < 1024 * 1024) return `${Math.round(size / 1024)} KB`;
  return `${(size / 1024 / 1024).toFixed(1)} MB`;
}
