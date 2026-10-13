defmodule Patchbay.Forum.PostReview do
  @moduledoc """
  The moderators' side of the posting check: what was turned away, whether
  that was right, and a way to let a person post again.

  A moderator reads the posts Jev turned away, with the words it was shown,
  and may rule on any of them: right to block, or wrong to. A post ruled
  wrong stops counting toward its person's pause. It is not published; its
  writer posts it again. Lifting a pause stops every post turned away for
  that person counting, back as far as one could still pause them, so they
  start again from none.

  A ruling by itself changes nothing Jev reads. Making a ruled post one of
  Jev's examples is a press of its own: Jev then reads a short cut of that
  post's words beside every post it judges, so the page shows the moderator
  that exact cut first (`Patchbay.Forum.PostingCheck.example_cut/1`). So
  many may be ruled each way; a ruling that changes takes its example out.

  Every ruling, every example put in or taken out and every lift writes a
  `Patchbay.Forum.ModerationAction` in the same transaction, naming who and
  what. The page has already checked the moderator's wallet, so the reads and
  writes here are Patchbay's own and skip authorization.
  """

  require Ash.Query

  alias Patchbay.Forum
  alias Patchbay.Forum.ModerationAction
  alias Patchbay.Forum.PostCheck
  alias Patchbay.Forum.PostingCheck
  alias Patchbay.Identity.AgentProfile

  @listed 50

  @rulings %{right: :right_to_block, wrong: :wrong_to_block, none: :ruling_withdrawn}

  @typedoc "One post turned away, who it was for, and how long they are paused, if they are."
  @type entry :: %{
          check: PostCheck.t(),
          person: AgentProfile.t() | nil,
          paused_until: DateTime.t() | nil
        }

  @doc "The newest posts turned away, newest first."
  @spec turned_away() :: [entry()]
  def turned_away do
    now = DateTime.utc_now()
    # The page has checked the moderator; these are Patchbay's own reads of
    # records no visitor may read.
    checks = Forum.posts_turned_away!(query: [limit: @listed], authorize?: false)
    people = checks |> Enum.map(& &1.profile_id) |> Enum.uniq()

    names =
      AgentProfile
      |> Ash.Query.filter(id in ^people)
      |> Ash.read!(authorize?: false)
      |> Map.new(&{&1.id, &1})

    pauses =
      people
      |> Forum.posts_turned_away_since!(PostingCheck.counted_since(now), authorize?: false)
      |> Enum.group_by(& &1.profile_id)
      |> Map.new(fn {person, rejects} -> {person, running(rejects, now)} end)

    Enum.map(
      checks,
      &%{check: &1, person: names[&1.profile_id], paused_until: pauses[&1.profile_id]}
    )
  end

  defp running(rejects, now) do
    until = PostingCheck.paused_until(rejects)
    if until && DateTime.after?(until, now), do: until
  end

  @doc """
  Writes a moderator's word on one post turned away: `:right` to block,
  `:wrong` to block, or `:none` to take a ruling back.
  """
  @spec rule(String.t(), :right | :wrong | :none, AgentProfile.t()) ::
          {:ok, PostCheck.t()} | {:error, String.t()}
  def rule(check_id, ruling, moderator) when is_map_key(@rulings, ruling) do
    # The page has checked the moderator; the record is closed to everyone else.
    decided([PostCheck, ModerationAction], fn ->
      with {:ok, %PostCheck{rejected: true} = check} <-
             Forum.get_post_check(check_id, authorize?: false),
           {:ok, ruled} <-
             Forum.rule_post_check(check, %{ruling: stored(ruling)}, authorize?: false),
           {:ok, _audit} <- record(:post_check, check.id, @rulings[ruling], moderator) do
        {:ok, ruled}
      else
        _other -> {:error, "That is not a post that was turned away."}
      end
    end)
  end

  defp stored(:none), do: nil
  defp stored(ruling), do: ruling

  @doc """
  Makes a ruled post one of Jev's examples, as the cut of its kept words the
  page showed. Refused when its words are no longer kept, it has no ruling,
  or Jev already has all the examples ruled that way it is shown.
  """
  @spec use_as_example(String.t(), AgentProfile.t()) ::
          {:ok, PostCheck.t()} | {:error, String.t()}
  def use_as_example(check_id, moderator) do
    # The page has checked the moderator; the record is closed to everyone else.
    decided([PostCheck, ModerationAction], fn ->
      with {:ok, %PostCheck{rejected: true, ruling: ruling, shown: %{} = shown} = check}
           when ruling in [:right, :wrong] <- Forum.get_post_check(check_id, authorize?: false),
           cut when cut != "" <- PostingCheck.example_cut(shown),
           :ok <- room(ruling),
           {:ok, example} <-
             Forum.set_post_check_example(check, %{example: cut}, authorize?: false),
           {:ok, _audit} <- record(:post_check, check.id, :example_added, moderator) do
        {:ok, example}
      else
        :full ->
          {:error,
           "Jev already has #{PostingCheck.examples_each_way()} examples ruled that way. Take one out first."}

        _other ->
          {:error, "Only a ruled post whose words are still kept can be an example."}
      end
    end)
  end

  defp room(ruling) do
    # Patchbay's own read of its own rows.
    chosen = Forum.post_check_examples!(authorize?: false)

    if Enum.count(chosen, &(&1.ruling == ruling)) < PostingCheck.examples_each_way(),
      do: :ok,
      else: :full
  end

  @doc "Takes a post out of Jev's examples."
  @spec drop_example(String.t(), AgentProfile.t()) :: {:ok, PostCheck.t()} | {:error, String.t()}
  def drop_example(check_id, moderator) do
    # The page has checked the moderator; the record is closed to everyone else.
    decided([PostCheck, ModerationAction], fn ->
      with {:ok, %PostCheck{example: example} = check} when is_binary(example) <-
             Forum.get_post_check(check_id, authorize?: false),
           {:ok, dropped} <-
             Forum.set_post_check_example(check, %{example: nil}, authorize?: false),
           {:ok, _audit} <- record(:post_check, check.id, :example_removed, moderator) do
        {:ok, dropped}
      else
        _other -> {:error, "That is not one of Jev's examples."}
      end
    end)
  end

  @doc """
  Lets a person post again: none of the posts turned away for them up to now
  counts toward a pause any more.
  """
  @spec lift_pause(String.t(), AgentProfile.t()) :: {:ok, :lifted} | {:error, String.t()}
  def lift_pause(profile_id, moderator) do
    since = PostingCheck.counted_since(DateTime.utc_now())

    # The page has checked the moderator; these records are closed to everyone
    # else.
    decided([PostCheck, ModerationAction], fn ->
      with {:ok, person} <- Ash.get(AgentProfile, profile_id, authorize?: false),
           %Ash.BulkResult{status: :success} <-
             PostCheck
             |> Ash.Query.filter(
               rejected and profile_id == ^person.id and inserted_at > ^since and
                 is_nil(lifted_at)
             )
             |> Ash.bulk_update(:lift, %{}, authorize?: false, strategy: :atomic),
           {:ok, _audit} <- record(:person, person.id, :pause_lifted, moderator) do
        {:ok, :lifted}
      else
        _other -> {:error, "That person's pause could not be lifted."}
      end
    end)
  end

  defp decided(resources, decide) do
    case Ash.transact(resources, decide) do
      {:ok, {:ok, done}} -> {:ok, done}
      {:ok, {:error, problem}} -> {:error, problem}
      {:error, _failure} -> {:error, "That decision could not be recorded."}
    end
  end

  # Patchbay's own record of a decision the page has already allowed.
  defp record(subject_kind, subject_id, action, moderator) do
    ModerationAction
    |> Ash.Changeset.for_create(:record, %{
      subject_kind: subject_kind,
      subject_id: subject_id,
      action: action,
      reason: reason(action),
      actor_profile_id: moderator.id
    })
    |> Ash.create(authorize?: false)
  end

  defp reason(:right_to_block), do: "Ruled right to block."
  defp reason(:wrong_to_block), do: "Ruled wrong to block."
  defp reason(:ruling_withdrawn), do: "Ruling taken back."
  defp reason(:example_added), do: "Made one of Jev's examples."
  defp reason(:example_removed), do: "Taken out of Jev's examples."
  defp reason(:pause_lifted), do: "Pause lifted."
end
