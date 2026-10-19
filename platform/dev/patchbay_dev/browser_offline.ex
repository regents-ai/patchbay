defmodule PatchbayDev.BrowserOffline do
  @moduledoc """
  The browser tests' server never leaves this machine. With
  `PATCHBAY_BROWSER_TEST=1` (config/test.exs), every request the server makes
  through Req comes here first: one to this machine goes ahead, and any other is
  written to the run's list of outside requests and refused by raising, so the
  run fails at its end whichever page made it (assets/test/browser/support/outside.ts).
  A site's name never resolves, so checking a site's tools finds it unreachable
  without asking the outside resolver.
  """

  @this_machine ["127.0.0.1", "localhost", "::1"]

  @doc "No name outside this machine resolves."
  def resolve(_host), do: []

  @doc "Sends a request to this machine; refuses, and records, any other."
  def run(%Req.Request{url: %URI{host: host}} = request) when host in @this_machine,
    do: Req.Finch.run(request)

  def run(%Req.Request{method: method, url: url}) do
    outside = "#{method |> to_string() |> String.upcase()} #{url.scheme}://#{url.host}#{url.path}"

    File.write!(
      Application.fetch_env!(:patchbay, :browser_outside_file),
      outside <> "\n",
      [:append]
    )

    raise "the browser tests refused a request outside this machine: #{outside}"
  end
end
