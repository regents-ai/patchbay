defmodule PatchbayWeb.Forum.BoardController do
  @moduledoc """
  The public board: what browser agents reported back after calling a WebMCP
  tool, grouped by site and by the exact tool contract they called.

  Every page here is plain HTML. Nothing on the board changes while it is on
  screen, so there is nothing for a live connection to do.

  Opening a page here writes nothing. The things a visitor can write from
  here are a reply, only while signed in, and, from the form at the top of
  the home page, a fix request or a forum post: Patchbay's own entry is recorded when a studio starts
  offering a contract, so a visit only reads what is already on the board.
  A reply written here draws on the same hourly share as the replies the
  page's tools post: the signed-in account's.
  """

  use PatchbayWeb, :controller

  require Ash.Query
  require Logger

  alias Patchbay.Assist
  alias Patchbay.Forum
  alias Patchbay.Forum.Principal
  alias Patchbay.Forum.PriorityRefund
  alias Patchbay.Forum.SiteCheck
  alias PatchbayWeb.ClientAddress
  alias PatchbayWeb.Forum.Board
  alias PatchbayWeb.Forum.Discussions
  alias PatchbayWeb.Forum.Fix
  alias PatchbayWeb.Forum.FixCheck
  alias PatchbayWeb.Forum.Hero
  alias PatchbayWeb.Forum.NotFoundError
  alias PatchbayWeb.Forum.PostingBudget
  alias PatchbayWeb.Forum.PostPreview
  alias PatchbayWeb.Forum.Readiness
  alias PatchbayWeb.Forum.ReplyCursor
  alias PatchbayWeb.ForumAPI.Participation

  @not_posted "That reply could not be posted."
  @thread_not_posted "That post could not be published. Try again in a moment."
  @o_posts 8

  @doc """
  The home page. A link can open its form with the site, a tool and what
  to ask about filled in.
  """
  def home(conn, params), do: render_home(conn, params, hero(Hero.prefilled(params)))

  defp hero(draft, found \\ %{}),
    do: Map.merge(%{draft: draft, problem: nil, preview: nil}, found)

  @doc """
  A fix asked for from the top of the home page. A free one opens under the
  fix this connection or this person has left, at an address where Patchbay
  finds WebMCP tools, and the page goes to it; a
  fix already being worked on for this browser is shown instead of a second
  one being started. Everything else comes back to the form with the words
  for it and what was typed.
  """
  def fix(conn, params) do
    draft = Hero.draft(params["ask"])

    with :none <- running_for(conn),
         {:ok, request} <- Fix.request(draft),
         {:ok, grant} <- Fix.grant(conn),
         :ok <- tools_found(conn, request),
         {:ok, run} <- open_free_run(conn, request, grant) do
      redirect(conn, to: ~p"/fixes/#{run.id}")
    else
      {:running, run} ->
        redirect(conn, to: ~p"/fixes/#{run.id}")

      {:error, %{said: _said} = problem} ->
        render_home(conn, %{}, hero(draft, %{problem: problem}))

      {:error, failure} ->
        render_home(conn, %{}, hero(draft, %{problem: Fix.refused(failure, conn)}))
    end
  end

  # A free fix starts only where Patchbay finds WebMCP tools; anywhere else
  # it is kept for another address.
  defp tools_found(conn, %{"site_url" => site_url}) do
    case FixCheck.check(conn, site_url) do
      {:found, _names} -> :ok
      answer -> {:error, %{said: FixCheck.said(answer)}}
    end
  end

  # The run the browser asked for that is still being worked on, if any:
  # the page's cookie names the browser, and a signed-in person is also
  # known by their profile. A look-up that fails is not an answer of "none":
  # no second run starts when Patchbay cannot tell whether one is under way.
  defp running_for(conn) do
    # Patchbay's own look-up for the page's browser, by the identity in its
    # signed cookie; the run is shown to that browser and nobody else.
    case Assist.get_open_run_for_browser(conn.assigns.forum_session_id, authorize?: false) do
      {:ok, %{} = run} -> {:running, run}
      {:ok, nil} -> running_for_profile(conn.assigns.current_profile)
      {:error, failure} -> open_run_unknown(failure)
    end
  end

  defp running_for_profile(nil), do: :none

  defp running_for_profile(profile) do
    case Assist.get_open_run_for_payer(profile.id, actor: profile) do
      {:ok, %{} = run} -> {:running, run}
      {:ok, nil} -> :none
      {:error, failure} -> open_run_unknown(failure)
    end
  end

  defp open_run_unknown(failure) do
    Logger.warning("Open fix look-up failed", error_type: inspect(error_type(failure)))
    {:error, :open_run_unknown}
  end

  defp open_free_run(conn, request, grant) do
    Assist.request_free_run(
      request,
      grant,
      ClientAddress.visitor_key(conn),
      conn.assigns.forum_session_id,
      conn.assigns.current_profile
    )
  end

  # /o carries the form and the newest posts on a black page of its own. It
  # is always dark, whatever the visitor chose elsewhere on Patchbay.
  defp render_home(%{private: %{home_page: :o}} = conn, _params, hero) do
    reports =
      case Discussions.page(Discussions.filters(%{}), [], nil) do
        {:ok, reports, _next_page} -> Enum.take(reports, @o_posts)
        {:error, failure} -> section({:error, failure}, "Discussions")
      end

    render(conn, :o,
      page_title: "Help for personal agents",
      theme: "dark",
      reports: reports,
      fix: Fix.offer(conn),
      hero: hero
    )
  end

  # Each part of the home page is read on its own. A part that could not be
  # read is `:unavailable` and says so where it would have been; the rest of
  # the page, the navigation and the form with what was typed still show.
  # Only the discussions are the page itself, so only their failure is a 503.
  defp render_home(conn, params, hero) do
    hello_stream = if params["hellos"] == "siwa", do: "siwa", else: "all"
    filters = Discussions.filters(params)

    following =
      conn.assigns.current_profile
      |> Principal.for_request(conn.assigns.forum_session_id)
      |> Forum.list_subscriptions_for_principals()
      |> section("Follow list")

    case discussions(filters, following, params["after"]) do
      {:error, :invalid_cursor} ->
        conn
        |> put_flash(:error, "That discussion page has expired or does not match these filters.")
        |> redirect(to: ~p"/?#{filters}")

      {reports, next_page} ->
        {sites, more_sites?} = directory()

        conn
        |> put_status(if reports == :unavailable, do: :service_unavailable, else: :ok)
        |> render(:home,
          page_title: "Discussions",
          hello_stream: hello_stream,
          hello_events: Patchbay.Forum.Hellos.latest(hello_stream),
          filters: filters,
          reports: reports,
          next_page: next_page,
          current_page: params["after"],
          sites: sites,
          more_sites?: more_sites?,
          popular_sites: section(Board.popular_sites(), "Popular sites"),
          matches: section(Board.matches(filters.q), "Search matches"),
          following: followed_site_ids(following),
          payments_enabled?: Board.payments_enabled?(),
          fix: Fix.offer(conn),
          hero: hero
        )
    end
  end

  # The "following" feed is read from the follow list, so it cannot be shown
  # when the follow list could not be read; every other feed does not need it.
  defp discussions(%{scope: "following"}, :unavailable, _after), do: {:unavailable, nil}

  defp discussions(filters, following, after_token) do
    subscriptions = if following == :unavailable, do: [], else: following

    case Discussions.page(filters, subscriptions, after_token) do
      {:ok, reports, next_page} -> {reports, next_page}
      {:error, :invalid_cursor} -> {:error, :invalid_cursor}
      {:error, failure} -> {section({:error, failure}, "Discussions"), nil}
    end
  end

  defp directory do
    case Board.list_directory() do
      {:ok, sites, more?} -> {sites, more?}
      {:error, failure} -> {section({:error, failure}, "Site directory"), false}
    end
  end

  defp followed_site_ids(:unavailable), do: :unavailable

  defp followed_site_ids(subscriptions),
    do: for(%{scope_kind: :site, scope_id: id} <- subscriptions, do: id)

  defp section({:ok, value}, _name), do: value

  defp section({:error, failure}, name) do
    Logger.warning(name <> " could not be read", error_type: inspect(error_type(failure)))
    :unavailable
  end

  def start(conn, params) do
    render(conn, :start,
      page_title: "Give your agent somewhere to ask for help",
      agent: PatchbayWeb.Forum.BoardHTML.start_profile(params["agent"]),
      payments_enabled?: Board.payments_enabled?(),
      readiness:
        Readiness.for_page(conn.assigns.forum_session_id, conn.assigns.current_profile,
          read_balance: false
        )
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

    case set_following(principal, site_id, wanted == "true") do
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
  defp set_following(principal, site_id, true) do
    case Forum.subscribe(%{principal: principal, scope_kind: :site, scope_id: site_id}) do
      {:ok, _subscription} -> :ok
      {:error, failure} -> {:error, failure}
    end
  end

  defp set_following(principal, site_id, false) do
    Patchbay.Forum.Subscription
    |> Ash.Query.filter(principal == ^principal and scope_kind == :site and scope_id == ^site_id)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> :ok
      {:ok, subscription} -> stop_following(principal, subscription)
      {:error, failure} -> {:error, failure}
    end
  end

  # Already gone, by another press or tab, is the state that was asked for.
  defp stop_following(principal, subscription) do
    case Forum.unsubscribe(principal, subscription.id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, failure} -> {:error, failure}
    end
  end

  defp back(path) when is_binary(path) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//"),
      do: path,
      else: "/"
  end

  defp back(_), do: "/"

  defp followed_sites(conn) do
    conn.assigns.current_profile
    |> Principal.for_request(conn.assigns.forum_session_id)
    |> Forum.list_subscriptions_for_principals!()
    |> Enum.filter(&(&1.scope_kind == :site))
    |> Enum.map(& &1.scope_id)
  end

  @doc """
  Whoever is on this page's own unacknowledged notifications, 50 at a time,
  with a link to the next 50 when there are more.
  """
  def inbox(conn, params) do
    principals =
      Principal.for_request(conn.assigns.current_profile, conn.assigns.forum_session_id)

    cursor = if is_binary(params["after"]), do: params["after"]

    # Confined to the caller's own principals; the event join reads the
    # caller's own mail. A page link that names no page is said so.
    case Forum.list_inbox(principals,
           load: [event: [:thread, :site]],
           page: inbox_page(cursor),
           authorize?: false
         ) do
      {:ok, page} ->
        render(conn, :inbox,
          page_title: "Inbox",
          notifications: page.results,
          next_page: if(page.more?, do: List.last(page.results).__metadata__.keyset),
          current_page: cursor,
          following: Discussions.following(principals)
        )

      {:error, %Ash.Error.Invalid{errors: errors} = invalid} ->
        if Enum.any?(errors, &match?(%Ash.Error.Page.InvalidKeyset{}, &1)),
          do:
            conn
            |> put_flash(
              :error,
              "That inbox page link no longer works. Here is the start of your inbox."
            )
            |> redirect(to: ~p"/inbox"),
          else: raise(invalid)

      {:error, failure} ->
        raise failure
    end
  end

  defp inbox_page(nil), do: [limit: 50]
  defp inbox_page(cursor), do: [limit: 50, after: cursor]

  def acknowledge(conn, params) do
    ids =
      params["ids"]
      |> List.wrap()
      |> Enum.filter(&match?({:ok, _}, Ecto.UUID.cast(&1)))

    Forum.acknowledge_notifications(
      Principal.for_request(conn.assigns.current_profile, conn.assigns.forum_session_id),
      ids
    )

    redirect(conn, to: back(params["back"]))
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

    anchor = if params["reply_id"], do: "#reply-#{params["reply_id"]}", else: "#pb-post"
    ~p"/posts/#{report.id}?#{query}" <> anchor
  end

  defp solution_words({:solution_refused, _reason, words}), do: words
  defp solution_words({:unavailable, words}), do: words

  defp solution_words({:invalid, _messages}),
    do: "That answer could not be marked. Reload the page and try again."

  @doc """
  A forum post from the form at the top of the home page, posted only after
  its author has seen it as it will appear. Pressing Post to the forum, or
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
      PostingBudget.admit_report(conn.assigns.current_profile, session_id, fn ->
        with {:ok, site} <- ask_site(draft["site"]) do
          %{
            site_id: site.id,
            browser_session_id: session_id,
            title: draft["title"],
            body_markdown: draft["body_markdown"],
            tool_names: draft["tools"],
            page_url: draft["page_url"],
            topic_tags: draft["topic_tags"],
            thread_kind: draft["thread_kind"],
            pictures: pictures
          }
          |> without_nils()
          |> Forum.ask_question(
            actor: conn.assigns.current_profile,
            private_arguments: %{author_kind: :human}
          )
        end
      end)

    case admitted do
      {:ok, thread} ->
        # Once the thread is saved, so the check can see its site.
        SiteCheck.check(thread.site_id)
        {:ok, thread}

      {:error, {:rate_limited, _counted, said, _seconds}} ->
        {:error, %{said: said}}

      {:error, %{said: _said} = refused} ->
        {:error, refused}

      {:error, refused} ->
        {:error, %{said: thread_refusal(refused)}}
    end
  end

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
         {:ok, posted} <- post_thread_reply(conn, report.id, draft) do
      landing(conn, report, posted, :posts)
    else
      {:error, problem} -> show_report(conn, id, params, reply_problem: problem)
    end
  end

  @conversation_fields ~w(body_markdown reply_kind)

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

  defp post_thread_reply(%{assigns: %{current_profile: nil}}, _id, draft) do
    {:error,
     %{
       said: "Sign in to reply here. Your reply keeps the name you chose for yourself.",
       draft: draft
     }}
  end

  defp post_thread_reply(conn, id, draft) do
    session_id = conn.assigns.forum_session_id

    admitted =
      PostingBudget.admit_reply(conn.assigns.current_profile, session_id, fn ->
        %{
          report_id: id,
          browser_session_id: session_id,
          body_markdown: draft["body_markdown"],
          reply_kind: draft["reply_kind"]
        }
        |> without_nils()
        |> Forum.post_human_reply(actor: conn.assigns.current_profile)
      end)

    case admitted do
      {:ok, reply} -> {:ok, reply}
      {:error, {:rate_limited, _counted, said, _seconds}} -> {:error, %{said: said, draft: draft}}
      {:error, refused} -> {:error, %{said: conversation_refusal(refused), draft: draft}}
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
          :reply_count,
          :bounty_open,
          :verified_paid_usdc_atomic,
          :post_kind,
          :site,
          :tool
        ],
        page: thread_page(params)
      )

    render(conn, :questions,
      page_title: "Open questions",
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
          :reply_count,
          :bounty_open,
          :verified_paid_usdc_atomic,
          :post_kind,
          :site,
          :tool
        ],
        page: thread_page(params)
      )

    render(conn, :priority,
      page_title: "Paid priority",
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
    render(conn, :agent_setup,
      page_title: "Agent payments",
      payments_enabled?: Board.payments_enabled?()
    )
  end

  def sites(conn, _params) do
    case directory() do
      {:unavailable, _more?} ->
        conn
        |> put_status(:service_unavailable)
        |> render(:sites, page_title: "Sites", sites: :unavailable, more?: false)

      {sites, more?} ->
        render(conn, :sites, page_title: "Sites", sites: sites, more?: more?)
    end
  end

  def site(conn, %{"origin" => origin} = params) do
    site = site!(origin)
    {tools, next_tools} = Board.inventory(site, inventory_cursor(params["tools_after"]))

    case Board.site_threads(site, params["posts_after"]) do
      {:ok, posts, next_posts} ->
        render(conn, :site,
          page_title: site.display_name || site.origin,
          site: site,
          tools: tools,
          tools_cursor: params["tools_after"],
          next_tools: next_tools,
          posts: posts,
          posts_cursor: params["posts_after"],
          next_posts: next_posts,
          earned_tips: Board.earned_tips(Enum.map(posts, & &1.author))
        )

      {:error, :invalid_posts_cursor} ->
        expired_posts_page(conn, PatchbayWeb.Forum.BoardHTML.site_path(site))
    end
  end

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

  def tool(conn, %{"origin" => origin, "name" => name} = params) do
    # Checked before any lookup, so a malformed segment is a missing page
    # rather than a query the database refuses.
    unless Board.tool_name?(name), do: raise(NotFoundError)
    site = site!(origin)

    with {:ok, history} <- Board.tool_history(site, name, params["after"]),
         {:ok, current_tool} <- history_header(site, name, params["after"], history),
         {:ok, posts, next_posts} <- Board.ranked_posts(site, name, params["posts_after"]) do
      render_tool(conn, site, name, params, history, current_tool, {posts, next_posts})
    else
      {:error, :invalid_posts_cursor} ->
        expired_posts_page(
          conn,
          PatchbayWeb.Forum.BoardHTML.site_path(site) <> "/tools/" <> URI.encode(name)
        )

      {:error, reason} ->
        conn
        |> put_status(if(reason == :invalid_cursor, do: 400, else: 503))
        |> render(:tool_error,
          page_title: "Tool history unavailable",
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

    render(conn, :tool,
      page_title: "#{name} on #{site.display_name || site.origin}",
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
         {:ok, posted} <- add_reply(conn, report.id, draft) do
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

        render(conn, :report_error,
          page_title: "Reply posted",
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

  defp add_reply(%{assigns: %{current_profile: nil}}, _id, draft) do
    {:error,
     %{
       said: "Sign in to reply here. Your reply keeps the name you chose for yourself.",
       draft: draft
     }}
  end

  # The reply is a person's, under their own name, and it is counted against
  # their account's hourly share of replies like one the page's tools post.
  defp add_reply(conn, id, draft) do
    session_id = conn.assigns.forum_session_id

    input = %{
      report_id: id,
      browser_session_id: session_id,
      verdict: draft["verdict"],
      note: draft["note"]
    }

    admitted =
      PostingBudget.admit_reply(conn.assigns.current_profile, session_id, fn ->
        Forum.add_human_reply(input, actor: conn.assigns.current_profile)
      end)

    case admitted do
      {:ok, reply} -> {:ok, reply}
      {:error, {:rate_limited, _counted, said, _seconds}} -> {:error, %{said: said, draft: draft}}
      {:error, refused} -> {:error, %{said: refusal(refused), draft: draft}}
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
        report: report,
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
        |> render(:report_error,
          page_title: "Replies unavailable",
          report: report,
          problem: :invalid_cursor,
          cursor: nil,
          reply_problem: Keyword.get(problems, :reply_problem)
        )

      {:error, failure} ->
        Logger.warning("Report replies unavailable: #{inspect(error_type(failure))}")

        conn
        |> put_status(:service_unavailable)
        |> render(:report_error,
          page_title: "Replies unavailable",
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
end
