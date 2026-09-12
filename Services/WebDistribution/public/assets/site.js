(() => {
  const root = document.documentElement;
  const key = "aetherroute-language";
  const titles = {
    "/": {
      zh: "AetherRoute — 为 Mac 精心设计的私密路由",
      en: "AetherRoute — Private routing, designed for Mac"
    },
    "/releases/": {
      zh: "版本与更新日志 — AetherRoute",
      en: "Releases and changelog — AetherRoute"
    },
    "/releases/1.0.0/": {
      zh: "AetherRoute 1.0.0 正式稳定版",
      en: "AetherRoute 1.0.0 Production Stable"
    },
    "/releases/0.1.0-preview/": {
      zh: "AetherRoute 0.1.0 技术预览",
      en: "AetherRoute 0.1.0 Technical Preview"
    },
    "/privacy/": { zh: "隐私 — AetherRoute", en: "Privacy — AetherRoute" },
    "/support/": { zh: "支持 — AetherRoute", en: "Support — AetherRoute" },
    "/license/": { zh: "软件许可 — AetherRoute", en: "Software License — AetherRoute" },
    "/404.html": { zh: "未找到 — AetherRoute", en: "Not Found — AetherRoute" }
  };

  let saved = null;
  try {
    saved = localStorage.getItem(key);
  } catch (_) {
    saved = null;
  }
  const preferred = saved || (navigator.language.toLowerCase().startsWith("zh") ? "zh" : "en");

  function apply(language) {
    const value = language === "en" ? "en" : "zh";
    root.dataset.language = value;
    root.lang = value === "zh" ? "zh-Hans" : "en";
    try {
      localStorage.setItem(key, value);
    } catch (_) {
      // Language switching remains functional when storage is unavailable.
    }
    let localizedTitle = titles[window.location.pathname]?.[value];
    if (!localizedTitle) {
      const release = window.location.pathname.match(
        /^\/releases\/([0-9]+\.[0-9]+(?:\.[0-9]+)?)\/$/
      );
      if (release) localizedTitle = `AetherRoute ${release[1]}`;
    }
    if (localizedTitle) document.title = localizedTitle;

    document.querySelectorAll("[data-localized-image]").forEach((image) => {
      const source = image.getAttribute(`data-src-${value}`);
      const alternative = image.getAttribute(`data-alt-${value}`);
      if (source && image.getAttribute("src") !== source) {
        image.setAttribute("src", source);
      }
      if (alternative) image.setAttribute("alt", alternative);
    });

    document.querySelectorAll("[data-language-toggle]").forEach((button) => {
      button.textContent = value === "zh" ? "EN" : "中文";
      button.setAttribute(
        "aria-label",
        value === "zh" ? "Switch to English" : "切换到中文"
      );
    });
  }

  document.querySelectorAll("[data-language-toggle]").forEach((button) => {
    button.addEventListener("click", () => {
      apply(root.dataset.language === "zh" ? "en" : "zh");
    });
  });

  // Checksum copy click helper
  document.querySelectorAll(".checksum").forEach((block) => {
    block.style.cursor = "pointer";
    block.title = "Click to copy / 点击复制";
    block.addEventListener("click", async () => {
      const text = block.textContent.trim();
      try {
        await navigator.clipboard.writeText(text);
        const originalBg = block.style.borderColor;
        block.style.borderColor = "var(--emerald)";
        setTimeout(() => {
          block.style.borderColor = originalBg;
        }, 1200);
      } catch (_) {}
    });
  });

  apply(preferred);
})();
