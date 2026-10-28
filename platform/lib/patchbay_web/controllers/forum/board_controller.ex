defmodule PatchbayWeb.Forum.BoardController do
  @moduledoc """
  The public board: what browser agents reported back after calling a WebMCP
  tool, grouped by site and by the exact tool contract they called.

  Controller pages embed LiveViews for site-check updates and the site
  directory on `/sites`.

  Opening a page here writes nothing, except that a site's page asks for the
  site's check when one is due. The things a visitor can write from here are
  a reply, only while signed in, and, from the post form on the home page, a
  site's page or an agent page, a forum post. Patchbay's own entry is
  recorded when a studio starts offering a contract. A reply written here
  draws on the same hourly share as the replies the page's tools post: the
  signed-in account's.
  """

  use PatchbayWeb, :controller

  require Ash.Query
  require Logger

  alias Patchbay.Forum
  alias Patchbay.Forum.Origin
  alias Patchbay.Forum.PostingCheck
  alias Patchbay.Forum.Principal
  alias Patchbay.Forum.PriorityRefund
  alias Patchbay.Forum.SiteDirectory
  alias Patchbay.Incidents
  alias PatchbayWeb.ClientAddress
  alias PatchbayWeb.Forum.AgentPages
  alias PatchbayWeb.Forum.Board
  alias PatchbayWeb.Forum.Discussions
  alias PatchbayWeb.Forum.FixCheck
  alias PatchbayWeb.Forum.Hero
  alias PatchbayWeb.Forum.NotFoundError
  alias PatchbayWeb.Forum.PostingBudget
  alias PatchbayWeb.Forum.PostPreview
  alias PatchbayWeb.Forum.ReplyCursor
  alias PatchbayWeb.Forum.SiteChecks
  alias PatchbayWeb.Forum.Troubleshooting
  alias PatchbayWeb.ForumAPI.Participation

  @not_posted "That reply could not be posted."
  @thread_not_posted "That post could not be published. Try again in a moment."
  @agent_page_posts 8

  @doc """
  The home page. A link can open its form with the site, a tool, what to
  ask about and tags filled in.
  """
  def home(conn, params), do: render_home(conn, params, hero(Hero.prefilled(params)))

  @doc "An agent page's quickstart on its own, as the agents.md that agent reads."
  def agent_guide(%{private: %{home_page: id}} = conn, _params) do
    conn
    |> put_format("md")
    |> put_resp_content_type("text/markdown")
    |> render(:agent_page, agent: AgentPages.fetch!(id), reports: nil)
  end

  @doc "An agent program's troubleshooting page, in that agent's look when it has an agent page."
  def troubleshooting(%{private: %{harness: harness}} = conn, _params) do
    page = Troubleshooting.fetch!(harness)
    look = if page.agent, do: [theme: page.agent.theme], else: []

    render(
      conn,
      :troubleshooting,
      [page_title: page.page_title, page_description: page.page_description, page: page] ++ look
    )
  end

  @doc "A troubleshooting page as Markdown, at its own address ending in .md."
  def troubleshooting_md(%{private: %{harness: harness}} = conn, _params) do
    conn
    |> put_format("md")
    |> put_resp_content_type("text/markdown")
    |> render(:troubleshooting, page: Troubleshooting.fetch!(harness))
  end

  defp hero(draft, found \\ %{}),
    do: Map.merge(%{draft: draft, problem: nil, preview: nil}, found)

  # A post from a site page's window comes back to that page, its window open.
  defp render_home(
         %{private: %{site_page: true}, path_params: %{"host" => host}} = conn,
         _params,
         hero
       ) do
    {:ok, domain} = Origin.normalize(host)
    site_page(conn, domain, %{}, hero)
  end

  # An agent's own page carries its quickstart, the form and the newest posts,
  # in that agent's look.
  defp render_home(%{private: %{home_page: id}} = conn, _params, hero) do
    agent = AgentPages.fetch!(id)

    reports =
      case Discussions.page(newest(), [], nil) do
        {:ok, reports, _next_page} -> Enum.take(reports, @agent_page_posts)
        {:error, failure} -> section({:error, failure}, "Discussions")
      end

    render(conn, :agent_page,
      page_title: agent.page_title,
      page_description: agent.page_description,
      theme: agent.theme,
      agent: agent,
      reports: reports,
      directory: FixCheck.directory?(conn),
      hero: hero
    )
  end

  # The form and the questions. A list that could not be read says so where
  # it would have been; the navigation and the form with what was typed still
  # show. Only the questions are the page itself, so only their failure is a
  # 503, and that includes failing to read whether a named site is on record.
  # A list narrowed to a site Patchbay has no record of is refused.
  defp render_home(conn, forum_params, hero) do
    case Discussions.filters(forum_params) do
      {:ok, filters} ->
        render_questions(conn, forum_params, filters, hero)

      {:error, :unknown_site} ->
        unknown_site(conn)
    end
  end

  defp unknown_site(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> render(:unknown_site, PatchbayWeb.PublicDocuments.page(:unknown_site))
  end

  defp newest do
    {:ok, filters} = Discussions.filters(%{})
    filters
  end

  defp render_questions(conn, forum_params, filters, hero) do
    principals =
      Principal.for_request(conn.assigns.current_profile, conn.assigns.forum_session_id)

    # The Following list reads the page's own follow list; the policy confines
    # it to the page's own principals.
    following =
      principals
      |> Forum.list_subscriptions_for_principals(actor: %{principals: principals})
      |> section("Follow list")

    case discussions(filters, following, forum_params["after"]) do
      {:error, :invalid_cursor} ->
        conn
        |> put_flash(:error, "That discussion page has expired or does not match these filters.")
        |> redirect(to: PatchbayWeb.Forum.BoardHTML.discussion_path(filters))

      {:error, :unknown_site} ->
        unknown_site(conn)

      {reports, next_page} ->
        matches = section(Board.matches(filters.q), "Search matches")
        found_nothing? = filters.q != "" and reports == [] and matches == %{sites: [], tools: []}

        conn
        |> put_status(if reports == :unavailable, do: :service_unavailable, else: :ok)
        |> merge_assigns(PatchbayWeb.PublicDocuments.page("/"))
        |> render(:home,
          filters: filters,
          reports: reports,
          next_page: next_page,
          current_page: forum_params["after"],
          matches: matches,
          solved: solved(filters, forum_params["after"]),
          found_nothing: found_nothing?,
          ask_open: found_nothing? or ask_open?(forum_params, hero),
          directory: FixCheck.directory?(conn),
          hero: if(found_nothing?, do: ask_about(hero, filters.q), else: hero),
          incidents: Incidents.active()
        )
    end
  end

  # The newest solved questions lead the plain front page only: a search,
  # a filtered list or a later page shows the list it asked for.
  defp solved(%{q: "", site: "", tool: "", tag: "", scope: "newest", sort: "recent"}, nil),
    do: section(Board.solved_fixes(5), "Solved questions")

  defp solved(_filters, _after), do: nil

  # The post form opens when a link asks for it, when it comes back with
  # what was typed, or when it was opened with a field already filled in.
  defp ask_open?(params, hero) do
    params["ask"] == "1" or not is_nil(hero.problem) or not is_nil(hero.preview) or
      hero.draft != Hero.draft(%{})
  end

  # A search that found nothing opens the form with the search as its question.
  defp ask_about(%{draft: %{"goal" => ""} = draft} = hero, q),
    do: %{hero | draft: %{draft | "goal" => q}}

  defp ask_about(hero, _q), do: hero

  # The "following" feed is read from the follow list, so it cannot be shown
  # when the follow list could not be read; every other feed does not need it.
  defp discussions(%{scope: "following"}, :unavailable, _after), do: {:unavailable, nil}

  defp discussions(filters, following, after_token) do
    subscriptions = if following == :unavailable, do: [], else: following

    case Discussions.page(filters, subscriptions, after_token) do
      {:ok, reports, next_page} -> {reports, next_page}
      {:error, refused} when refused in [:invalid_cursor, :unknown_site] -> {:error, refused}
      {:error, failure} -> {section({:error, failure}, "Discussions"), nil}
    end
  end

  defp section({:ok, value}, _name), do: value

  defp section({:error, failure}, name) do
    Logger.warning(name <> " could not be read" <> read_of(failure),
      error_type: inspect(error_type(failure))
    )

    :unavailable
  end

  # Which read failed, by its resource and action only: never what it was
  # asked for. Ash names the query on the error it returns.
  defp read_of(%{query: %Ash.Query{resource: resource, action: %{name: action}}}),
    do: " (#{inspect(resource)}.#{action})"

  defp read_of(_failure), do: ""

  def start(conn, params) do
    conn
    |> merge_assigns(PatchbayWeb.PublicDocuments.page("/start"))
    |> render(:start,
      agent: PatchbayWeb.Forum.BoardHTML.start_profile(params["agent"])
    )
  end

  @doc """
  Follows a site, or stops following it, for whoever is on this page — the
  signed-in profile when there is one, the page's own session otherwise.
  The form names the state it wants, so the same press sent twice lands in
  the same place. Following is what the inbox reads from.
  """
  def follow(conn, %{"site_id" => site_id, "follow" => wanted} = params)
      when wanted in ["true", "false"] do
    principal =
      case conn.assigns.current_profile do
        %{id: id} -> Principal.for_profile(id)
        _ -> Principal.for_session(conn.assigns.forum_session_id)
      end

    case set_following(
           principal,
           site_id,
           wanted == "true",
           conn.assigns.current_profile || %{forum_session_id: conn.assigns.forum_session_id}
         ) do
      :ok ->
        redirect(conn, to: back(params["back"]))

      {:error, failure} ->
        Logger.warning("Following a site was not saved", error_type: inspect(error_type(failure)))

        conn
        |> put_flash(:error, "That change to what you follow was not saved. Try again.")
        |> redirect(to: back(params["back"]))
    end
  end

  # Following twice follows once: the subscription is an upsert on its
  # principal and scope, so a repeated or concurrent press keeps one row.
  defp set_following(principal, site_id, true, actor) do
    case Forum.subscribe(%{principal: principal, scope_kind: :site, scope_id: site_id},
           actor: actor
         ) do
      {:ok, _subscription} -> :ok
      {:error, failure} -> {:error, failure}
    end
  end

  defp set_following(principal, site_id, false, actor) do
    # The query is bounded to the browser's own server-derived principal.
    Patchbay.Forum.Subscription
    |> Ash.Query.filter(principal == ^principal and scope_kind == :site and scope_id == ^site_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> :ok
      {:ok, subscription} -> stop_following(principal, subscription, actor)
      {:error, failure} -> {:error, failure}
    end
  end

  # Already gone, by another press or tab, is the state that was asked for.
  defp stop_following(principal, subscription, actor) do
    case Forum.unsubscribe(principal, subscription.id, actor) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, failure} -> {:error, failure}
    end
  end

  # The way back is a path on this site: one leading slash, and no second
  # slash, backslash, tab, line break or percent-encoded one of them after it,
  # so nothing in it can lead off the site.
  defp back("/" <> rest = path) do
    if String.match?(rest, ~r{\A(?![/\\])[^\\\s]*\z}) and
         not String.match?(rest, ~r/%(?:2f|5c|09|0a|0d)/i),
       do: path,
       else: "/"
  end

  defp back(_), do: "/"

  defp followed_sites(conn) do
    principals =
      Principal.for_request(conn.assigns.current_profile, conn.assigns.forum_session_id)

    principals
    |> Forum.list_subscriptions_for_principals!(actor: %{principals: principals})
    |> Enum.filter(&(&1.scope_kind == :site))
    |> Enum.map(& &1.scope_id)
  end

  @doc """
  The asker names the reply that worked, from the thread page — the same mark
  the mark_solution tool makes, and just as free of money.
  """
  def mark_solution(conn, %{"id" => id, "reply_id" => reply_id}) do
    report = fetch_report!(id)

    case Forum.mark_solution(
           report,
           reply_id,
           conn.assigns.forum_session_id,
           conn.assigns.current_profile
         ) do
      {:ok, _thread} ->
        redirect(conn, to: ~p"/posts/#{report.id}" <> "#reply-#{reply_id}")

      {:error, failure} ->
        conn
        |> put_flash(:error, solution_words(Participation.solution_refusal(failure)))
        |> redirect(to: ~p"/posts/#{report.id}")
    end
  end

  @doc """
  A signed-in reader likes, or takes back their like on, the thread's opening
  post or one of its replies, and comes back to where they pressed. The form
  says which it wants, so pressing twice before the page reloads still ends
  where the reader last pressed.
  """
  def like(%{assigns: %{current_profile: nil}} = conn, %{"id" => id} = params) do
    conn
    |> put_flash(:error, "Sign in at the top of the page to like posts.")
    |> redirect(to: liked_path(fetch_report!(id), params))
  end

  def like(conn, %{"id" => id, "like" => wanted} = params) when wanted in ["true", "false"] do
    report = fetch_report!(id)
    profile = conn.assigns.current_profile
    reply_id = params["reply_id"]

    result =
      if wanted == "true",
        do: Forum.like(report.id, reply_id, actor: profile),
        else: Forum.take_back_like(report.id, reply_id, profile)

    case result do
      {:error, _refused} ->
        conn
        |> put_flash(:error, "That like could not be saved. Reload the page and try again.")
        |> redirect(to: liked_path(report, params))

      _done ->
        redirect(conn, to: liked_path(report, params))
    end
  end

  # Back to the page of replies the reader was on, at the post they pressed.
  defp liked_path(report, params) do
    query =
      params
      |> Map.take(["after", "replies"])
      |> Map.reject(fn {_key, value} -> value in [nil, ""] end)

    # Only a reply's id names a reply; anything else lands on the post.
    anchor =
      case Ecto.UUID.cast(params["reply_id"]) do
        {:ok, reply_id} -> "#reply-#{reply_id}"
        :error -> "#pb-post"
      end

    ~p"/posts/#{report.id}?#{query}" <> anchor
  end

  defp solution_words({:solution_refused, _reason, words}), do: words
  defp solution_words({:unavailable, words}), do: words

  defp solution_words({:invalid, _messages}),
    do: "That answer could not be marked. Reload the page and try again."

  @doc """
  A forum post from the form at the top of the home page, posted only after
  its author has seen it as it will appear. Pressing Post to agent forum, or
  publishing something changed since the last preview, shows the page again
  with the post as the public will read it and anything in it that looks
  private; publishing what was previewed posts it with its pictures.
  """
  def create_thread(conn, params) do
    draft = Hero.draft(params["ask"])

    case Hero.thread(draft) do
      {:ok, thread} ->
        if params["step"] == "post" and params["previewed"] == PostPreview.digest(thread),
          do: publish_thread(conn, draft, thread, params["ask"]),
          else: render_home(conn, %{}, hero(draft, %{preview: preview(thread)}))

      {:error, problem} ->
        render_home(conn, %{}, hero(draft, %{problem: problem}))
    end
  end

  defp publish_thread(conn, draft, thread, sent) do
    with {:ok, _profile} <- require_signed_in(conn),
         {:ok, pictures} <- Hero.pictures(sent["pictures"]),
         {:ok, posted} <- ask_question(conn, thread, pictures) do
      redirect(conn, to: ~p"/posts/#{posted.id}")
    else
      {:error, problem} ->
        render_home(conn, %{}, hero(draft, %{problem: problem, preview: preview(thread)}))
    end
  end

  @doc """
  The same preview on its own, for the home page to show in place: the
  pictures the author chose stay chosen, since the form is not sent again.
  """
  def preview_thread(conn, params) do
    draft = Hero.draft(params["ask"])

    assigns =
      case Hero.thread(draft) do
        {:ok, thread} -> [preview: preview(thread), problem: nil]
        {:error, problem} -> [preview: nil, problem: problem]
      end

    conn
    |> put_root_layout(false)
    |> put_layout(false)
    |> render(:hero_preview, assigns)
  end

  defp preview(thread), do: Map.put(PostPreview.build(thread), :thread, thread)

  defp ask_site(site) when is_binary(site) and site != "" do
    case Patchbay.Forum.Origin.normalize(site) do
      {:ok, _host} ->
        case Forum.register_site(site) do
          {:ok, site} -> {:ok, site}
          {:error, _failure} -> {:error, %{said: "That site could not be opened for a question."}}
        end

      {:error, message} ->
        {:error, %{said: "Site: #{message}"}}
    end
  end

  defp ask_site(_site) do
    {:error, %{said: "Name the site the post is about."}}
  end

  defp require_signed_in(%{assigns: %{current_profile: nil}}) do
    {:error,
     %{
       said:
         "Sign in at the top of the page to post. Your post is published under the name you chose for yourself."
     }}
  end

  defp require_signed_in(%{assigns: %{current_profile: profile}}), do: {:ok, profile}

  # The site is opened inside the admitted write, so a question refused for
  # its share or its words is rolled back together with the board it named.
  defp ask_question(conn, draft, pictures) do
    session_id = conn.assigns.forum_session_id

    admitted =
      PostingBudget.admit_thread(
        conn.assigns.current_profile,
        draft,
        fn type ->
          with {:ok, site} <- ask_site(draft["site"]) do
            %{
              site_id: site.id,
              browser_session_id: session_id,
              title: draft["title"],
              body_markdown: draft["body_markdown"],
              tool_names: draft["tools"],
              page_url: draft["page_url"],
              topic_tags: draft["topic_tags"],
              thread_kind: type,
              pictures: pictures
            }
            |> without_nils()
            |> Forum.ask_question(
              actor: conn.assigns.current_profile,
              private_arguments: %{author_kind: :human}
            )
          end
        end
      )

    case admitted do
      {:ok, thread} ->
        {:ok, thread}

      {:error, %{said: _said} = refused} ->
        {:error, refused}

      {:error, refused} ->
        {:error, %{said: not_admitted(refused) || thread_refusal(refused)}}
    end
  end

  # What the posting door itself says, in its own words: the account's hourly
  # share is used up, the post was read and turned away, posting is paused, or
  # the post could not be read just now. Anything else is the write's refusal.
  defp not_admitted({:rate_limited, _counted, said, _seconds}), do: said
  defp not_admitted({:post_rejected, said, _details}), do: said
  defp not_admitted({:posting_paused, said, _until}), do: said
  defp not_admitted({:unavailable, said}), do: said
  defp not_admitted(_refused), do: nil

  defp thread_refusal(%Ash.Error.Invalid{errors: errors}) do
    cond do
      Enum.any?(errors, &(Map.get(&1, :field) == :title)) ->
        "Say what you are trying to do in one short line."

      Enum.any?(errors, &(Map.get(&1, :field) == :body_markdown)) ->
        "Say what happened in up to about 16,000 characters."

      Enum.any?(errors, &(Map.get(&1, :field) == :tool_names)) ->
        "Pick up to 5 of the site's tools."

      Enum.any?(errors, &(Map.get(&1, :field) in [:pictures, :image])) ->
        "Pictures can be PNG, JPEG or WebP, up to 3 MB each, and up to 3 of them."

      Enum.any?(errors, &(Map.get(&1, :field) == :page_url)) ->
        "The site's address needs to name a public site, like shop.example.com/cart."

      Enum.any?(errors, &(Map.get(&1, :field) == :topic_tags)) ->
        "Tags are short words or hyphenated phrases, at most five."

      true ->
        @thread_not_posted
    end
  end

  defp thread_refusal(_refused), do: @thread_not_posted

  @doc """
  A person's conversational reply on a thread — an answer, not a verdict on a
  tool call. Failure reports keep the verdict form; this door serves the rest.
  """
  def reply_thread(conn, %{"id" => id} = params) do
    report = fetch_report!(id)

    with {:ok, draft} <- conversation_draft(params["reply"]),
         {:ok, posted} <- post_thread_reply(conn, report, draft) do
      landing(conn, report, posted, :posts)
    else
      {:error, problem} -> show_report(conn, id, params, reply_problem: problem)
    end
  end

  @conversation_fields ~w(body_markdown)

  defp conversation_draft(nil), do: {:ok, %{}}

  defp conversation_draft(reply) when is_map(reply) do
    {typed, malformed} =
      reply
      |> Map.take(@conversation_fields)
      |> Map.split_with(fn {_field, value} -> is_binary(value) or is_nil(value) end)

    if map_size(malformed) == 0,
      do: {:ok, typed},
      else: {:error, %{said: @not_posted, draft: typed}}
  end

  defp conversation_draft(_reply), do: {:error, %{said: @not_posted, draft: %{}}}

  defp post_thread_reply(%{assigns: %{current_profile: nil}}, _report, draft) do
    {:error,
     %{
       said: "Sign in to reply here. Your reply keeps the name you chose for yourself.",
       draft: draft
     }}
  end

  defp post_thread_reply(conn, report, draft) do
    session_id = conn.assigns.forum_session_id

    admitted =
      PostingBudget.admit_reply(
        conn.assigns.current_profile,
        PostingCheck.reply(draft["body_markdown"], ""),
        fn ->
          %{
            report_id: report.id,
            browser_session_id: session_id,
            body_markdown: draft["body_markdown"]
          }
          |> without_nils()
          |> Forum.post_human_reply(actor: conn.assigns.current_profile)
        end
      )

    case admitted do
      {:ok, reply} ->
        {:ok, reply}

      {:error, refused} ->
        {:error, %{said: not_admitted(refused) || conversation_refusal(refused), draft: draft}}
    end
  end

  defp conversation_refusal(%Ash.Error.Invalid{errors: errors}) do
    if Enum.any?(errors, &(Map.get(&1, :field) == :body_markdown)) do
      "Write something to reply with — up to about 16,000 characters."
    else
      @not_posted
    end
  end

  defp conversation_refusal(_refused), do: @not_posted

  @doc """
  Questions and requests still waiting for an answer the asker called working.
  """
  def questions(conn, params) do
    page =
      Forum.list_open_questions!(
        load: [
          :author,
          :person,
          :reply_count,
          :solved,
          :view_count,
          :thread_like_count,
          :bounty_open,
          :verified_paid_usdc_atomic,
          :post_kind,
          :site,
          :tool
        ],
        page: thread_page(params)
      )

    conn
    |> merge_assigns(PatchbayWeb.PublicDocuments.page("/questions"))
    |> render(:questions,
      threads: page.results,
      more?: page.more?,
      next: if(page.more?, do: page.after)
    )
  end

  @doc """
  The genuinely funded questions, largest confirmed amount first.
  """
  def priority(conn, params) do
    page =
      Forum.list_priority_queue!(
        load: [
          :author,
          :person,
          :reply_count,
          :solved,
          :view_count,
          :thread_like_count,
          :bounty_open,
          :verified_paid_usdc_atomic,
          :post_kind,
          :site,
          :tool
        ],
        page: thread_page(params)
      )

    conn
    |> merge_assigns(PatchbayWeb.PublicDocuments.page("/priority"))
    |> render(:priority,
      threads: page.results,
      more?: page.more?,
      next: if(page.more?, do: page.after)
    )
  end

  defp thread_page(params) do
    if params["after"], do: [limit: 20, after: params["after"]], else: [limit: 20]
  end

  def retired_demo(conn, _params), do: redirect(conn, to: ~p"/start")

  def agent_setup(conn, _params) do
    conn
    |> merge_assigns(PatchbayWeb.PublicDocuments.page("/agent-setup"))
    |> render(:agent_setup,
      payments_enabled?: Board.payments_enabled?()
    )
  end

  @doc """
  The site directory: the most popular sites, then every site with its
  search. The page reads the directory live; its Markdown and JSON are the
  listing itself.
  """
  def sites(conn, params) do
    case SiteDirectory.page_number(params["page"]) do
      {:ok, number} ->
        sites_page(conn, params, get_format(conn), popular(params, number))

      {:error, {:invalid, messages}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> merge_assigns(PatchbayWeb.PublicDocuments.page(:no_such_sites_page))
        |> render_catalog(:sites_error, messages: messages)
    end
  end

  defp sites_page(conn, params, "html", popular) do
    conn
    |> merge_assigns(PatchbayWeb.PublicDocuments.page("/sites"))
    |> render(:sites,
      popular: popular,
      directory_filters: Map.take(params, ~w(q category page)),
      directory_visitor: ClientAddress.visitor_key(conn)
    )
  end

  defp sites_page(conn, params, "md", popular) do
    {:ok, directory} = SiteDirectory.page(params)

    render(conn, :sites,
      page_title: "WebMCP Site Directory",
      popular: popular,
      directory: directory
    )
  end

  defp sites_page(conn, params, "json", _popular) do
    {:ok, directory} = SiteDirectory.page(params)
    render_catalog(conn, :sites, directory: directory)
  end

  # The most popular sites open the directory's first page, before any search
  # or category narrows it; a later or narrowed page shows none.
  defp popular(params, 1) do
    if Enum.all?(~w(q category), &(String.trim(params[&1] || "") == "")),
      do: section(Board.most_popular(), "Most popular sites"),
      else: []
  end

  defp popular(_params, _later_page), do: []

  @doc """
  The one page for a site, `/<domain>`, whether or not the board knows it
  yet. Any other way of writing the site (a host under it, capitals) moves
  for good to its domain; anything that is not a public domain with a real
  ending is a missing page. `goal` and `error` in the address fill in the
  post form, and `page` names the exact page the visitor was on.

  Opening the page asks for the site's check when one is due, within the
  visitor's share (`PatchbayWeb.Forum.SiteChecks`). A site without a board
  yet is kept out of search results until its first post.
  """
  def site(conn, %{"host" => host} = params) do
    # The router lets only a real domain through to here.
    {:ok, domain} = Origin.normalize(host)

    if conn.request_path == "/" <> domain,
      do: site_page(conn, domain, params, site_hero(domain, params)),
      else: moved(conn, "/" <> domain, params)
  end

  @doc "A site's page at its earlier address, `/sites/<domain or slug>`, moved for good."
  def old_site(conn, %{"origin" => ref} = params) do
    case {Board.fetch_site_ref(ref), Origin.normalize(ref)} do
      {{:ok, site}, _domain} -> moved(conn, PatchbayWeb.Forum.BoardHTML.site_path(site), params)
      {:error, {:ok, domain}} -> moved(conn, "/" <> domain, params)
      {:error, {:error, _not_a_site}} -> raise NotFoundError
    end
  end

  @doc "A tool's page at its earlier address, `/sites/<site>/tools/<name>`, moved for good."
  def old_tool(conn, %{"origin" => ref, "name" => name} = params) do
    unless Board.tool_name?(name), do: raise(NotFoundError)
    site = site!(ref)
    moved(conn, PatchbayWeb.Forum.BoardHTML.tool_path(site, name), params)
  end

  defp moved(conn, path, params) do
    query = Map.take(params, ~w(goal error page tools_after posts_after after))
    to = if query == %{}, do: path, else: path <> "?" <> URI.encode_query(query)
    conn |> put_status(:moved_permanently) |> redirect(to: to)
  end

  # The site page's form, filled in from the link that opened the page.
  defp site_hero(domain, params) do
    page = Origin.inner_page(params["page"])

    hero(
      Hero.draft(%{
        "goal" => presence(params["goal"]),
        "site_url" => page || domain,
        "details" => presence(params["error"])
      })
    )
  end

  defp site_page(conn, domain, params, hero) do
    visitor = ClientAddress.visitor_key(conn)
    {asked, check} = SiteChecks.ask(domain, SiteChecks.current(domain), visitor, :open)
    goal = presence(params["goal"])
    error = presence(params["error"])
    page = Origin.inner_page(params["page"])
    ask = ask_call(domain, page, goal, error)

    case board_for(conn, domain, params) do
      {:ok, board} ->
        site_name = (board.site && board.site.display_name) || domain

        conn
        |> then(&if(board.site, do: &1, else: put_resp_header(&1, "x-robots-tag", "noindex")))
        |> render(
          :site,
          Map.merge(board, %{
            page_title: site_name,
            page_description:
              "#{site_name}: what agents asked about its tools, the fixes that worked, and the tools an agent can use there.",
            domain: domain,
            check: check,
            check_session: %{
              "domain" => domain,
              "limited" => asked == :limited,
              "tools_after" => params["tools_after"],
              "ask" => ask
            },
            refresh_session: board.site && %{"origin" => board.site.origin, "visitor" => visitor},
            standing: board.site && Board.site_standing(board.site),
            agent_offers: Patchbay.Offers.Serving.for_site(board.site),
            posts_cursor: params["posts_after"],
            earned_tips: Board.earned_tips(Enum.map(board.posts, & &1.author)),
            ask: ask,
            directory: FixCheck.directory?(conn),
            hero: hero
          })
        )

      {:error, :invalid_posts_cursor} ->
        expired_posts_page(conn, "/" <> domain)
    end
  end

  # The board's posts for the site, and its tools for the Markdown page; the
  # HTML page's tools live in its For agents panel (SiteCheckLive). A site
  # without a board has neither.
  defp board_for(conn, domain, params) do
    format = get_format(conn)

    case Board.fetch_site(domain) do
      {:ok, site} ->
        with {:ok, posts, next_posts} <- Board.site_threads(site, params["posts_after"]) do
          {:ok,
           Map.merge(
             %{site: site, posts: posts, next_posts: next_posts},
             inventory(format, site, params)
           )}
        end

      :error ->
        {:ok, Map.merge(%{site: nil, posts: [], next_posts: nil}, inventory(format, nil, params))}
    end
  end

  defp inventory("md", nil, _params), do: %{tools: [], next_tools: nil}

  defp inventory("md", site, params) do
    {tools, next_tools} = Board.inventory(site, inventory_cursor(params["tools_after"]))
    %{tools: tools, next_tools: next_tools}
  end

  # The HTML page's panel reads the tools itself; the address is held to the
  # same rule as the Markdown page's.
  defp inventory(_html, _site, params) do
    inventory_cursor(params["tools_after"])
    %{}
  end

  # The arguments for ask_question, with the agent's own words where it gave
  # them and a capitalised blank where it did not.
  defp ask_call(domain, page, goal, error) do
    Jason.OrderedObject.new(
      site: domain,
      page_url: page || "https://THE-EXACT-PAGE-YOU-WERE-ON",
      title: if(goal, do: String.slice(goal, 0, 100), else: "WHAT YOU WERE TRYING TO DO"),
      body_markdown:
        "I am on #{domain}, trying to #{goal || "WHAT YOU WERE TRYING TO DO"}.\n\n" <>
          "What happened: #{error || "WHAT HAPPENED"}\n\nWhat I tried: WHAT YOU TRIED"
    )
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp presence(_absent), do: nil

  # A tool page continues from a tool name; anything that could not name a
  # tool is a missing page, not a query.
  defp inventory_cursor(nil), do: nil

  defp inventory_cursor(name) do
    if Board.tool_name?(name), do: name, else: raise(NotFoundError)
  end

  # A continuation that names no page any more sends the reader back to the
  # first page of posts, and says so, rather than showing an empty list.
  defp expired_posts_page(conn, path) do
    conn
    |> put_flash(:error, "That page of posts has expired. Showing the first page.")
    |> redirect(to: path <> "#pb-site-posts")
  end

  def tool(conn, %{"host" => host, "name" => name} = params) do
    # Checked before any lookup, so a malformed segment is a missing page
    # rather than a query the database refuses.
    unless Board.tool_name?(name), do: raise(NotFoundError)
    site = site!(host)

    if host == site.origin,
      do: tool_page(conn, site, name, params),
      else: moved(conn, PatchbayWeb.Forum.BoardHTML.tool_path(site, name), params)
  end

  defp tool_page(conn, site, name, params) do
    with {:ok, history} <- Board.tool_history(site, name, params["after"]),
         {:ok, current_tool} <- history_header(site, name, params["after"], history),
         {:ok, posts, next_posts} <- Board.ranked_posts(site, name, params["posts_after"]) do
      render_tool(conn, site, name, params, history, current_tool, {posts, next_posts})
    else
      {:error, :invalid_posts_cursor} ->
        expired_posts_page(
          conn,
          PatchbayWeb.Forum.BoardHTML.tool_path(site, name)
        )

      {:error, reason} ->
        conn
        |> put_status(if(reason == :invalid_cursor, do: 400, else: 503))
        |> merge_assigns(PatchbayWeb.PublicDocuments.page(:tool_history_unavailable))
        |> render_catalog(:tool_error,
          site: site,
          name: name,
          invalid_cursor?: reason == :invalid_cursor
        )
    end
  end

  defp history_header(_site, _name, nil, history), do: {:ok, List.first(history.versions)}

  defp history_header(site, name, _cursor, _history) do
    with {:ok, latest} <- PatchbayWeb.Forum.ToolHistory.page(site, name, nil, 1) do
      {:ok, List.first(latest.versions)}
    end
  end

  defp render_tool(conn, site, name, params, history, current_tool, {posts, next_posts}) do
    versions = history.versions

    if is_nil(current_tool), do: raise(NotFoundError)
    reports = Board.reports_by_version(versions)
    priority_reports = Board.priority_reports(versions)

    render_catalog(conn, :tool,
      page_title: "#{name} on #{site.display_name || site.origin}",
      page_description:
        "#{name} on #{site.display_name || site.origin}: what the tool does, how it changed, and what agents reported when they used it.",
      site: site,
      tool_name: name,
      current_tool: current_tool,
      evidence: PatchbayWeb.Forum.ToolEvidence.levels(site, name),
      comparison_versions: history.comparison_versions,
      pagination: history.pagination,
      history_cursor: params["after"],
      versions: versions,
      more?: history.pagination.has_more,
      reports: reports,
      priority_reports: priority_reports,
      posts: posts,
      posts_cursor: params["posts_after"],
      next_posts: next_posts,
      earned_tips:
        Board.earned_tips(
          Board.authors(Enum.concat(Map.values(reports))) ++
            Enum.map(priority_reports, & &1.author) ++ Enum.map(posts, & &1.author)
        )
    )
  end

  @doc """
  One report and a page of its replies: the opening page, or the page a
  continuation from this board or from the API names.
  """
  def report(conn, %{"id" => id} = params) do
    :ok = id |> fetch_report!() |> Board.record_view(conn.assigns)
    show_report(conn, id, params, [])
  end

  def post(conn, params), do: report(conn, params)

  @doc """
  The asker takes the bounty they put up back off the board.

  The control that leads here is always live for the asker, so every press
  reaches Base and Base decides. Base refuses before the thirty days are up,
  which is the ordinary answer and is said plainly on the page.
  """
  def refund(conn, %{"id" => id}) do
    case PriorityRefund.run(id, conn.assigns.current_profile) do
      {:ok, %{escrow_refund_tx_hash: hash}} when is_binary(hash) ->
        redirect(conn, to: ~p"/reports/#{id}" <> "#patchbay-escrow")

      {:ok, _refused} ->
        show_report(conn, id, %{},
          refund_problem:
            "Base would not take that request. A bounty can only be taken back 30 days " <>
              "after it was recorded, and nothing has moved."
        )

      {:error, failure} ->
        show_report(conn, id, %{}, refund_problem: refund_refusal(failure))
    end
  end

  # A refusal from the resource already says what a reader needs to know, so it
  # is passed on as it is; anything else is said plainly.
  defp refund_refusal(%Ash.Error.Invalid{errors: [%{message: message} | _rest]})
       when is_binary(message) do
    message
  end

  defp refund_refusal(%Ash.Error.Forbidden{}) do
    "Only the person who put this money up can take it back."
  end

  defp refund_refusal(_failure), do: "That money could not be taken back."

  @doc """
  One person's reply, written in the form on the report page.

  The page is the only way a person can reply, and a person replies under their
  own name, so a visitor who is not signed in is told so on the page rather than
  being sent anywhere. Whatever they typed is still on screen when they are, on
  the page of replies they were reading; if that page can no longer be shown,
  it is still on screen on the page that says so. A posted reply is the newest
  on its thread, so the person is taken to the page that ends on it; if that
  page cannot be found once the reply is saved, the page says the reply was
  posted and leads back to the report. The reply is never posted twice.

  A request that is not shaped the way the form sends a reply is refused
  before anything is written, and whatever in it a person could have typed
  is still on screen.
  """
  def create_reply(conn, %{"id" => id} = params) do
    # Read before the write, so nothing the page needs is read after it.
    report = fetch_report!(id)

    with {:ok, draft} <- reply_draft(params["reply"]),
         {:ok, posted} <- add_reply(conn, report, draft) do
      landing(conn, report, posted)
    else
      {:error, problem} -> show_report(conn, id, params, reply_problem: problem)
    end
  end

  # What the form sends and nothing else: a verdict and a note, each a string
  # or left out. Anything shaped differently did not come from the form, so it
  # is refused without a write; the fields that are strings stay on screen.
  @reply_fields ~w(verdict note)

  defp reply_draft(nil), do: {:ok, %{}}

  defp reply_draft(reply) when is_map(reply) do
    {typed, malformed} =
      reply
      |> Map.take(@reply_fields)
      |> Map.split_with(fn {_field, value} -> is_binary(value) or is_nil(value) end)

    if map_size(malformed) == 0,
      do: {:ok, typed},
      else: {:error, %{said: @not_posted, draft: typed}}
  end

  defp reply_draft(_reply), do: {:error, %{said: @not_posted, draft: %{}}}

  defp landing(conn, report, posted, door \\ :reports) do
    case Board.page_ending_at(posted) do
      {:ok, cursor} ->
        redirect(conn, to: replies_path(door, report.id, cursor))

      {:error, failure} ->
        Logger.warning("Reply posted but its page was not read: #{inspect(error_type(failure))}")

        conn
        |> merge_assigns(PatchbayWeb.PublicDocuments.page(:reply_posted))
        |> render(:report_error,
          report: report,
          problem: :posted_unread,
          cursor: nil,
          reply_problem: nil
        )
    end
  end

  defp replies_path(:reports, id, nil), do: ~p"/reports/#{id}" <> "#patchbay-replies"
  defp replies_path(:posts, id, nil), do: ~p"/posts/#{id}" <> "#patchbay-replies"

  defp replies_path(:reports, id, cursor),
    do: ~p"/reports/#{id}?after=#{cursor}" <> "#patchbay-replies"

  defp replies_path(:posts, id, cursor),
    do: ~p"/posts/#{id}?after=#{cursor}" <> "#patchbay-replies"

  defp add_reply(%{assigns: %{current_profile: nil}}, _report, draft) do
    {:error,
     %{
       said: "Sign in to reply here. Your reply keeps the name you chose for yourself.",
       draft: draft
     }}
  end

  # The reply is a person's, under their own name, and it is counted against
  # their account's hourly share of replies like one the page's tools post.
  defp add_reply(conn, report, draft) do
    session_id = conn.assigns.forum_session_id

    input = %{
      report_id: report.id,
      browser_session_id: session_id,
      verdict: draft["verdict"],
      note: draft["note"]
    }

    admitted =
      PostingBudget.admit_reply(
        conn.assigns.current_profile,
        PostingCheck.verdict_reply(draft["verdict"], draft["note"]),
        fn ->
          Forum.add_human_reply(input, actor: conn.assigns.current_profile)
        end
      )

    case admitted do
      {:ok, reply} ->
        {:ok, reply}

      {:error, refused} ->
        {:error, %{said: not_admitted(refused) || refusal(refused), draft: draft}}
    end
  end

  # An Ash refusal names fields a reader never sees, so the form says what to do
  # about the two things a person can actually get wrong.
  defp refusal(%Ash.Error.Invalid{errors: errors}) do
    cond do
      Enum.any?(errors, &(Map.get(&1, :field) == :verdict)) ->
        "Say whether the tool worked before you post."

      Enum.any?(errors, &(Map.get(&1, :field) == :note)) ->
        "That reply is too long. Keep it under 500 characters."

      true ->
        @not_posted
    end
  end

  defp refusal(_refused), do: @not_posted

  # A missing report is not on the board; a bad continuation and a reply read
  # that fails are each said for what they are, never shown as an empty thread.
  # A reply refused on the way to either page stays on screen there, on a form
  # that carries the page only while that page can still be shown.
  # A Techtree Result's discussion shows what Techtree says of it now.
  defp techtree_result(%{techtree_digest: nil}), do: nil
  defp techtree_result(%{techtree_digest: digest}), do: Patchbay.Techtree.fetch_result(digest)

  defp show_report(conn, id, params, problems) do
    report = fetch_report!(id)
    filter = if params["replies"] in ["solution", "official"], do: params["replies"], else: "all"

    with {:ok, keyset} <- ReplyCursor.verify(report.id, params["after"]),
         {:ok, replies, next_cursor} <- Board.replies(report, keyset, filter) do
      render(conn, :report,
        page_title: PatchbayWeb.Forum.BoardHTML.post_title(report),
        page_description: PatchbayWeb.Forum.BoardHTML.post_description(report),
        # The thread answers at /posts/:id and /reports/:id; the first is its address.
        canonical_path: ~p"/posts/#{report.id}",
        page_data: [PatchbayWeb.Forum.BoardHTML.thread_data(report, replies)],
        report: report,
        answer: Board.answer(report),
        agent_offers: Patchbay.Offers.Serving.for_site(report.site),
        following: followed_sites(conn),
        reply_filter: filter,
        receipt: Board.receipt(report),
        replies: replies,
        replies_cursor: params["after"],
        next_cursor: next_cursor,
        reply_problem: Keyword.get(problems, :reply_problem),
        refund_problem: Keyword.get(problems, :refund_problem),
        liked: Board.liked(report, replies, conn.assigns.current_profile),
        earned_tips: Board.earned_tips([report.author | Enum.map(replies, & &1.author)]),
        techtree: techtree_result(report)
      )
    else
      {:error, :invalid_cursor} ->
        conn
        |> put_status(:bad_request)
        |> merge_assigns(PatchbayWeb.PublicDocuments.page(:replies_unavailable))
        |> render(:report_error,
          report: report,
          problem: :invalid_cursor,
          cursor: nil,
          reply_problem: Keyword.get(problems, :reply_problem)
        )

      {:error, failure} ->
        Logger.warning("Report replies unavailable: #{inspect(error_type(failure))}")

        conn
        |> put_status(:service_unavailable)
        |> merge_assigns(PatchbayWeb.PublicDocuments.page(:replies_unavailable))
        |> render(:report_error,
          report: report,
          problem: :unavailable,
          cursor: params["after"],
          reply_problem: Keyword.get(problems, :reply_problem)
        )
    end
  end

  defp error_type(failure) when is_struct(failure), do: failure.__struct__
  defp error_type(failure), do: failure

  # A field left out of a form stays out of the write: nil is not a value here,
  # and would otherwise override an action's own defaults.
  defp without_nils(attrs) do
    Map.reject(attrs, fn {_key, value} -> is_nil(value) end)
  end

  defp fetch_report!(id) do
    case Board.fetch_report(id) do
      {:ok, report} -> report
      :error -> raise NotFoundError
    end
  end

  defp site!(origin) do
    case Board.fetch_site_ref(origin) do
      {:ok, site} -> site
      :error -> raise NotFoundError
    end
  end

  defp render_catalog(conn, template, assigns) do
    if get_format(conn) == "json" do
      payload = apply(PatchbayWeb.Forum.BoardJSON, template, [Map.new(assigns)])

      if byte_size(Jason.encode!(payload)) <= 256 * 1024 do
        json(conn, payload)
      else
        conn
        |> put_status(:internal_server_error)
        |> json(
          PatchbayWeb.ApiError.body(
            "response_too_large",
            "This catalog page could not be returned intact.",
            "Read the website, or use /forum/tool-history with limit=1 for a tool's schemas."
          )
        )
      end
    else
      render(conn, template, assigns)
    end
  end
end
