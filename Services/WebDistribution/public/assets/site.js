(() => {
  const root = document.documentElement;
  const key = "aetherroute-language";
  const titles = {
    "/": {
      zh: "AetherRoute — 为 Mac 与 iPhone 精心设计的私密路由",
      en: "AetherRoute — Private routing for Mac and iPhone"
    },
    "/releases/": {
      zh: "版本与更新日志 — AetherRoute",
      en: "Releases and changelog — AetherRoute"
    },
    "/releases/1.0.24/": {zh: "AetherRoute 1.0.24 正式版", en: "AetherRoute 1.0.24 Release"},
    "/releases/1.0.23/": {zh: "AetherRoute 1.0.23 正式版", en: "AetherRoute 1.0.23 Release"},
    "/releases/1.0.22/": {zh: "AetherRoute 1.0.22 正式版", en: "AetherRoute 1.0.22 Release"},
    "/releases/1.0.21/": {zh: "AetherRoute 1.0.21 正式版", en: "AetherRoute 1.0.21 Release"},
    "/releases/1.0.20/": {zh: "AetherRoute 1.0.20 正式版", en: "AetherRoute 1.0.20 Release"},
    "/releases/1.0.19/": {zh: "AetherRoute 1.0.19 正式版", en: "AetherRoute 1.0.19 Release"},
    "/releases/1.0.18/": {zh: "AetherRoute 1.0.18 正式版", en: "AetherRoute 1.0.18 Release"},
    "/releases/1.0.17/": {zh: "AetherRoute 1.0.17 正式版", en: "AetherRoute 1.0.17 Release"},
    "/releases/1.0.16/": {zh: "AetherRoute 1.0.16 正式版", en: "AetherRoute 1.0.16 Release"},
    "/releases/1.0.15/": {zh: "AetherRoute 1.0.15 正式版", en: "AetherRoute 1.0.15 Release"},
    "/releases/1.0.14/": {zh: "AetherRoute 1.0.14 正式版", en: "AetherRoute 1.0.14 Release"},
    "/releases/1.0.13/": {zh: "AetherRoute 1.0.13 正式版", en: "AetherRoute 1.0.13 Release"},
    "/releases/1.0.12/": {zh: "AetherRoute 1.0.12 正式版", en: "AetherRoute 1.0.12 Release"},
    "/releases/1.0.11/": {zh: "AetherRoute 1.0.11 正式版", en: "AetherRoute 1.0.11 Release"},
    "/releases/1.0.10/": {zh: "AetherRoute 1.0.10 正式版", en: "AetherRoute 1.0.10 Release"},
    "/releases/1.0.9/": {zh: "AetherRoute 1.0.9 正式版", en: "AetherRoute 1.0.9 Release"},
    "/releases/1.0.8/": {zh: "AetherRoute 1.0.8 正式版", en: "AetherRoute 1.0.8 Release"},
    "/releases/1.0.7/": {zh: "AetherRoute 1.0.7 正式版", en: "AetherRoute 1.0.7 Release"},
    "/releases/1.0.6/": {zh: "AetherRoute 1.0.6 正式版", en: "AetherRoute 1.0.6 Release"},
    "/releases/1.0.5/": {zh: "AetherRoute 1.0.5 正式版", en: "AetherRoute 1.0.5 Release"},
    "/releases/1.0.4/": {
      zh: "AetherRoute 1.0.4 正式版",
      en: "AetherRoute 1.0.4 Release"
    },
    "/releases/1.0.3/": {
      zh: "AetherRoute 1.0.3 正式版",
      en: "AetherRoute 1.0.3 Release"
    },
    "/releases/1.0.2/": {
      zh: "AetherRoute 1.0.2 稳定版",
      en: "AetherRoute 1.0.2 Stable"
    },
    "/releases/1.0.1/": {
      zh: "AetherRoute 1.0.1 正式稳定版",
      en: "AetherRoute 1.0.1 Production Stable"
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
  const views = {
    overview: { zh: "概览", en: "Overview" },
    proxies: { zh: "节点管理", en: "Proxies" },
    connections: { zh: "实时连接", en: "Connections" },
    settings: { zh: "主题设置", en: "Appearance" },
    dark: { zh: "深色外观", en: "Dark mode" }
  };
  let currentView = "overview";
  function updateShowcase(language) {
    const image = document.getElementById("showcase-img");
    if (!image) return;
    image.src = `/assets/aetherroute-${currentView}-${language}.png?v=20260914.08`;
    image.width = currentView === "settings" ? 1920 : 2290;
    image.height = currentView === "settings" ? 1344 : 1312;
    const original = document.getElementById("showcase-original");
    if (original) original.href = image.src;
    image.alt = `AetherRoute — ${views[currentView][language]}`;
  }
  function apply(language) {
    const value = language === "en" ? "en" : "zh";
    root.dataset.language = value;
    root.lang = value === "zh" ? "zh-Hans" : "en";
    try { localStorage.setItem(key, value); } catch (_) {}
    const path = window.location.pathname.replace(/index\.html$/, "");
    document.title = titles[path]?.[value] || document.title;
    document.querySelectorAll("[data-localized-image]").forEach(image => {
      const source = image.getAttribute(`data-src-${value}`);
      const alt = image.getAttribute(`data-alt-${value}`);
      if (source) image.src = source;
      if (alt) image.alt = alt;
    });
    document.querySelectorAll("[data-language-toggle]").forEach(button => {
      button.textContent = value === "zh" ? "EN" : "中文";
      button.setAttribute("aria-label", value === "zh" ? "Switch to English" : "切换到中文");
    });
    updateShowcase(value);
  }
  document.querySelectorAll("[data-language-toggle]").forEach(button => {
    button.addEventListener("click", () => apply(root.dataset.language === "zh" ? "en" : "zh"));
  });
  const viewButtons = [...document.querySelectorAll(".stage-tab")];
  viewButtons.forEach((button, index) => button.addEventListener("click", () => {
    if (!views[button.dataset.targetTab]) return;
    currentView = button.dataset.targetTab;
    viewButtons.forEach(item => item.setAttribute("aria-pressed", String(item === button)));
    updateShowcase(root.dataset.language);
    const number = document.querySelector(".stage-number");
    if (number) number.textContent = `${String(index + 1).padStart(2, "0")} / ${String(viewButtons.length).padStart(2, "0")}`;
  }));
  document.querySelectorAll(".checksum").forEach(block => {
    if (block.tagName !== "BUTTON") {
      block.setAttribute("role", "button");
      block.tabIndex = 0;
      block.addEventListener("keydown", event => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          block.click();
        }
      });
    }
    const status = document.createElement("p");
    status.className = "copy-feedback";
    status.setAttribute("role", "status");
    block.after(status);
    block.addEventListener("click", async () => {
      const zh = root.dataset.language === "zh";
      try {
        await navigator.clipboard.writeText(block.dataset.copy || block.textContent.trim());
        status.textContent = zh ? "已复制" : "Copied";
      } catch (_) {
        status.textContent = zh ? "请选中文字手动复制" : "Please select the text and copy it manually.";
      }
    });
  });
  document.querySelectorAll(".navlinks a, .site-footer a").forEach(link => {
    if (link.pathname === location.pathname && !link.hash) link.setAttribute("aria-current", "page");
  });
  let preferred;
  try { preferred = localStorage.getItem(key); } catch (_) {}
  apply(preferred || (navigator.language.toLowerCase().startsWith("zh") ? "zh" : "en"));
})();
