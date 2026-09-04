defmodule PatchbayWeb.MarkdownEncoder do
  @moduledoc false

  def encode_to_iodata!(data) when is_binary(data), do: data
  def encode_to_iodata!(data) when is_list(data), do: data
end
