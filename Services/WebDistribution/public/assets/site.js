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
    "/releases/1.0.2/": {
      zh: "AetherRoute 1.0.2 正式稳定版",
      en: "AetherRoute 1.0.2 Production Stable"
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

    if (typeof updateShowcase === "function") {
      updateShowcase(value);
    }
  }

  document.querySelectorAll("[data-language-toggle]").forEach((button) => {
    button.addEventListener("click", () => {
      apply(root.dataset.language === "zh" ? "en" : "zh");
    });
  });

  // Showcase Tab Switcher
  const showcaseTabs = {
    overview: {
      zh: { src: "/assets/aetherroute-overview-zh.png", title: "AetherRoute — 概览", alt: "AetherRoute 中文深色模式真实概览界面，显示透明代理、规则路由、当前出口、延迟和实时流量" },
      en: { src: "/assets/aetherroute-overview-en.png", title: "AetherRoute — Overview", alt: "The real AetherRoute overview in English and light appearance, showing TUN, Rule routing, current route, latency, and live traffic" }
    },
    proxies: {
      zh: { src: "/assets/aetherroute-proxies-zh.png", title: "AetherRoute — 节点与测速", alt: "AetherRoute 中文节点策略组与延迟测速真实界面" },
      en: { src: "/assets/aetherroute-proxies-en.png", title: "AetherRoute — Proxies", alt: "AetherRoute real proxies and latency testing interface" }
    },
    connections: {
      zh: { src: "/assets/aetherroute-connections-zh.png", title: "AetherRoute — 实时连接追踪", alt: "AetherRoute 中文实时连接与分流详情真实界面" },
      en: { src: "/assets/aetherroute-connections-en.png", title: "AetherRoute — Live Connections", alt: "AetherRoute real active connections interface" }
    },
    profiles: {
      zh: { src: "/assets/aetherroute-profiles-zh.png", title: "AetherRoute — 配置与订阅", alt: "AetherRoute 中文配置管理与加密库真实界面" },
      en: { src: "/assets/aetherroute-profiles-en.png", title: "AetherRoute — Profiles", alt: "AetherRoute real profiles interface" }
    },
    settings: {
      zh: { src: "/assets/aetherroute-settings-zh.png", title: "AetherRoute — 系统与引擎偏好", alt: "AetherRoute 中文设置真实界面" },
      en: { src: "/assets/aetherroute-settings-en.png", title: "AetherRoute — Engine & Settings", alt: "AetherRoute real settings interface" }
    }
  };
  let currentShowcaseTab = "overview";

  function updateShowcase(lang) {
    const tabInfo = showcaseTabs[currentShowcaseTab]?.[lang];
    if (!tabInfo) return;
    const img = document.getElementById("showcase-img");
    const title = document.getElementById("showcase-window-title");
    if (img) {
      img.style.opacity = "0.4";
      setTimeout(() => {
        img.src = tabInfo.src;
        img.alt = tabInfo.alt;
        img.setAttribute(`data-src-${lang}`, tabInfo.src);
        img.setAttribute(`data-alt-${lang}`, tabInfo.alt);
        img.style.opacity = "1";
      }, 100);
    }
    if (title) {
      title.textContent = tabInfo.title;
    }
  }

  document.querySelectorAll(".stage-tab").forEach((tabBtn) => {
    tabBtn.addEventListener("click", () => {
      const target = tabBtn.getAttribute("data-target-tab");
      if (!target || !showcaseTabs[target]) return;
      currentShowcaseTab = target;
      document.querySelectorAll(".stage-tab").forEach(b => {
        b.classList.remove("active");
        b.setAttribute("aria-selected", "false");
      });
      tabBtn.classList.add("active");
      tabBtn.setAttribute("aria-selected", "true");
      updateShowcase(root.dataset.language || "zh");
    });
  });

  // SHA Checksum Capsule Click to Copy
  document.querySelectorAll(".sha-capsule").forEach((capsule) => {
    capsule.addEventListener("click", async () => {
      const checksum = capsule.getAttribute("data-checksum");
      if (!checksum) return;
      try {
        await navigator.clipboard.writeText(checksum);
        const actionEl = capsule.querySelector(".copy-text");
        const isZh = root.dataset.language === "zh";
        if (actionEl) {
          actionEl.textContent = isZh ? "已复制 ✓" : "Copied ✓";
        }
        capsule.style.borderColor = "var(--emerald)";
        setTimeout(() => {
          if (actionEl) {
            actionEl.textContent = isZh ? "复制校验和" : "Copy Checksum";
          }
          capsule.style.borderColor = "";
        }, 1600);
      } catch (_) {}
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
