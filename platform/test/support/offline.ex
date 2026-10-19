defmodule PatchbayTest.Offline do
  @moduledoc """
  The test suite never leaves the machine. Every request a test makes through Req
  without a stub comes here (config/test.exs): one to this machine goes ahead, and
  any other is recorded and refused by raising, and test/test_helper.exs fails the
  run if anything was recorded, so a request from a background process fails the
  run too.
  """

  @this_machine ["127.0.0.1", "localhost", "::1"]
  @table :patchbay_outside_requests

  @doc "Starts recording; test/test_helper.exs calls it before the tests run."
  def start, do: :ets.new(@table, [:named_table, :public, :bag])

  @doc "Every request refused so far, as `METHOD scheme://host/path`."
  def refused, do: @table |> :ets.tab2list() |> Enum.map(&elem(&1, 1)) |> Enum.sort()

  def run(%Req.Request{url: %URI{host: host}} = request) when host in @this_machine,
    do: Req.Finch.run(request)

  def run(%Req.Request{method: method, url: url}) do
    outside = "#{method |> to_string() |> String.upcase()} #{url.scheme}://#{url.host}#{url.path}"
    :ets.insert(@table, {:refused, outside})
    raise "a test reached outside this machine: #{outside}"
  end
end
