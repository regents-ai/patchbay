defmodule Patchbay.WalletBench.PublicRun do
  @moduledoc """
  A bounded, anonymous read of a run's public results on Techtree
  (`/wallet-bench/<id>/results.json`, the record its results download starts
  with). The published pair result supplies the id; neither the browser nor the
  response chooses a host. No cookies, credentials or recorded file bodies are
  read.
  """

  @origin "https://techtree.sh"
  @max_bytes 2_000_000
  @steps ~w(T1a T1b T2 T2-signature T3 T4 T5 return)

  def fetch(run) do
    with {:ok, id} <- Ecto.UUID.cast(run.attempt_id),
         {:ok, %{status: 200, body: body}} when is_binary(body) <-
           Req.get(source_url(id) <> "/results.json",
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

  @doc "Reject a different run or pair, or a record the report cannot show."
  def valid?(report, run) when is_map(report) do
    report["id"] == run.attempt_id and report["harness_id"] == run.harness_id and
      report["wallet_id"] == run.wallet_id and shown?(report)
  end

  def valid?(_report, _run), do: false

  defp shown?(report) do
    text_fields?(
      report,
      ~w(agent wallet_tool status started_at failure model_cost_usd judge_cost_usd)
    ) and
      (is_nil(report["machine"]) or
         text_fields?(report["machine"], ~w(harness_version model reasoning_effort os))) and
      list_of?(report["timeline"], &text_fields?(&1, ~w(at label failure))) and
      list_of?(report["funding"], &text_fields?(&1, ~w(sent state transaction))) and
      list_of?(report["tests"], &step?/1) and length(report["tests"]) <= length(@steps)
  end

  defp step?(step) do
    step["folder"] in @steps and is_binary(step["test"]) and
      text_fields?(
        step,
        ~w(state prompt started_at ended_at seconds model_cost_usd judge_cost_usd failure
           version_installed base_check storage_finding)
      ) and (is_nil(step["ruling"]) or ruling?(step["ruling"])) and
      is_map(step["files"]) and Enum.all?(step["files"], &file?/1)
  end

  defp ruling?(ruling) do
    text_fields?(ruling, ~w(outcome judged_by summary reasoning)) and
      list_of?(ruling["checks"], &text_fields?(&1, ~w(check answer why))) and
      Enum.count_until(ruling["checks"], 10) <= 9
  end

  defp file?({name, %{"bytes" => bytes, "sha256" => sha256}}),
    do: is_binary(name) and is_integer(bytes) and bytes >= 0 and is_binary(sha256)

  defp file?(_file), do: false

  defp list_of?(value, check),
    do: is_list(value) and Enum.all?(value, &(is_map(&1) and check.(&1)))

  defp text_fields?(map, keys) when is_map(map),
    do: Enum.all?(keys, &(is_nil(map[&1]) or is_binary(map[&1])))

  defp text_fields?(_value, _keys), do: false

  def source_url(id), do: @origin <> "/wallet-bench/" <> id

  @doc "File links use the fixed Techtree origin and encoded path segments."
  def file_url(id, folder, name) when is_binary(folder) and is_binary(name) do
    source_url(id) <>
      "/evidence/" <>
      URI.encode(folder, &URI.char_unreserved?/1) <>
      "/" <> URI.encode(name, &URI.char_unreserved?/1)
  end
end
