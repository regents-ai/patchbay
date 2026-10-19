defmodule PatchbayDev.WalkOffline do
  @moduledoc """
  The browser walk's server never leaves the machine. With `PATCHBAY_WALK` set
  (assets/playwright.config.ts), every request the server makes through Req comes
  here first: one to this machine goes ahead, and any other is written to the walk's
  list of outside requests and refused by raising, so the walk fails at its end
  (assets/test/browser/support/teardown.ts), whichever page caused it.
  """

  @this_machine ["127.0.0.1", "localhost", "::1"]

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
