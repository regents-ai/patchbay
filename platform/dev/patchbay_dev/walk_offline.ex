defmodule PatchbayDev.WalkOffline do
  @moduledoc """
  The browser walk's server never leaves the machine. With `PATCHBAY_WALK` set
  (assets/playwright.config.ts), every request the server makes through Req comes
  here first: one to this machine goes ahead, and any other is written to this run's
  list of outside requests and refused by raising, so the walk fails at its end
  (assets/test/browser/support/teardown.ts), whichever page caused it.
  No name outside this machine resolves (`:assist_target`), so looking at a
  site's tools, a site's check and refresh, Offers screening and Jev's work
  find the site unreachable without asking the outside resolver.
  """

  @this_machine ["127.0.0.1", "localhost", "::1"]

  @doc "No name outside this machine resolves."
  def resolve(_host), do: []

  def run(%Req.Request{url: %URI{host: host}} = request) when host in @this_machine,
    do: Req.Finch.run(request)

  def run(%Req.Request{method: method, url: url}) do
    outside = "#{method |> to_string() |> String.upcase()} #{url.scheme}://#{url.host}#{url.path}"

    File.write!(
      Application.fetch_env!(:patchbay, :walk_outside_file),
      outside <> "\n",
      [:append]
    )

    raise "the browser walk refused a request outside this machine: #{outside}"
  end
end
