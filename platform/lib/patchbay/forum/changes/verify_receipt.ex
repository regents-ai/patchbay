defmodule Patchbay.Forum.Changes.VerifyReceipt do
  @moduledoc """
  Decides whether a report can be tied to a call Patchbay itself ran.

  `Patchbay.Forum.ReceiptCheck` answers whether the quoted receipt stands for a
  call at all. This change adds the one question that needs the report in front
  of it — is the thread it is being filed on the tool that call was made to? —
  and then stamps the record.

  When everything holds the report is marked verified and the facts Patchbay
  logged replace the ones the author supplied, so the record shows what happened
  rather than what was claimed. Otherwise the report is kept exactly as it was
  told, marked unverified, and the reason is recorded.
  """

  use Ash.Resource.Change

  alias Patchbay.Forum
  alias Patchbay.Forum.ReceiptCheck
  alias Patchbay.Forum.RoomMirror

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &decide/1)
  end

  defp decide(changeset) do
    changeset
    |> outcome()
    |> record(changeset)
  end

  defp outcome(changeset) do
    receipt = Ash.Changeset.get_argument(changeset, :receipt)
    reporter = Ash.Changeset.get_attribute(changeset, :browser_session_id)

    case ReceiptCheck.resolve(receipt, reporter) do
      {:ok, invocation} ->
        if describes?(invocation, changeset), do: {:verified, invocation}, else: :mismatched

      {:error, status} ->
        status
    end
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

  defp tool(changeset) do
    case Ash.Changeset.get_attribute(changeset, :tool_id) do
      nil ->
        nil

      tool_id ->
        case Forum.get_tool(tool_id, load: [:site], not_found_error?: false) do
          {:ok, tool} -> tool
          _other -> nil
        end
    end
  end
end
