defmodule Patchbay.Forum.Validations.SourceLinks do
  @moduledoc """
  Every link in a list attribute is a web address a reader can open as it
  is: it parses, it is `https` or `http`, it names a host, it carries no
  user name or password before the host (a source never carries
  credentials), and it holds no space and none of `<`, `>`, `"` or `'`,
  which would end the link early wherever it is written into a page or a
  feed.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @message "each must be a whole https or http link with a host, no user name or password, and no spaces or < > \" '"

  @impl true
  def init(opts) do
    case opts[:attribute] do
      attribute when is_atom(attribute) and not is_nil(attribute) -> {:ok, opts}
      _ -> {:error, "`:attribute` is required"}
    end
  end

  @impl true
  def validate(changeset, opts, _context) do
    links = Ash.Changeset.get_attribute(changeset, opts[:attribute]) || []

    if Enum.all?(links, &link?/1),
      do: :ok,
      else: {:error, InvalidAttribute.exception(field: opts[:attribute], message: @message)}
  end

  @impl true
  def describe(_opts), do: [message: @message, vars: []]

  @doc "Whether one text is a link a reader can open as it is."
  @spec link?(String.t()) :: boolean()
  def link?(text) do
    not String.match?(text, ~r/[\s<>"']/u) and
      match?(
        {:ok, %URI{scheme: scheme, host: host, userinfo: nil}}
        when scheme in ["https", "http"] and is_binary(host) and host != "",
        URI.new(text)
      )
  end
end
