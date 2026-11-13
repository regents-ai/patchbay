defmodule PatchbayWeb.Forum.Hero do
  @moduledoc """
  The one form at the top of the home page. It sends what the person is
  trying to do, the site, up to five of the site's tools they picked and,
  under its details, what happened, the kind of post, tags and pictures.
  The words become a forum post: what they are trying to do is the post's
  title, the details its body, and the address they typed the exact page it
  was on.
  """

  alias Patchbay.Forum.Origin
  alias Patchbay.Forum.PostPicture

  @max_title 160

  @type draft :: %{String.t() => String.t() | [String.t()]}

  @typedoc """
  Why a post was turned down, in words that say what to do. `field` names the
  form field the words belong under; a refusal that is about no one field has
  none.
  """
  @type problem :: %{required(:said) => String.t(), optional(:field) => atom()}

  @doc "The longest title a post takes, counted in characters."
  @spec max_title() :: pos_integer()
  def max_title, do: @max_title

  @doc "What to do about a title that is too long."
  @spec title_fix() :: String.t()
  def title_fix, do: "Use #{@max_title} characters or fewer. Put the rest in Steps."

  @doc """
  The form's fields as sent. Opened from a link instead, the site, a tool,
  what to ask about and tags can be filled in already.
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

  @doc """
  The form opened from a link: `site_url`, `tool`, `goal` and `topic_tags`
  fill the form's fields. They narrow nothing, so a link can name a site with
  no questions yet; a link that also wants the questions under the form
  narrowed to that site sends `site` as well (`BoardHTML.ask_path/1`).
  """
  @spec prefilled(map()) :: draft()
  def prefilled(params) do
    draft(%{
      "goal" => params["goal"],
      "site_url" => params["site_url"],
      "tools" => List.wrap(params["tool"]),
      "topic_tags" => params["topic_tags"]
    })
  end

  @doc """
  The forum post the form's words make, in the fields a question is posted
  with, or why they cannot be one.
  """
  @spec thread(draft()) :: {:ok, map()} | {:error, problem()}
  def thread(draft) do
    if String.length(draft["goal"]) > @max_title do
      {:error, %{said: title_fix(), field: :goal}}
    else
      {:ok,
       %{
         "site" => draft["site_url"],
         "title" => draft["goal"],
         "body_markdown" => presence(draft["details"]),
         "tools" => draft["tools"],
         "page_url" => Origin.inner_page(draft["site_url"]),
         "topic_tags" => tags(draft["topic_tags"]),
         "thread_kind" => presence(draft["thread_kind"])
       }}
    end
  end

  @doc """
  The pictures sent with a post, read from the uploads: at most four, each
  up to 3 MB. An empty picture field sends nothing.
  """
  @spec pictures(term()) :: {:ok, [binary()]} | {:error, problem()}
  # The paths are the upload files Plug wrote for this request, never a name
  # the sender chose.
  # sobelow_skip ["Traversal.FileModule"]
  def pictures(uploads) when is_list(uploads) do
    chosen = Enum.filter(uploads, &match?(%Plug.Upload{filename: name} when name != "", &1))

    cond do
      length(chosen) > PostPicture.max_per_post() ->
        {:error, %{said: "Add up to #{PostPicture.max_per_post()} pictures.", field: :pictures}}

      Enum.any?(chosen, &(File.stat!(&1.path).size > PostPicture.max_bytes())) ->
        {:error, %{said: "Each picture can be up to 3 MB.", field: :pictures}}

      true ->
        {:ok, Enum.map(chosen, &File.read!(&1.path))}
    end
  end

  def pictures(_none), do: {:ok, []}

  @doc """
  Whether the optional details are shown: any of them already holds something,
  or the post was turned down over one of them.
  """
  @spec details?(draft(), problem() | nil) :: boolean()
  def details?(draft, problem),
    do:
      Enum.any?(~w(details thread_kind topic_tags), &(draft[&1] != "")) or
        (problem != nil and problem[:field] in [:details, :pictures, :tags])

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
