defmodule Patchbay.Assist.Request do
  @moduledoc """
  The rules for what an agent asks a paid assist to do, in the one place
  every door reads them from.

  A request names the goal, the site, what "done" looks like, whether the
  site needs a signed-in user, and the calls the agent believes will work.
  Everything is text the agent wrote, so every field is bounded before it is
  frozen into payment terms, and a site is only ever a public `https` name:
  Patchbay will not be pointed at an address inside anybody's network. A site
  that needs a signed-in user is refused here, before any money moves, since
  Patchbay never acts on a third party's account.
  """

  alias Patchbay.Patchbay.CanonicalJSON

  @type request :: %{String.t() => term()}
  @type refusal :: {:invalid, [String.t()]} | :needs_sign_in

  @fields ~w(goal site_url believed_calls sign_in expected_result)

  @max_text_chars 1_000
  @max_site_url_bytes 2_048
  @max_host_bytes 253
  @max_believed_calls 5
  @max_tool_chars 128
  @max_believed_calls_bytes 8 * 1024

  @sign_ins ~w(none unknown required)

  # Names networks keep for themselves, or that never name a public site.
  @reserved_suffixes ~w(.local .localhost .internal .home.arpa .arpa .lan .intranet .corp
                        .test .invalid .example .onion)

  @doc "The fields an assist request takes, and no others."
  @spec fields() :: [String.t()]
  def fields, do: @fields

  @doc """
  The request as the caller wrote it, trimmed and with its believed calls in
  one shape, if it holds only the fields a request takes and each one keeps to
  its rule; otherwise every rule it broke, in the caller's words.
  """
  @spec draft(map()) :: {:ok, request()} | {:error, refusal()}
  def draft(params) when is_map(params) do
    with :ok <- fields_only(params),
         {:ok, goal} <- text("goal", params["goal"]),
         {:ok, expected_result} <- text("expected_result", params["expected_result"]),
         {:ok, site_url} <- site_url(params["site_url"]),
         {:ok, sign_in} <- sign_in(params["sign_in"]),
         {:ok, believed_calls} <- believed_calls(params["believed_calls"]) do
      {:ok,
       %{
         "goal" => goal,
         "site_url" => site_url,
         "believed_calls" => believed_calls,
         "sign_in" => sign_in,
         "expected_result" => expected_result
       }}
    end
  end

  @doc "The host a request's site URL names."
  @spec host(request()) :: String.t()
  def host(%{"site_url" => site_url}), do: URI.parse(site_url).host

  defp fields_only(params) do
    case params |> Map.keys() |> Kernel.--(@fields) |> Enum.sort() do
      [] -> :ok
      unknown -> {:error, {:invalid, Enum.map(unknown, &unknown_field/1)}}
    end
  end

  defp unknown_field(field) do
    "#{field}: an assist request does not take #{field}. " <>
      "It takes goal, site_url, believed_calls, sign_in and expected_result."
  end

  defp text(field, value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:error, {:invalid, [text_rule(field)]}}
      String.length(trimmed) > @max_text_chars -> {:error, {:invalid, [text_rule(field)]}}
      not String.valid?(trimmed) -> {:error, {:invalid, [text_rule(field)]}}
      true -> {:ok, trimmed}
    end
  end

  defp text(field, _value), do: {:error, {:invalid, [text_rule(field)]}}

  defp text_rule(field), do: "#{field}: must be text of at most #{@max_text_chars} characters"

  @site_rule "site_url: must be a public https address, such as \"https://example.com/app\""

  # Only the standard port: a site is a public https name, never a port on it.
  defp site_url(value) when is_binary(value) do
    trimmed = String.trim(value)

    with true <- byte_size(trimmed) <= @max_site_url_bytes,
         {:ok, %URI{scheme: "https", host: host, userinfo: nil, port: 443}} <- URI.new(trimmed),
         true <- public_host?(host) do
      {:ok, trimmed}
    else
      _not_public -> {:error, {:invalid, [@site_rule]}}
    end
  end

  defp site_url(_value), do: {:error, {:invalid, [@site_rule]}}

  # A public site is named, not addressed: no IP literal, nothing encoded,
  # and, once the trailing dot a resolver ignores is dropped, a name with a
  # dot in it that is not one of the names networks keep for themselves.
  defp public_host?(host) when is_binary(host) and host != "" do
    name = host |> String.downcase() |> String.trim_trailing(".")

    byte_size(name) <= @max_host_bytes and not String.contains?(name, "%") and
      not address?(name) and String.contains?(name, ".") and
      not String.ends_with?(name, @reserved_suffixes)
  end

  defp public_host?(_host), do: false

  defp address?(name) do
    case :inet.parse_address(String.to_charlist(String.trim(name, "[]"))) do
      {:ok, _address} -> true
      {:error, _not_an_address} -> false
    end
  end

  defp sign_in(value) when value in @sign_ins do
    if value == "required", do: {:error, :needs_sign_in}, else: {:ok, value}
  end

  defp sign_in(_value),
    do: {:error, {:invalid, ["sign_in: must be one of none, unknown, required"]}}

  defp believed_calls(nil), do: {:ok, []}

  defp believed_calls(calls) when is_list(calls) and length(calls) <= @max_believed_calls do
    with {:ok, shaped} <- shaped_calls(calls) do
      if byte_size(CanonicalJSON.encode(shaped)) <= @max_believed_calls_bytes,
        do: {:ok, shaped},
        else: {:error, {:invalid, ["believed_calls: must be 8 KB or less once encoded"]}}
    end
  rescue
    ArgumentError ->
      {:error, {:invalid, ["believed_calls: arguments must be plain named values"]}}
  end

  defp believed_calls(_calls),
    do:
      {:error,
       {:invalid,
        [
          "believed_calls: must be a list of at most #{@max_believed_calls} calls, " <>
            "each an object with tool and, if known, arguments"
        ]}}

  defp shaped_calls(calls) do
    Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, shaped} ->
      case shaped_call(call) do
        {:ok, one} -> {:cont, {:ok, shaped ++ [one]}}
        {:error, refusal} -> {:halt, {:error, refusal}}
      end
    end)
  end

  defp shaped_call(%{"tool" => tool} = call) when is_binary(tool) do
    trimmed = String.trim(tool)
    arguments = Map.get(call, "arguments", %{})

    cond do
      Map.keys(call) -- ["tool", "arguments"] != [] ->
        {:error, {:invalid, ["believed_calls: each call takes only tool and arguments"]}}

      trimmed == "" or String.length(trimmed) > @max_tool_chars ->
        {:error,
         {:invalid,
          ["believed_calls: tool must be a name of at most #{@max_tool_chars} characters"]}}

      not is_map(arguments) ->
        {:error, {:invalid, ["believed_calls: arguments must be an object of named values"]}}

      true ->
        {:ok, %{"tool" => trimmed, "arguments" => arguments}}
    end
  end

  defp shaped_call(_call),
    do: {:error, {:invalid, ["believed_calls: each call must be an object naming its tool"]}}
end
