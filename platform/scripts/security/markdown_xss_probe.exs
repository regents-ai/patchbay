# Stored-XSS regression probe for author-written Markdown.
#
# Every forum body, reply, known-fix field and site/tool description that is
# shown as HTML goes through PatchbayWeb.Forum.BoardHTML.markdown/1 (and the
# equivalent markdown_html/1), which render with MDEx `unsafe: false`. This
# asserts that raw HTML, event handlers and scriptable URL schemes written by
# an author never survive into the rendered HTML.
#
# Run:  direnv exec . mix run --no-start scripts/security/markdown_xss_probe.exs

alias PatchbayWeb.Forum.BoardHTML

payloads = [
  ~s|<script>alert(1)</script>|,
  ~s|<img src=x onerror=alert(1)>|,
  ~s|<a href="javascript:alert(1)">x</a>|,
  ~s|[click](javascript:alert(1))|,
  ~s|[click](  javascript:alert(1))|,
  ~s|[click](java\tscript:alert(1))|,
  ~s|<svg/onload=alert(1)>|,
  ~s|<iframe src="data:text/html,<script>alert(1)</script>"></iframe>|,
  ~s|<details open ontoggle=alert(1)>|,
  ~s|normal **bold** [ok](https://example.com) text|,
  ~s|<a href="vbscript:msgbox(1)">x</a>|,
  ~s|![x](javascript:alert(1))|
]

# A rendered fragment is dangerous if it still carries an executable sink.
bad_patterns = [
  ~r/<script/i,
  ~r/<iframe/i,
  ~r/<svg/i,
  ~r/\son\w+\s*=/i,
  ~r/href\s*=\s*["']?\s*javascript:/i,
  ~r/href\s*=\s*["']?\s*vbscript:/i,
  ~r/src\s*=\s*["']?\s*javascript:/i,
  ~r/src\s*=\s*["']?\s*data:text\/html/i
]

defmodule P do
  def render(text) do
    text |> PatchbayWeb.Forum.BoardHTML.markdown() |> Phoenix.HTML.safe_to_string()
  end
end

failed = false

failed =
  Enum.reduce(payloads, failed, fn payload, failed ->
    html = P.render(payload)
    hit = Enum.find(bad_patterns, &Regex.match?(&1, html))

    status = if hit, do: "FAIL", else: "PASS"
    IO.puts([status, "  in:  ", inspect(payload)])
    IO.puts(["      out: ", inspect(html)])
    if hit, do: true, else: failed
  end)

# Confirm the renderer is the hardened one (defence-in-depth sanity on config).
unsafe = BoardHTML.markdown(~s(<b>x</b>)) |> Phoenix.HTML.safe_to_string()
IO.puts("\nraw <b> handling: #{inspect(unsafe)} (should be escaped, not a live tag)")

if failed, do: System.halt(1), else: IO.puts("\nALL PASS")
