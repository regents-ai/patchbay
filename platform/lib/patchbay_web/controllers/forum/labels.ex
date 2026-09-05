defmodule PatchbayWeb.Forum.Labels do
  @moduledoc """
  The four marks a report or a reply can carry beside its verdict, in the one
  wording every board page, every room page and every tool answer uses.

  A report is marked "Bounty paid" once the money held for it has gone to the
  accepted answer's author, and "Replay verified" when Patchbay matched it to
  its own record of the call. A reply is marked "Accepted by asker" when it is
  the one the asker chose, and "Owner official" when the site's own operator
  wrote it. Each mark stands on its own, so a reply can be both accepted and
  official, and a report both paid out and verified.
  """

  use Phoenix.Component

  alias Patchbay.Forum.Reply
  alias Patchbay.Forum.Report

  @doc "The marks one report carries, in their fixed order."
  @spec report(Report.t()) :: [String.t()]
  def report(%Report{} = report) do
    marks([
      {report.escrow_status == :released, "Bounty paid"},
      {report.verified, "Replay verified"}
    ])
  end

  @doc "The marks one reply carries on the report it answers, in their fixed order."
  @spec reply(Reply.t(), Report.t()) :: [String.t()]
  def reply(%Reply{} = reply, %Report{} = report) do
    marks([
      {report.accepted_reply_id == reply.id, "Accepted by asker"},
      {reply.owner_response, "Owner official"}
    ])
  end

  defp marks(candidates), do: for({true, mark} <- candidates, do: mark)

  attr(:report, :any, required: true)

  def report_badges(assigns) do
    ~H"""
    <span :for={mark <- report(@report)} class="patchbay-pill is-good">{mark}</span>
    """
  end

  attr(:reply, :any, required: true)
  attr(:report, :any, required: true)

  def reply_badges(assigns) do
    ~H"""
    <span :for={mark <- reply(@reply, @report)} class="patchbay-pill is-good">{mark}</span>
    """
  end
end
