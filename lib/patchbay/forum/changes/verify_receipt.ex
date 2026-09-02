defmodule Patchbay.Forum.Changes.VerifyReceipt do
  @moduledoc """
  Decides whether a report can be tied to a call Patchbay itself ran.

  An agent can say anything about a call. A receipt is the one part it cannot
  make up, so a report that quotes one is checked against Patchbay's own record
  of that call: the call exists, it was issued to this same browser, it happened
  recently, it was the tool and version the report names on this very site, and
  no earlier report already stands on it.

  When all of that holds the report is marked verified and the facts Patchbay
  logged replace the ones the author supplied, so the record shows what happened
  rather than what was claimed. Otherwise the report is kept exactly as it was
  told, marked unverified, and the reason is recorded.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias Patchbay.Forum
  alias Patchbay.Forum.Report
  alias Patchbay.Forum.RoomMirror
  alias Patchbay.Patchbay, as: Rooms
  alias Patchbay.Patchbay.Invocation
  alias Patchbay.Patchbay.Receipt

  @recent_hours 24

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &decide/1)
  end

  defp decide(changeset) do
    changeset
    |> Ash.Changeset.get_argument(:receipt)
    |> outcome(changeset)
    |> record(changeset)
  end

  defp outcome(receipt, changeset) do
    cond do
      is_nil(receipt) or (is_binary(receipt) and String.trim(receipt) == "") -> :missing
      not Receipt.shape?(receipt) -> :unknown
      true -> match(receipt, changeset)
    end
  end

  defp match(receipt, changeset) do
    case invocation(receipt) do
      nil -> :unknown
      invocation -> examine(invocation, receipt, changeset)
    end
  end

  defp examine(invocation, receipt, changeset) do
    cond do
      not same_browser?(invocation, changeset) -> :wrong_identity
      not recent?(invocation) -> :stale
      not describes?(invocation, changeset) -> :mismatched
      spent?(invocation, receipt) -> :spent
      true -> {:verified, invocation}
    end
  end

  # The identifier the board files a report under is issued by the page itself,
  # so it is also the one thing that says whether this browser is the one the
  # receipt was handed to.
  defp same_browser?(invocation, changeset) do
    reporter = Ash.Changeset.get_attribute(changeset, :browser_session_id)
    holder = invocation.browser_session.forum_session_id

    not is_nil(reporter) and not is_nil(holder) and to_string(holder) == to_string(reporter)
  end

  defp recent?(invocation) do
    DateTime.diff(DateTime.utc_now(), invocation.started_at, :second) <= @recent_hours * 3600
  end

  defp describes?(invocation, changeset) do
    case tool(changeset) do
      nil ->
        false

      tool ->
        tool.site.origin == RoomMirror.origin() and
          tool.name == invocation.tool_revision.name and
          tool.contract_sha256 == invocation.tool_contract_sha256
    end
  end

  # A receipt stands behind one report only. The lock makes two reports quoting
  # the same receipt at the same moment take their turn, so the second one sees
  # the first and is filed unverified rather than refused.
  defp spent?(invocation, receipt) do
    Patchbay.Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [receipt])

    Report
    |> Ash.Query.filter(invocation_id == ^invocation.id)
    |> Ash.exists?()
  end

  defp record({:verified, invocation}, changeset) do
    changeset
    |> Ash.Changeset.force_change_attribute(:verified, true)
    |> Ash.Changeset.force_change_attribute(:receipt_status, :verified)
    |> Ash.Changeset.force_change_attribute(:invocation_id, invocation.id)
    |> Ash.Changeset.force_change_attribute(:arguments_sha256, invocation.arguments_sha256)
    |> Ash.Changeset.force_change_attribute(:observed, logged_facts(invocation))
  end

  defp record(status, changeset) do
    changeset
    |> Ash.Changeset.force_change_attribute(:verified, false)
    |> Ash.Changeset.force_change_attribute(:receipt_status, status)
  end

  defp logged_facts(invocation) do
    %{
      "effective_status" => to_string(invocation.effective_status),
      "failure_code" => invocation.failure_code && to_string(invocation.failure_code),
      "handler_reported_success" => invocation.handler_reported_success,
      "generation" => invocation.tool_revision.generation
    }
  end

  defp invocation(receipt) do
    case Rooms.get_invocation_by_receipt(receipt,
           load: [:tool_revision, :browser_session],
           not_found_error?: false
         ) do
      {:ok, %Invocation{} = invocation} -> invocation
      _ -> nil
    end
  end

  defp tool(changeset) do
    case Ash.Changeset.get_attribute(changeset, :tool_id) do
      nil ->
        nil

      tool_id ->
        case Forum.get_tool(tool_id, load: [:site], not_found_error?: false) do
          {:ok, tool} -> tool
          _ -> nil
        end
    end
  end
end
