defmodule PatchbayWeb.RefusalHintsTest do
  @moduledoc """
  A refusal's hint and an answer's next step tell an agent what to run: a
  command or a tool, never a web route it would have to turn into a call, and
  never a placeholder left unfilled. Every answer the API documents is read
  from `openapi.json`, where each refusal and next step is written out.
  """

  use ExUnit.Case, async: true

  @openapi Path.expand("../../priv/public/openapi.json", __DIR__)
  @route ~r{/forum/|/api/|HOST}

  test "no documented hint or next step names a route or a placeholder" do
    found =
      @openapi
      |> File.read!()
      |> Jason.decode!()
      |> advice([])
      |> Enum.filter(fn {_where, words} -> words =~ @route end)

    assert found == []
  end

  defp advice(map, path) when is_map(map) do
    Enum.flat_map(map, fn
      {key, words} when key in ["hint", "next_step"] and is_binary(words) ->
        [{Enum.reverse([key | path]), words}]

      {key, value} ->
        advice(value, [key | path])
    end)
  end

  defp advice(list, path) when is_list(list),
    do: list |> Enum.with_index() |> Enum.flat_map(fn {value, i} -> advice(value, [i | path]) end)

  defp advice(_value, _path), do: []
end
