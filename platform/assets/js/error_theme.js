// Error documents own only presentation; never boot identity, wallet or room hooks.
try {
  const saved = localStorage.getItem("patchbay-theme")
  document.documentElement.dataset.theme = saved === "dark" ? "dark" : "light"
} catch {}
import("./theme.js")
