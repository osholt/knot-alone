(() => {
  const storageKey = "tide-and-seek-theme-v1";
  const validThemes = new Set(["light", "dark"]);

  function preferredTheme() {
    try {
      const saved = localStorage.getItem(storageKey);
      if (validThemes.has(saved)) return saved;
    } catch {
      // A theme still works when browser storage is disabled.
    }
    return window.matchMedia?.("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }

  function applyTheme(theme, persist = true) {
    document.documentElement.dataset.theme = theme;
    document.documentElement.style.colorScheme = theme;
    document.querySelector('meta[name="theme-color"]')
      ?.setAttribute("content", theme === "dark" ? "#071b23" : "#092f3d");
    for (const button of document.querySelectorAll("[data-theme-choice]")) {
      const selected = button.dataset.themeChoice === theme;
      button.setAttribute("aria-pressed", String(selected));
      button.classList.toggle("selected", selected);
    }
    if (persist) {
      try {
        localStorage.setItem(storageKey, theme);
      } catch {
        // Keep the selected theme for this page even if it cannot be saved.
      }
    }
    window.dispatchEvent(new CustomEvent("tideandseekthemechange", { detail: { theme } }));
  }

  applyTheme(preferredTheme(), false);
  for (const button of document.querySelectorAll("[data-theme-choice]")) {
    button.addEventListener("click", () => {
      applyTheme(button.dataset.themeChoice);
    });
  }
})();
