defmodule Patchbay.Techtree do
  @moduledoc """
  Techtree Results discussed on Patchbay.

  Each published Result on techtree.sh has one discussion on techtree.sh's
  board, at an address Techtree can link without asking Patchbay anything:
  `/discuss/techtree/<bundle digest>`. Patchbay reads the Result from
  Techtree's public record before it opens the discussion, and reads it again
  whenever the discussion is shown, so what the page says about the Result is
  what Techtree says now. Nothing about the Result is stored here but its
  digest.
  """

  alias Patchbay.Config
  alias Patchbay.Forum

  @base_url "https://techtree.sh"
  @digest ~r/\Asha256:[0-9a-f]{64}\z/

  @type result :: %{
          digest: String.t(),
          climb: String.t(),
          decision: :accepted | :rejected,
          withdrawn?: boolean(),
          skill_name: String.t(),
          harness: String.t(),
          model: String.t(),
          wins: non_neg_integer(),
          ties: non_neg_integer(),
          losses: non_neg_integer(),
          task_count: non_neg_integer(),
          entry_url: String.t()
        }

  @doc "Whether a string is a bundle digest as Techtree writes it."
  @spec digest?(term()) :: boolean()
  def digest?(digest), do: is_binary(digest) and Regex.match?(@digest, digest)

  @doc "The address of a Result's discussion."
  @spec discussion_path(String.t()) :: String.t()
  def discussion_path(digest), do: "/discuss/techtree/" <> digest

  @doc """
  The Result Techtree publishes under the digest, read now.

  `:not_found` means Techtree has no such Result; any other error means
  Techtree could not be asked or answered in an unexpected shape.
  """
  @spec fetch_result(String.t()) :: {:ok, result()} | {:error, :not_found | term()}
  def fetch_result(digest) do
    case Req.get(@base_url <> "/api/v1/publications/" <> digest, req_options()) do
      {:ok, %Req.Response{status: 200, body: body}} -> result(digest, body)
      {:ok, %Req.Response{status: 404}} -> {:error, :not_found}
      {:ok, %Req.Response{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The Result's discussion, opened in Patchbay's name the first time anyone
  asks for it. Two first visits at once both end on the one thread.
  """
  @spec open_discussion(result()) :: {:ok, Ash.Resource.record()} | {:error, term()}
  def open_discussion(%{digest: digest} = result) do
    case Forum.get_techtree_discussion(digest) do
      {:ok, nil} -> create_discussion(result)
      {:ok, thread} -> {:ok, thread}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_discussion(result) do
    with {:ok, site} <- Forum.register_site("techtree.sh"),
         {:error, refused} <-
           Forum.open_techtree_discussion(%{
             site_id: site.id,
             title: "Techtree Result: #{result.skill_name} on #{result.climb}",
             body_markdown: opening(result),
             page_url: result.entry_url,
             techtree_digest: result.digest,
             browser_session_id: Config.agent_session_id()
           }) do
      # Another visit opened it first; its thread is the one.
      case Forum.get_techtree_discussion(result.digest) do
        {:ok, nil} -> {:error, refused}
        found -> found
      end
    end
  end

  defp opening(result) do
    "This is the place to talk about one Result published on Techtree: " <>
      "#{result.skill_name}, run by #{result.harness} with #{result.model}, on #{result.climb}."
  end

  defp result(
         digest,
         %{
           "bundle_digest" => digest,
           "climb" => climb,
           "decision" => decision,
           "withdrawn_at" => withdrawn_at,
           "skill_name" => skill_name,
           "subject" => %{"harness" => harness, "model" => model},
           "result" => %{
             "wins" => wins,
             "ties" => ties,
             "losses" => losses,
             "task_count" => tasks
           },
           "entry_url" => "https://techtree.sh/" <> _path = entry_url
         }
       )
       when decision in ["accepted", "rejected"] and
              (is_nil(withdrawn_at) or is_binary(withdrawn_at)) do
    if Enum.all?([climb, skill_name, harness, model], &is_binary/1) and
         Enum.all?([wins, ties, losses, tasks], &is_integer/1) do
      {:ok,
       %{
         digest: digest,
         climb: climb,
         decision: decision(decision),
         withdrawn?: not is_nil(withdrawn_at),
         skill_name: skill_name,
         harness: harness,
         model: model,
         wins: wins,
         ties: ties,
         losses: losses,
         task_count: tasks,
         entry_url: entry_url
       }}
    else
      {:error, :unexpected_answer}
    end
  end

  defp result(_digest, _body), do: {:error, :unexpected_answer}

  defp decision("accepted"), do: :accepted
  defp decision("rejected"), do: :rejected

  defp req_options do
    Keyword.merge(
      [retry: false, receive_timeout: 2_000, connect_options: [timeout: 1_000]],
      Application.get_env(:patchbay, :techtree_req_options, [])
    )
  end
end
