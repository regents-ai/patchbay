defmodule Patchbay.WalletBench.PublicRun do
  @moduledoc """
  A bounded, anonymous read of Techtree's public run export. The published pair
  result supplies the identity; neither the browser nor the response chooses a
  host. No cookies, credentials, artifact bodies or private tables are read.
  """

  @origin "https://techtree.sh"
  @max_bytes 2_000_000
  @criteria %{
    "T1a" => 9,
    "T1b" => 9,
    "T2" => 9,
    "T2-signature" => 9,
    "T3" => 5,
    "T4" => 5,
    "T5" => 5,
    "return" => 0
  }

  def fetch(run) do
    with {:ok, id} <- Ecto.UUID.cast(run.attempt_id),
         {:ok, %{status: 200, body: body}} when is_binary(body) <-
           Req.get(@origin <> "/api/wallet-bench/" <> id,
             headers: [{"accept", "application/json"}],
             redirect: false,
             retry: false,
             raw: true,
             compressed: false,
             connect_options: [timeout: 4_000],
             receive_timeout: 8_000,
             request_timeout: 12_000,
             into: &collect/2
           ),
         {:ok, report} <- Jason.decode(body),
         true <- valid?(report, run) do
      {:ok, report}
    else
      _ -> {:error, :unavailable}
    end
  end

  # Req's streaming hook stops the response before an oversized body is kept.
  defp collect({:data, chunk}, {request, response}) do
    body = response.body || ""

    if is_binary(body) and byte_size(body) + byte_size(chunk) <= @max_bytes do
      {:cont, {request, %{response | body: body <> chunk}}}
    else
      {:halt, {request, %{response | body: :too_large}}}
    end
  end

  @doc "Reject a different run, pair, export version or malformed report."
  def valid?(%{"schema_version" => 1} = report, run) do
    report["id"] == run.attempt_id and report["harness_id"] == run.harness_id and
      report["wallet_id"] == run.wallet_id and is_map(report["setup"]) and
      text_fields?(
        report["setup"],
        ~w(harness_name harness_version model reasoning_effort os plan wallet_name survey_wallet_version)
      ) and
      text_fields?(report, ~w(status_label started_at finished_at failure funding_refused)) and
      costs?(report["costs"]) and maps?(report["timeline"]) and
      maps?(report["funding"]) and maps?(report["stages"]) and
      length(report["stages"]) <= map_size(@criteria) and
      Enum.all?(report["stages"], &stage?/1) and
      Enum.all?(report["timeline"], &text_fields?(&1, ~w(at label failure)))
  end

  def valid?(_report, _run), do: false
  defp maps?(value), do: is_list(value) and Enum.all?(value, &is_map/1)

  defp stage?(stage) do
    is_map_key(@criteria, stage["stage"]) and
      stage["criterion_count"] == @criteria[stage["stage"]] and
      stage["criterion_source"] == "current_catalog" and
      is_binary(stage["name"]) and
      text_fields?(stage, ~w(outcome_label summary failure plain_file prompt)) and
      maps?(stage["criteria"]) and Enum.all?(stage["criteria"], &criterion?/1) and
      maps?(stage["evidence"]) and Enum.all?(stage["evidence"], &artifact?/1) and
      text_fields?(stage["timing"], ~w(started_at finished_at duration_seconds)) and
      is_integer(stage["timing"]["limit_seconds"]) and
      stage["timing"]["limit_source"] == "current_catalog" and costs?(stage["costs"]) and
      text_fields?(stage["judge"], ~w(model reasoning)) and
      (is_nil(stage["version"]) or text_fields?(stage["version"], ~w(installed requested survey))) and
      is_map(stage["verification"]) and
      Enum.all?(~w(base money), fn key ->
        value = stage["verification"][key]
        is_nil(value) or text_fields?(value, ["summary"])
      end)
  end

  defp criterion?(check) do
    check["id"] in Enum.map(1..9, &"C#{&1}") and
      check["result"] in [nil, "true", "false", "open"] and
      text_fields?(check, ~w(criterion reason))
  end

  defp artifact?(file),
    do:
      is_binary(file["name"]) and text_fields?(file, ["sha256"]) and
        (is_nil(file["bytes"]) or (is_integer(file["bytes"]) and file["bytes"] >= 0))

  defp costs?(value), do: text_fields?(value, ~w(currency model judge))

  defp text_fields?(map, keys) when is_map(map),
    do: Enum.all?(keys, &(is_nil(map[&1]) or is_binary(map[&1])))

  defp text_fields?(_value, _keys), do: false

  def source_url(id), do: @origin <> "/wallet-bench/" <> id

  @doc "Artifact links use the fixed producer origin and encoded path segments."
  def artifact_url(id, stage, name) when is_binary(stage) and is_binary(name) do
    source_url(id) <>
      "/evidence/" <>
      URI.encode(stage, &URI.char_unreserved?/1) <>
      "/" <> URI.encode(name, &URI.char_unreserved?/1)
  end
end
