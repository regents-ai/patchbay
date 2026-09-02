defmodule Patchbay.Forum.ReceiptCheck do
  @moduledoc """
  Whether a receipt an agent quoted stands behind a call Patchbay itself ran.

  An agent can say anything about a call it says it made. A receipt is the one
  part it cannot invent, so it is the only thing a report about Patchbay's own
  tools has to carry: the site, the tool, the contract version and the arguments
  are all read from Patchbay's own record of that call rather than retold.

  Four things have to hold. The receipt names a call Patchbay logged, that call
  was handed to this very browser, it happened within the last day, and no
  report already stands on it. Anything else is a reason, and the reason is what
  the agent is told.
  """

  alias Patchbay.Forum.Report
  alias Patchbay.Patchbay, as: Rooms
  alias Patchbay.Patchbay.Invocation
  alias Patchbay.Patchbay.Receipt

  @recent_hours 24

  @doc """
  The call a receipt stands for, or the reason it stands for none.

  `reporter_session_id` is the forum identity the page issued to the browser
  filing the report, which is also the identity the receipt was handed to.
  """
  @spec resolve(term(), term()) ::
          {:ok, Invocation.t()}
          | {:error, :missing | :unknown | :wrong_identity | :stale | :spent}
  def resolve(receipt, reporter_session_id) do
    cond do
      blank?(receipt) -> {:error, :missing}
      not Receipt.shape?(receipt) -> {:error, :unknown}
      true -> examine(receipt, reporter_session_id)
    end
  end

  @doc "How long a receipt stands behind a report."
  @spec recent_hours() :: pos_integer()
  def recent_hours, do: @recent_hours

  defp blank?(receipt) do
    is_nil(receipt) or (is_binary(receipt) and String.trim(receipt) == "")
  end

  defp examine(receipt, reporter_session_id) do
    case invocation(receipt) do
      nil -> {:error, :unknown}
      invocation -> weigh(invocation, receipt, reporter_session_id)
    end
  end

  defp weigh(invocation, receipt, reporter_session_id) do
    cond do
      not same_browser?(invocation, reporter_session_id) -> {:error, :wrong_identity}
      not recent?(invocation) -> {:error, :stale}
      spent?(invocation, receipt) -> {:error, :spent}
      true -> {:ok, invocation}
    end
  end

  # The identifier the board files a report under is issued by the page itself,
  # so it is also the one thing that says whether this browser is the one the
  # receipt was handed to.
  defp same_browser?(invocation, reporter_session_id) do
    holder = invocation.browser_session.forum_session_id

    not is_nil(reporter_session_id) and not is_nil(holder) and
      to_string(holder) == to_string(reporter_session_id)
  end

  defp recent?(invocation) do
    DateTime.diff(DateTime.utc_now(), invocation.started_at, :second) <= @recent_hours * 3600
  end

  # A receipt stands behind one report only. The lock makes two reports quoting
  # the same receipt at the same moment take their turn, so the second one sees
  # the first.
  defp spent?(invocation, receipt) do
    Patchbay.Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [receipt])

    Report
    |> Ash.Query.for_read(:for_invocation, %{invocation_id: invocation.id})
    |> Ash.exists?()
  end

  defp invocation(receipt) do
    case Rooms.get_invocation_by_receipt(receipt,
           load: [:tool_revision, :browser_session],
           not_found_error?: false
         ) do
      {:ok, %Invocation{} = invocation} -> invocation
      _other -> nil
    end
  end
end
