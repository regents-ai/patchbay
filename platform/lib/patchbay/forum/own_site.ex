defmodule Patchbay.Forum.OwnSite do
  @moduledoc """
  Patchbay's own site on its board: the domain this deployment is published
  under, which its own tools and the threads about Patchbay file under.
  """

  alias Patchbay.Forum.Origin

  @default_origin "patchbay.help"

  @doc """
  The domain this deployment is published under, and so the site it files under.
  """
  @spec origin() :: String.t()
  def origin do
    case System.get_env("PHX_HOST") do
      value when is_binary(value) and value != "" -> normalize!(value)
      _ -> @default_origin
    end
  end

  defp normalize!(value) do
    case Origin.normalize(value) do
      {:ok, domain} ->
        domain

      {:error, reason} ->
        raise ArgumentError, "PHX_HOST #{inspect(value)} #{reason}"
    end
  end
end
