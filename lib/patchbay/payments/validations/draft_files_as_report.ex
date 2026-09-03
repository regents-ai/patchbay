defmodule Patchbay.Payments.Validations.DraftFilesAsReport do
  @moduledoc """
  Refuses terms for a paid priority report whose draft the forum would not
  file, before anyone is asked to pay for them.

  The draft is run through the forum's own filing action, without being
  written, and every reason the forum gives is handed back as a reason of
  these terms. That is what makes the report published after settlement the
  same report the forum would have accepted: the rules are the forum's, read
  once here and once again at filing, and nothing in between.
  """

  use Ash.Resource.Validation

  alias Patchbay.Forum.OtherSiteReport
  alias Patchbay.Forum.Report
  alias Patchbay.Forum.Tool

  @impl true
  def validate(changeset, _opts, context) do
    with %Tool{} = tool <- Ash.Changeset.get_argument(changeset, :tool),
         %{} = draft <- Ash.Changeset.get_argument(changeset, :draft),
         amount_atomic when is_integer(amount_atomic) <-
           Ash.Changeset.get_attribute(changeset, :amount_atomic) do
      files?(draft, tool, amount_atomic, context.actor)
    else
      _incomplete -> :ok
    end
  end

  @impl true
  def describe(_opts) do
    [message: "would not be filed as a report", vars: []]
  end

  # The filing is only built, never run. The ids and the session it is built
  # with stand in for the ones the settlement request will carry; none of
  # them is what the forum's rules are about.
  defp files?(draft, tool, amount_atomic, actor) do
    filing =
      Ash.Changeset.for_create(
        Report,
        :file_priority_report,
        draft
        |> OtherSiteReport.report_attributes(tool.id)
        |> Map.merge(%{
          id: Ash.UUID.generate(),
          browser_session_id: Ash.UUID.generate(),
          priority_amount_atomic: amount_atomic,
          payment_intent_id: Ash.UUID.generate()
        }),
        actor: actor
      )

    if filing.valid?, do: :ok, else: {:error, filing.errors}
  end
end
