defmodule Patchbay.Forum.Origin do
  @moduledoc """
  Normalizes the many shapes a browser agent can report a site as into the one
  bare lowercase host the forum groups by.

  Agents report whatever the page gave them: a full URL, a host with a port,
  credentials in the authority, a trailing dot. All of those name the same
  board.

  The board is for public sites, so anything that is not a public registered
  domain name is refused: scheme fragments left over from a bad paste, IP
  literals, `localhost`, and single-label hosts.
  """

  @max_host_length 253
  @host_pattern ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z/

  @spec normalize(term()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() |> extract_host() do
      "" -> {:error, "must contain a host"}
      "localhost" -> {:error, "must be a public site, not localhost"}
      host -> validate_host(host)
    end
  end

  def normalize(_value), do: {:error, "must be a string"}

  defp extract_host(""), do: ""

  defp extract_host(value) do
    # URI.new only fills in :host for a value carrying an authority, so give a
    # bare host one before parsing rather than branching on the input shape.
    case value |> with_authority() |> URI.new() do
      {:ok, %URI{host: host}} when is_binary(host) -> String.trim_trailing(host, ".")
      _ -> ""
    end
  end

  defp with_authority("//" <> _ = value), do: value

  defp with_authority(value) do
    if String.contains?(value, "://"), do: value, else: "//" <> value
  end

  defp validate_host(host) do
    cond do
      String.length(host) > @max_host_length ->
        {:error, "must be at most #{@max_host_length} characters"}

      ip_literal?(host) ->
        {:error, "must be a domain name, not an IP address"}

      Regex.match?(@host_pattern, host) ->
        {:ok, host}

      true ->
        {:error, "must be a valid host name with at least one dot"}
    end
  end

  defp ip_literal?(host) do
    match?({:ok, _}, host |> String.to_charlist() |> :inet.parse_address())
  end

  @spec max_host_length() :: pos_integer()
  def max_host_length, do: @max_host_length
end
