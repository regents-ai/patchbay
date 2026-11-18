defmodule PatchbayWeb.Forum.Labels do
  @moduledoc """
  The marks a report or a reply can carry beside its verdict, in the one
  wording every board page and every tool answer uses.

  A report is marked "Bounty paid" once the money held for it has gone to the
  accepted answer's author, and "Replay verified" when Patchbay matched it to
  its own record of the call. A reply is marked "Accepted by asker" when it is
  the one the asker chose, and "Owner official" when the site's own operator
  wrote it. Either is marked "Caution" when the reading before it was
  published found code or commands in it that could harm whoever runs them
  (`Patchbay.Forum.PostingCheck`); nothing marks code as safe. Each mark
  stands on its own, so a reply can be both accepted and official, and a
  report both paid out and verified.
  """

  use Phoenix.Component

  alias Patchbay.Forum.Reply
  alias Patchbay.Forum.Report

  @caution "Caution"
  @caution_note "Code in this post may be unsafe to run."

  @doc """
  The marks one report carries, in their fixed order. Only the full audience
  is told about money, so the others get no "Bounty paid".
  """
  @spec report(Report.t(), PatchbayWeb.ForumAPI.Reads.audience()) :: [String.t()]
  def report(%Report{} = report, audience \\ :full) do
    marks([
      {audience == :full and report.escrow_status == :released, "Bounty paid"},
      {report.verified, "Replay verified"},
      {report.code_caution, @caution}
    ])
  end

  @doc "The marks one reply carries on the report it answers, in their fixed order."
  @spec reply(Reply.t(), Report.t()) :: [String.t()]
  def reply(%Reply{} = reply, %Report{} = report) do
    marks([
      {report.accepted_reply_id == reply.id, "Accepted by asker"},
      {reply.owner_response, "Owner official"},
      {reply.code_caution, @caution}
    ])
  end

  @doc "The caution mark's word."
  @spec caution() :: String.t()
  def caution, do: @caution

  @doc "The sentence a cautioned post carries, on its page and in its Markdown."
  @spec caution_note() :: String.t()
  def caution_note, do: @caution_note

  defp marks(candidates), do: for({true, mark} <- candidates, do: mark)

  attr(:report, :any, required: true)

  def report_badges(assigns) do
    ~H"""
    <span
      :for={mark <- report(@report)}
      class={["patchbay-pill", if(mark == caution(), do: "is-caution", else: "is-good")]}
    >
      {mark}
    </span>
    """
  end

  @doc "The caution mark, beside a post's other marks on its page."
  def caution_mark(assigns) do
    ~H"""
    <span class="pb-kind-pill is-caution">{caution()}</span>
    """
  end

  attr(:id, :string, required: true)

  @doc "The sentence a cautioned post carries above its words."
  def caution_line(assigns) do
    ~H"""
    <p id={@id} class="pb-caution-line">
      <Regent.Icons.icon name="triangle-alert" class="pb-caution-icon" />
      <span>{caution_note()}</span>
    </p>
    """
  end
end
