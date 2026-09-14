const root = document.documentElement;
// Browser storage can be unavailable; controls should still work for this page.
const readPreference = (key: string): string | null => {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
};
const writePreference = (key: string, value: string) => {
  try {
    localStorage.setItem(key, value);
  } catch {
    // The visible preference is already applied; persistence is optional.
  }
};
const storedTheme = readPreference("mactools-theme");
const storedLang = readPreference("mactools-lang");
const applyLanguage = (lang: "zh" | "en") => {
  root.dataset.lang = lang;
  root.lang = lang === "zh" ? "zh-CN" : "en";
};

const syncLocalizedAttributes = () => {
  const language = root.dataset.lang === "en" ? "en" : "zh";
  document.querySelectorAll<HTMLElement>("[data-aria-label-zh][data-aria-label-en]").forEach((element) => {
    element.setAttribute("aria-label", language === "en" ? element.dataset.ariaLabelEn ?? "" : element.dataset.ariaLabelZh ?? "");
  });
};

if (storedTheme === "dark" || storedTheme === "light") {
  root.dataset.theme = storedTheme;
} else if (window.matchMedia("(prefers-color-scheme: dark)").matches) {
  root.dataset.theme = "dark";
}

if (storedLang === "zh" || storedLang === "en") {
  applyLanguage(storedLang);
} else {
  const browserLanguages = navigator.languages?.length ? navigator.languages : [navigator.language];
  const prefersChinese = browserLanguages.some((language) => language.toLowerCase().startsWith("zh"));
  applyLanguage(prefersChinese ? "zh" : "en");
}

syncLocalizedAttributes();
new MutationObserver(syncLocalizedAttributes).observe(root, { attributes: true, attributeFilter: ["data-lang"] });

document.querySelectorAll<HTMLElement>("[data-copy]").forEach((button) => {
  const initialMarkup = button.innerHTML;
  let resetTimer: number | undefined;

  const showCopyStatus = (message: string) => {
    window.clearTimeout(resetTimer);
    button.textContent = message;
    resetTimer = window.setTimeout(() => {
      button.innerHTML = initialMarkup;
    }, 1600);
  };

  button.addEventListener("click", async () => {
    const value = button.dataset.copy;
    if (!value) return;

    try {
      await navigator.clipboard.writeText(value);
      showCopyStatus(root.dataset.lang === "en" ? "Copied" : "已复制");
    } catch {
      showCopyStatus(root.dataset.lang === "en" ? "Failed" : "失败");
    }
  });
});

document.querySelector<HTMLElement>("[data-theme-toggle]")?.addEventListener("click", () => {
  const next = root.dataset.theme === "dark" ? "light" : "dark";
  root.dataset.theme = next;
  writePreference("mactools-theme", next);
});

document.querySelector<HTMLElement>("[data-language-toggle]")?.addEventListener("click", () => {
  const next = root.dataset.lang === "en" ? "zh" : "en";
  applyLanguage(next);
  writePreference("mactools-lang", next);
});

const pluginFilterButtons = [...document.querySelectorAll<HTMLButtonElement>("[data-plugin-filter]")];
const pluginCards = [...document.querySelectorAll<HTMLElement>("[data-plugin-category]")];

if (pluginFilterButtons.length && pluginCards.length) {
  const availableFilters = new Set(pluginFilterButtons.map((button) => button.dataset.pluginFilter));

  const applyPluginFilter = (filter: string) => {
    const selectedFilter = availableFilters.has(filter) ? filter : "all";

    for (const button of pluginFilterButtons) {
      button.setAttribute("aria-pressed", String(button.dataset.pluginFilter === selectedFilter));
    }

    for (const card of pluginCards) {
      const isVisible = selectedFilter === "all" || card.dataset.pluginCategory === selectedFilter;
      card.hidden = !isVisible;
    }
  };

  for (const button of pluginFilterButtons) {
    button.addEventListener("click", () => {
      const filter = button.dataset.pluginFilter ?? "all";
      applyPluginFilter(filter);

      if (filter === "all") {
        history.replaceState(null, "", `${location.pathname}${location.search}`);
      } else {
        history.replaceState(null, "", `#${filter}`);
      }
    });
  }

  applyPluginFilter(location.hash.replace(/^#/, "") || "all");
  window.addEventListener("hashchange", () => {
    applyPluginFilter(location.hash.replace(/^#/, "") || "all");
  });
}
