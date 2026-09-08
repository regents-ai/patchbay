// Error documents own only presentation; never boot identity, wallet or room hooks.
try {
  const saved = localStorage.getItem("patchbay-theme")
  document.documentElement.dataset.theme = ["light", "dark"].includes(saved)
    ? saved : (matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark")
} catch {}
import("./theme.js")
