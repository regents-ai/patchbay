defmodule PatchbayWeb.PostFormLive do
  @moduledoc """
  The post form on the home page, each agent page and each site page's post
  window (`PatchbayWeb.Forum.Hero`), changing the page where it stands.

  What the person types reaches the form as they type it, so a press is
  answered beside the form and nothing they typed or the pictures they chose
  is lost. Post to agent forum shows the post as the public will read it,
  with anything in it that looks private; Publish post publishes exactly what
  was shown, or shows it again when it changed since. A published post opens
  its own page.

  What is wrong with a field is said under that field: what a press needs and
  is missing, a title too long once the title is left, and what Patchbay
  turns down. Typing takes a line away once the field is right. A refusal
  about no one field, such as the hourly share being used up or the post
  being read and turned away, is said beside Publish post.

  Pictures go up with the press that sends them and stay chosen through a
  refusal. One of another kind, too large or past the post's limit is not
  added, and the line under Add pictures says so.

  Publishing reads the sign-in again from the lease the form connected with,
  as a page load would, and posts as that person only.
  """
  use PatchbayWeb, :live_view

  import PatchbayWeb.Forum.BoardHTML, only: [hero_form: 1]

  alias Patchbay.Forum
  alias Patchbay.Forum.Origin
  alias Patchbay.Forum.PostAddress
  alias Patchbay.Forum.PostPicture
  alias PatchbayWeb.CurrentProfile
  alias PatchbayWeb.Forum.Hero
  alias PatchbayWeb.Forum.PostingBudget
  alias PatchbayWeb.Forum.PostPreview

  @not_posted "That post could not be published. Try again in a moment."
  @site_fix "Use the site's public address, like shop.example.com/cart."
  @signed_out "Sign in at the top of the page to post. Your post is published under the name you chose for yourself."

  # The fields a line can be said under, by the name each is sent with.
  @fields %{
    "goal" => :goal,
    "site_url" => :site,
    "details" => :details,
    "topic_tags" => :tags
  }

  # What a press is reached at when it is refused over a field: the element
  # that takes the focus, and the line that says what to fix.
  @reach %{
    goal: {"pb-fix-goal", "pb-fix-goal-errors"},
    site: {"pb-fix-site", "pb-fix-site-errors"},
    details: {"pb-hero-body", "pb-hero-body-errors"},
    pictures: {"pb-hero-pictures-add", "pb-hero-pictures-errors"},
    tags: {"pb-hero-tags", "pb-hero-tags-errors"}
  }

  @impl true
  def mount(_params, %{"home" => home, "draft" => draft} = session, socket) do
    socket =
      socket
      |> assign(
        home: home,
        window: session["window"] == true,
        directory: session["directory"] == true,
        draft: draft,
        connected: connected?(socket),
        lines: %{},
        problem: nil,
        preview: nil
      )
      |> sign_in(session)
      |> assign_new(:forum_session_id, fn -> session["forum_session_id"] end)
      |> allow_upload(:pictures,
        accept: ~w(image/png image/jpeg image/webp),
        max_entries: PostPicture.max_per_post(),
        max_file_size: PostPicture.max_bytes()
      )

    {:ok, socket, layout: false}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.hero_form
      home={@home}
      profile={@current_profile}
      directory={@directory}
      window={@window}
      draft={@draft}
      connected={@connected}
      lines={@lines}
      problem={@problem}
      preview={@preview}
      pictures={@uploads.pictures}
    />
    """
  end

  @impl true
  def handle_event("change", params, socket) do
    {:noreply,
     socket
     |> take_draft(params)
     |> changed(params["_target"])
     |> settle_pictures()}
  end

  # Leaving the title says when it is too long; typing never does.
  def handle_event("left_goal", %{"value" => value}, socket) when is_binary(value) do
    if String.length(String.trim(value)) > Hero.max_title(),
      do: {:noreply, put_line(socket, :goal, Hero.title_fix())},
      else: {:noreply, socket}
  end

  # A Remove pressed twice finds its picture already gone.
  def handle_event("remove_picture", %{"ref" => ref}, socket) when is_binary(ref) do
    if Enum.any?(socket.assigns.uploads.pictures.entries, &(&1.ref == ref)),
      do:
        {:noreply, socket |> cancel_upload(:pictures, ref) |> unpreview() |> drop_line(:pictures)},
      else: {:noreply, socket}
  end

  # The full Add pictures is the one pressed, so the line under it says why
  # and the focus stays where the person has taken it since.
  def handle_event("pictures_full", _params, socket) do
    most = PostPicture.max_per_post()
    {:noreply, put_line(socket, :pictures, "Up to #{most} pictures. Remove one to add another.")}
  end

  def handle_event("send", params, socket) do
    socket = take_draft(socket, params)

    case missing(socket.assigns.draft) do
      [] ->
        {:noreply, step(socket, params["step"])}

      [first | _rest] = stopped ->
        {:noreply, socket |> put_lines(stopped) |> reach(elem(first, 0))}
    end
  end

  # Post to agent forum, and Publish post on a post changed since it was
  # shown, show the post as it will be published.
  defp step(socket, step) do
    case Hero.thread(socket.assigns.draft) do
      {:ok, thread} ->
        if step == "post" and shown?(socket.assigns.preview, thread),
          do: publish(socket, thread),
          else: show(socket, thread)

      {:error, problem} ->
        refuse(socket, problem)
    end
  end

  defp shown?(nil, _thread), do: false
  defp shown?(preview, thread), do: preview.digest == PostPreview.digest(thread)

  defp show(socket, thread) do
    socket
    |> assign(preview: Map.put(PostPreview.build(thread), :thread, thread), problem: nil)
    |> push_event("pb:previewed", %{})
  end

  defp publish(socket, thread) do
    with {:ok, profile} <- signed_in(socket),
         {:ok, posted} <- ask_question(profile, socket, thread) do
      redirect(socket, to: PostAddress.path(posted))
    else
      {:error, problem} -> refuse(socket, problem)
    end
  end

  # Drawn with the page, the form takes the page's sign-in; connected, it reads
  # the sign-in its own socket connected with, and keeps the lease that reads it
  # again (`PatchbayWeb.CurrentProfile`).
  defp sign_in(socket, session) do
    if connected?(socket) do
      {profile, lease} = CurrentProfile.connect_lease(session)
      assign(socket, current_profile: profile, session_lease: lease)
    else
      socket |> assign_new(:current_profile, fn -> nil end) |> assign(:session_lease, nil)
    end
  end

  # The sign-in as it reads now, from the lease the form connected with.
  defp signed_in(socket) do
    case CurrentProfile.leased_profile(socket.assigns.session_lease) do
      nil -> {:error, %{said: @signed_out}}
      profile -> {:ok, profile}
    end
  end

  # The site is opened inside the admitted write, so a question refused for
  # its share or its words is rolled back together with the board it named.
  defp ask_question(profile, socket, thread) do
    pictures = pictures(socket)

    admitted =
      PostingBudget.admit_thread(
        profile,
        thread,
        fn type ->
          with {:ok, site} <- ask_site(thread["site"]) do
            {:ok,
             %{
               site_id: site.id,
               browser_session_id: socket.assigns.forum_session_id,
               title: thread["title"],
               body_markdown: thread["body_markdown"],
               tool_names: thread["tools"],
               page_url: thread["page_url"],
               topic_tags: thread["topic_tags"],
               thread_kind: type,
               pictures: pictures
             }
             |> Map.reject(fn {_field, value} -> is_nil(value) end)
             |> Forum.changeset_to_ask_question(
               actor: profile,
               private_arguments: %{author_kind: :human}
             )}
          end
        end,
        &Ash.create/1
      )

    case admitted do
      {:ok, posted} -> {:ok, posted}
      {:error, %{said: _said} = refused} -> {:error, refused}
      {:error, refused} -> {:error, refusal(refused)}
    end
  end

  # What the posting door said in its own words, or what the write refused.
  defp refusal(refused) do
    case PostingBudget.said(refused) do
      nil -> thread_refusal(refused)
      said -> %{said: said}
    end
  end

  # The pictures as chosen, in their order, read without being let go: a post
  # that is turned down keeps them chosen for the next press. The paths are
  # the files the upload wrote for this page, never a name the sender chose.
  # sobelow_skip ["Traversal.FileModule"]
  defp pictures(socket) do
    for entry <- socket.assigns.uploads.pictures.entries do
      consume_uploaded_entry(socket, entry, fn %{path: path} -> {:postpone, File.read!(path)} end)
    end
  end

  defp ask_site(site) when is_binary(site) and site != "" do
    case Origin.normalize(site) do
      {:ok, _host} ->
        case Forum.register_site(site) do
          {:ok, site} -> {:ok, site}
          {:error, _failure} -> {:error, %{said: "That site could not be opened for a question."}}
        end

      {:error, _unreadable} ->
        {:error, %{said: @site_fix, field: :site}}
    end
  end

  defp ask_site(_site), do: {:error, %{said: "Name the site the post is about.", field: :site}}

  # What the write refused, with the form field it is said under. The tools
  # are picked from a list that stops at five, so theirs is about no field a
  # person can type in.
  defp thread_refusal(%Ash.Error.Invalid{errors: errors}) do
    refused = MapSet.new(errors, &Map.get(&1, :field))

    cond do
      :title in refused ->
        %{said: "Say what you are trying to do in one short line.", field: :goal}

      :body_markdown in refused ->
        %{said: "Say what happened in up to about 16,000 characters.", field: :details}

      :tool_names in refused ->
        %{said: "Pick up to 5 of the site's tools."}

      :pictures in refused or :image in refused ->
        %{
          said:
            "Pictures can be PNG, JPEG or WebP, up to 3 MB each, and up to #{PostPicture.max_per_post()} of them.",
          field: :pictures
        }

      :page_url in refused ->
        %{said: @site_fix, field: :site}

      :topic_tags in refused ->
        %{said: "Use short words or hyphenated phrases, five at most.", field: :tags}

      true ->
        %{said: @not_posted}
    end
  end

  defp thread_refusal(_refused), do: %{said: @not_posted}

  # The form's words as they stand. A post changed since it was shown is
  # shown again before it is published, so the preview and anything said
  # beside it go.
  defp take_draft(socket, params) do
    draft = Hero.draft(params["ask"])

    if draft == socket.assigns.draft,
      do: socket,
      else: socket |> assign(draft: draft) |> unpreview()
  end

  defp unpreview(socket), do: assign(socket, preview: nil, problem: nil)

  # What the press needs and the form is missing, in the order the fields stand.
  defp missing(draft) do
    Enum.reject([goal: empty(draft, :goal), site: empty(draft, :site)], &is_nil(elem(&1, 1)))
  end

  defp empty(%{"goal" => ""}, :goal), do: "Describe the issue."
  defp empty(%{"site_url" => ""}, :site), do: "Name the site."
  defp empty(_draft, _field), do: nil

  # A field's line goes once what it holds is right: filled in, and a title
  # no longer than a title may be. A line Patchbay gave for what was sent
  # goes with the first change. Pictures chosen take away the preview, as
  # any change to the post does, and the last word about the pictures.
  defp changed(socket, ["ask", name]) when is_map_key(@fields, name) do
    field = @fields[name]
    draft = socket.assigns.draft

    if empty(draft, field) == nil and not overlong?(draft, field),
      do: drop_line(socket, field),
      else: socket
  end

  defp changed(socket, ["pictures"]), do: socket |> unpreview() |> drop_line(:pictures)
  defp changed(socket, _target), do: socket

  defp overlong?(draft, :goal), do: String.length(draft["goal"]) > Hero.max_title()
  defp overlong?(_draft, _field), do: false

  # Pictures that cannot go are let go as soon as they arrive, and the line
  # under Add pictures says why: another kind, too large, or past the post's
  # limit, where the first ones chosen are kept.
  defp settle_pictures(socket) do
    upload = socket.assigns.uploads.pictures
    {fitting, unfit} = Enum.split_with(upload.entries, & &1.valid?)
    {_kept, extra} = Enum.split(fitting, upload.max_entries)

    case unfit ++ extra do
      [] ->
        socket

      dropped ->
        errors = Enum.flat_map(unfit, &upload_errors(upload, &1))
        most = upload.max_entries

        said =
          [
            :not_accepted in errors && "Pictures can be PNG, JPEG or WebP.",
            :too_large in errors &&
              "Each picture can be up to #{megabytes(upload.max_file_size)} MB.",
            extra != [] && "Up to #{most} pictures. The first #{most} are kept."
          ]
          |> Enum.filter(&is_binary/1)
          |> Enum.join(" ")

        dropped
        |> Enum.reduce(socket, &cancel_upload(&2, :pictures, &1.ref))
        |> put_line(:pictures, said)
    end
  end

  defp megabytes(bytes), do: div(bytes, 1024 * 1024)

  # A refusal over one field is said under it, which takes the focus; one
  # about no field is said beside Publish post.
  defp refuse(socket, %{field: field, said: said}),
    do: socket |> put_line(field, said) |> reach(field)

  defp refuse(socket, %{said: _said} = problem), do: assign(socket, problem: problem)

  defp reach(socket, field) do
    {to, line} = @reach[field]
    push_event(socket, "pb:reach", %{to: to, line: line})
  end

  defp put_lines(socket, said),
    do: Enum.reduce(said, socket, fn {field, words}, socket -> put_line(socket, field, words) end)

  defp put_line(socket, field, words), do: update(socket, :lines, &Map.put(&1, field, words))
  defp drop_line(socket, field), do: update(socket, :lines, &Map.delete(&1, field))
end
