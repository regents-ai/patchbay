defmodule PatchbayWeb.ApiDescription do
  @moduledoc """
  The API description as one of Patchbay's two addresses serves it
  (`PatchbayWeb.SiteEdition`), from the one file `priv/public/openapi.json`.

  An object in that file may carry `x-open`, beside what it describes. Neither
  address serves the marker itself:

    * `"x-open": false` leaves the object out of the open address's document:
      a schema, a property, a parameter, an example. A property left out is
      also dropped from its schema's `required`.
    * `"x-open": {...}` gives the keys that read differently at the open
      address, such as a `description`; `null` is a key it has none of.

  patchbay.help's document is the file without its markers.
  """

  @marker "x-open"

  @doc "The decoded description (`objects: :ordered_objects`) as `edition`'s address serves it."
  @spec for_edition(term(), :main | :open) :: term()
  def for_edition(%Jason.OrderedObject{values: values} = object, edition) do
    values = worded(values, edition)
    left_out = left_out_properties(values, edition)

    %{
      object
      | values:
          for {key, value} <- values, offered?(value, edition) do
            {key, described(key, value, left_out, edition)}
          end
    }
  end

  def for_edition(list, edition) when is_list(list),
    do: for(item <- list, offered?(item, edition), do: for_edition(item, edition))

  def for_edition(value, _edition), do: value

  defp described("required", names, left_out, _edition) when is_list(names),
    do: names -- left_out

  defp described(_key, value, _left_out, edition), do: for_edition(value, edition)

  defp offered?(%Jason.OrderedObject{values: values}, :open),
    do: not match?({@marker, false}, List.keyfind(values, @marker, 0))

  defp offered?(_value, _edition), do: true

  # An object's own keys without its marker; at the open address, with the
  # marker's words in place of the shared ones.
  defp worded(values, edition) do
    case List.keytake(values, @marker, 0) do
      {{@marker, %Jason.OrderedObject{values: open}}, shared} when edition == :open ->
        Enum.reduce(open, shared, fn
          {key, nil}, values -> List.keydelete(values, key, 0)
          {key, value}, values -> List.keystore(values, key, 0, {key, value})
        end)

      {_marker, shared} ->
        shared

      nil ->
        values
    end
  end

  defp left_out_properties(values, edition) do
    case List.keyfind(values, "properties", 0) do
      {"properties", %Jason.OrderedObject{values: properties}} ->
        for {name, schema} <- properties, not offered?(schema, edition), do: name

      _none ->
        []
    end
  end
end
