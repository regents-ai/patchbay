defmodule Patchbay.Assist.KnownFixes do
  @moduledoc """
  The fixes Patchbay already knows, one Markdown file each in
  `priv/known_fixes` named by the fix's id (`Patchbay.Assist.KnownFix`),
  read at compile time. Jev chooses among them; it never writes one.
  """

  alias Patchbay.Assist.KnownFix
  alias Patchbay.Forum.Origin

  @directory "priv/known_fixes"

  @paths @directory |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".md")) |> Enum.sort()
  for path <- @paths, do: @external_resource(Path.join(@directory, path))
  # A file added or removed recompiles the catalog too.
  @external_resource @directory

  @fixes Enum.map(@paths, fn path ->
           KnownFix.parse!(Path.rootname(path), File.read!(Path.join(@directory, path)))
         end)

  @doc "Every known fix, by id."
  @spec all() :: [KnownFix.t()]
  def all, do: @fixes

  @doc "The known fix with `id`, if there is one."
  @spec get(String.t()) :: KnownFix.t() | nil
  def get(id), do: Enum.find(@fixes, &(&1.id == id))

  @doc """
  The known fixes for the site an address or host belongs to. A fix names
  its sites as registrable domains (`Patchbay.Forum.Origin`), so a fix for
  `regents.sh` is a fix for `siwa.regents.sh` too.
  """
  @spec for_site(String.t()) :: [KnownFix.t()]
  def for_site(address) do
    case Origin.normalize(address) do
      {:ok, domain} -> Enum.filter(@fixes, &(domain in &1.sites))
      {:error, _not_a_site} -> []
    end
  end
end
