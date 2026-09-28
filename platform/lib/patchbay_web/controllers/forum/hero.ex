defmodule PatchbayWeb.Forum.Hero do
  @moduledoc """
  The one form at the top of the home page. It sends what the person is
  trying to do, the site, up to five of the site's tools they picked and,
  under Add details, what happened, the kind of post, tags and pictures.
  The same words either ask Jev for a fix or become a forum post: what they
  are trying to do is the post's title, the details its body, and the
  address they typed the exact page it was on.
  """

  alias Patchbay.Forum.Origin
  alias Patchbay.Forum.PostPicture

  @max_title 160

  @type draft :: %{String.t() => String.t() | [String.t()]}

  @doc """
  The form's fields as sent. Opened from a link instead, the site, a tool
  and what to ask about can be filled in already.
  """
  @spec draft(term()) :: draft()
  def draft(%{} = params) do
    %{
      "goal" => text(params["goal"]),
      "site_url" => text(params["site_url"]),
      "tools" => names(params["tools"]),
      "details" => text(params["details"]),
      "thread_kind" => text(params["thread_kind"]),
      "topic_tags" => text(params["topic_tags"])
    }
  end

  def draft(_absent), do: draft(%{})

  @doc "The form opened from a link that names the site, a tool or what to ask."
  @spec prefilled(map()) :: draft()
  def prefilled(params) do
    draft(%{
      "goal" => params["goal"],
      "site_url" => params["site"],
      "tools" => List.wrap(params["tool"])
    })
  end

  @doc """
  The forum post the form's words make, in the fields a question is posted
  with, or why they cannot be one.
  """
  @spec thread(draft()) :: {:ok, map()} | {:error, %{said: String.t()}}
  def thread(draft) do
    if String.length(draft["goal"]) > @max_title do
      {:error,
       %{
         said:
           "A forum post's title is what you are trying to do, in up to #{@max_title} characters. Put the rest under Add details."
       }}
    else
      {:ok,
       %{
         "site" => draft["site_url"],
         "title" => draft["goal"],
         "body_markdown" => presence(draft["details"]),
         "tools" => draft["tools"],
         "page_url" => page_url(draft["site_url"]),
         "topic_tags" => tags(draft["topic_tags"]),
         "thread_kind" => presence(draft["thread_kind"])
       }}
    end
  end

  @doc """
  The pictures sent with a post, read from the uploads: at most three, each
  up to 3 MB. An empty picture field sends nothing.
  """
  @spec pictures(term()) :: {:ok, [binary()]} | {:error, %{said: String.t()}}
  def pictures(uploads) when is_list(uploads) do
    chosen = Enum.filter(uploads, &match?(%Plug.Upload{filename: name} when name != "", &1))

    cond do
      length(chosen) > PostPicture.max_per_post() ->
        {:error, %{said: "Add up to #{PostPicture.max_per_post()} pictures."}}

      Enum.any?(chosen, &(File.stat!(&1.path).size > PostPicture.max_bytes())) ->
        {:error, %{said: "Each picture can be up to 3 MB."}}

      true ->
        {:ok, Enum.map(chosen, &File.read!(&1.path))}
    end
  end

  def pictures(_none), do: {:ok, []}

  @doc "Whether any of the optional details already hold something."
  @spec details?(draft()) :: boolean()
  def details?(draft),
    do: Enum.any?(~w(details thread_kind topic_tags), &(draft[&1] not in ["", "question"]))

  # The exact page, when the address names more of the site than its home.
  defp page_url(address) do
    case Origin.address(address) do
      {:ok, page} -> if URI.parse(page).path == "/", do: nil, else: page
      {:error, _unreadable} -> nil
    end
  end

  # Tags arrive as one comma-separated line and are split here, where the
  # form ends.
  defp tags(line),
    do: line |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp presence(""), do: nil
  defp presence(value), do: value

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_other), do: ""

  defp names(names) when is_list(names), do: for(name <- names, is_binary(name), do: name)
  defp names(_none), do: []
end
