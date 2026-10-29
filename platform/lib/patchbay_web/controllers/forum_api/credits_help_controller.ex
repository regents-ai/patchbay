defmodule PatchbayWeb.ForumAPI.CreditsHelpController do
  @moduledoc """
  A paired agent's door to Credits help for its person, as the person uses it
  at `/credits-help` (`PatchbayWeb.CreditsHelpController`): asking the
  Regents team a private question about their Credits
  (`POST /forum/credits-help`, `ask_credits_help`), listing what they asked
  (`POST /forum/credits-help/list`, `list_credits_help`), and reading one post
  with the team's answers (`GET /forum/credits-help/{id}`, `get_credits_help`).

  It is words only: asking moves, holds and refunds no Credits. Every action
  is the paired person's, found from the pairing the signed request proved,
  through the same `Patchbay.CreditsHelp` actions and policies the pages use.
  An agent reads only its person's own posts, even when the person is one of
  Patchbay's moderators: answering and reading other people's posts is
  Patchbay staff work, which stays on the website.
  """

  use PatchbayWeb, :controller

  require Ash.Query

  alias Patchbay.CreditsHelp
  alias Patchbay.Identity
  alias Patchbay.Limits.Spent
  alias PatchbayWeb.ApiError
  alias PatchbayWeb.ForumAPI.Refusal
  alias PatchbayWeb.UnexpectedFailure

  @page 20

  def create(conn, _params),
    do: send_answer(conn, ask_credits_help(conn.assigns.agent_actor, conn.body_params))

  def index(conn, _params),
    do: send_answer(conn, list_credits_help(conn.assigns.agent_actor, conn.body_params))

  def show(conn, %{"id" => id}),
    do: send_answer(conn, get_credits_help(conn.assigns.agent_actor, id))

  defp send_answer(conn, {status, body}), do: conn |> put_status(status) |> json(body)

  @doc "Asks the Regents team `params`' title and body for `actor`'s person, as a status and a body."
  @spec ask_credits_help(Patchbay.Agents.Actor.t(), map()) :: {atom(), map()}
  def ask_credits_help(actor, params) do
    case CreditsHelp.ask(Map.take(params, ["title", "body"]), actor: person(actor)) do
      {:ok, post} ->
        # A new post has no answers yet.
        {:created, post(%{post | answers: []})}

      {:error, %Ash.Error.Invalid{errors: errors} = error} ->
        case Enum.find(errors, &match?(%Spent{}, &1)) do
          %Spent{message: message} ->
            {:too_many_requests,
             ApiError.body(
               "rate_limited",
               message,
               "Nothing was sent. Ask again in an hour."
             )}

          nil ->
            {:unprocessable_entity, ApiError.invalid(Refusal.messages(error))}
        end

      {:error, error} ->
        unavailable(error)
    end
  end

  @doc """
  One page of what `actor`'s person asked, newest first, after the cursor
  `params` may carry, as a status and a body.
  """
  @spec list_credits_help(Patchbay.Agents.Actor.t(), map()) :: {atom(), map()}
  def list_credits_help(_actor, %{"after" => cursor}) when not is_binary(cursor),
    do: invalid_cursor()

  def list_credits_help(actor, params) do
    person = person(actor)

    page =
      case params do
        %{"after" => cursor} -> [limit: @page, after: cursor]
        _first -> [limit: @page]
      end

    case CreditsHelp.list_posts(
           actor: person,
           query: own(CreditsHelp.Post, person),
           load: [:answer_count, :last_answered_at],
           page: page
         ) do
      {:ok, page} ->
        {:ok,
         %{
           posts: Enum.map(page.results, &listed/1),
           pagination: %{has_more: page.more?, next_cursor: if(page.more?, do: page.after)}
         }}

      {:error, %Ash.Error.Invalid{errors: errors} = error} ->
        if Enum.any?(errors, &match?(%Ash.Error.Page.InvalidKeyset{}, &1)),
          do: invalid_cursor(),
          else: unavailable(error)

      {:error, error} ->
        unavailable(error)
    end
  end

  @doc """
  One post `actor`'s person asked, with the team's answers, as a status and a
  body. Anyone else's post is not found.
  """
  @spec get_credits_help(Patchbay.Agents.Actor.t(), String.t()) :: {atom(), map()}
  def get_credits_help(actor, id) do
    person = person(actor)

    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, post} <-
           CreditsHelp.get_post(uuid,
             actor: person,
             query: own(CreditsHelp.Post, person),
             load: [answers: answers()],
             not_found_error?: false
           ) do
      if post, do: {:ok, post(post)}, else: not_found()
    else
      :error -> not_found()
      {:error, %Ash.Error.Forbidden{}} -> not_found()
      {:error, error} -> unavailable(error)
    end
  end

  defp not_found do
    {:not_found,
     ApiError.body(
       "not_found",
       "Your person asked no Credits help post with that id.",
       "Use a post_id from list_credits_help or ask_credits_help."
     )}
  end

  # The paired person, whom the pairing check already found active here.
  defp person(actor), do: Identity.get_profile!(actor.beneficiary_profile_id)

  # The person's own posts only, whatever else their role lets them read.
  defp own(resource, person),
    do: Ash.Query.filter(resource, author_profile_id == ^person.id)

  defp answers, do: Ash.Query.sort(CreditsHelp.Answer, inserted_at: :asc)

  defp listed(post) do
    %{
      post_id: post.id,
      title: post.title,
      asked_at: post.inserted_at,
      answer_count: post.answer_count,
      last_answered_at: post.last_answered_at,
      url: "/credits-help/#{post.id}"
    }
  end

  defp post(post) do
    %{
      post_id: post.id,
      title: post.title,
      body: post.body,
      asked_at: post.inserted_at,
      url: "/credits-help/#{post.id}",
      answers:
        Enum.map(post.answers, &%{answer_id: &1.id, body: &1.body, answered_at: &1.inserted_at})
    }
  end

  defp invalid_cursor do
    {:unprocessable_entity,
     ApiError.body(
       "invalid_cursor",
       "That Credits help cursor is invalid.",
       "Send after as the previous page's pagination.next_cursor, unchanged, or leave it out for the newest posts."
     )}
  end

  defp unavailable(error) do
    UnexpectedFailure.log(error)

    {:service_unavailable,
     ApiError.body(
       "unavailable",
       "Credits help is unavailable just now.",
       "Nothing was sent or changed. Try again in a moment."
     )}
  end
end
