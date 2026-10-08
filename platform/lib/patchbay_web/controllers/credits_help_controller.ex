defmodule PatchbayWeb.CreditsHelpController do
  @moduledoc """
  The Credits help pages: `/credits-help`, where a signed-in person asks the
  Regents team about their Credits and sees what they have asked, and
  `/credits-help/:id`, one post with the team's answers.

  Every read goes through `Patchbay.CreditsHelp` with the signed-in profile as
  the actor, so a post that is not the reader's own, and the reader is not a
  moderator, answers as though it does not exist. None of these pages is
  meant for search engines.
  """

  use PatchbayWeb, :controller

  alias Patchbay.Config
  alias Patchbay.CreditsHelp
  alias PatchbayWeb.Forum.NotFoundError

  plug :keep_out_of_search

  def index(conn, params) do
    render_index(conn, params, %{}, nil)
  end

  def create(conn, %{"post" => fields}) do
    draft = Map.take(fields, ["title", "body"])

    case conn.assigns.current_profile do
      nil ->
        render_index(conn, %{}, draft, "Sign in at the top of the page to post.")

      profile ->
        case CreditsHelp.ask(draft, actor: profile) do
          {:ok, post} -> redirect(conn, to: ~p"/credits-help/#{post.id}")
          {:error, error} -> render_index(conn, %{}, draft, problem(:post, error))
        end
    end
  end

  def show(conn, %{"id" => id}) do
    render_post(conn, fetch_post!(conn, id), %{}, nil)
  end

  def answer(conn, %{"id" => id, "answer" => fields}) do
    post = fetch_post!(conn, id)
    draft = Map.take(fields, ["body"])
    profile = conn.assigns.current_profile

    unless Config.moderator?(profile), do: raise(NotFoundError)

    case CreditsHelp.answer(%{post_id: post.id, body: draft["body"]}, actor: profile) do
      {:ok, answer} -> redirect(conn, to: ~p"/credits-help/#{post.id}" <> "#answer-#{answer.id}")
      {:error, error} -> render_post(conn, post, draft, problem(:answer, error))
    end
  end

  defp render_index(conn, params, draft, problem) do
    profile = conn.assigns.current_profile

    page =
      profile &&
        CreditsHelp.list_posts!(
          actor: profile,
          load: [:author, :answer_count],
          page: page(params)
        )

    render(conn, :index,
      page_title: "Credits help",
      admin?: Config.moderator?(profile),
      posts: (page && page.results) || [],
      cursor: params["after"],
      next: page && page.more? && page.after,
      draft: draft,
      problem: problem
    )
  end

  defp render_post(conn, post, draft, problem) do
    render(conn, :show,
      page_title: post.title,
      post: post,
      admin?: Config.moderator?(conn.assigns.current_profile),
      draft: draft,
      problem: problem
    )
  end

  defp fetch_post!(conn, id) do
    load = [
      :author,
      answers: Ash.Query.sort(CreditsHelp.Answer, inserted_at: :asc) |> Ash.Query.load(:author)
    ]

    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, post} <-
           CreditsHelp.get_post(uuid, actor: conn.assigns.current_profile, load: load) do
      post
    else
      _missing -> raise NotFoundError
    end
  end

  defp page(%{"after" => cursor}) when is_binary(cursor), do: [limit: 20, after: cursor]
  defp page(_params), do: [limit: 20]

  defp problem(:post, %Ash.Error.Invalid{}),
    do:
      "Give it a title of up to 140 characters and say what happened in up to 5,000, then post again."

  defp problem(:answer, %Ash.Error.Invalid{}),
    do: "Write an answer of up to 5,000 characters, then post it again."

  defp problem(_form, _error), do: "That did not save. Try again in a moment."

  defp keep_out_of_search(conn, _opts), do: put_resp_header(conn, "x-robots-tag", "noindex")
end
