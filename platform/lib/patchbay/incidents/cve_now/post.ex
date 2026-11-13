defmodule Patchbay.Incidents.CveNow.Post do
  @moduledoc """
  The post a cve.now record is copied into, made only from what the record
  says: a title of its id and its own title, a tag of its id, and a Markdown
  body. The body opens with cve.now's summary, or the CVE record's own
  description when there is no summary, then gives the severity, what is
  affected, the fix, the record's references, and a line crediting the
  record on cve.now with a link to it.

  Every word of it is cve.now's, so each piece is kept to one line and its
  Markdown marks are escaped: it reads as written and adds no heading, list
  or link of its own.
  """

  alias Patchbay.Forum.TopicTag

  # A post's title holds at most this many characters (`Patchbay.Forum.Report`).
  @max_title 160
  # More references than this are counted rather than listed.
  @max_references 25
  @web_address ~r{\Ahttps?://[^\s<>]+\z}

  @type t :: %{
          id: String.t(),
          modified_at: DateTime.t(),
          title: String.t(),
          tag: String.t(),
          body: String.t()
        }

  @doc """
  The post for one record as `GET /api/v1/entries/<id>` answers it.
  `:not_critical` when cve.now does not rate the record critical (a record
  on CISA's list of exploited vulnerabilities always is); `:malformed` when
  it lacks an id that can be a tag, a title, its address on cve.now or when
  it last changed.
  """
  @spec from_entry(term()) :: {:ok, t()} | {:error, :not_critical | :malformed}
  def from_entry(%{"critical" => %{"value" => false}}), do: {:error, :not_critical}

  def from_entry(
        %{
          "id" => id,
          "title" => title,
          "url" => "https://cve.now/" <> _ = url,
          "modifiedAt" => modified,
          "critical" => %{"value" => true}
        } = entry
      )
      when is_binary(id) and is_binary(title) and is_binary(modified) do
    tag = String.downcase(id)

    with true <- TopicTag.valid?(tag) and line(title) != "",
         {:ok, modified_at, _offset} <- DateTime.from_iso8601(modified) do
      {:ok,
       %{
         id: id,
         modified_at: modified_at,
         title: title(id, title),
         tag: tag,
         body: body(entry, url)
       }}
    else
      _not_a_record -> {:error, :malformed}
    end
  end

  def from_entry(_entry), do: {:error, :malformed}

  defp title(id, title) do
    full = id <> ": " <> line(title)

    if String.length(full) <= @max_title,
      do: full,
      else: (full |> String.slice(0, @max_title - 1) |> String.replace(~r/\s+\S*\z/u, "")) <> "…"
  end

  defp body(entry, url) do
    description = description(entry)

    [
      opening(description),
      section("Severity", severity(entry)),
      section("Affected", affected(entry)),
      section("Fix", fix(entry)),
      section("References", references(entry)),
      "## Source\n\n" <> credit(description, url)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp description(%{"summary" => %{"text" => text}}) when is_binary(text) and text != "",
    do: {:summary, text}

  defp description(%{"originalDescription" => text}) when is_binary(text) and text != "",
    do: {:record, text}

  defp description(_entry), do: :none

  defp opening({_source, text}), do: text(text)
  defp opening(:none), do: ""

  defp credit({:summary, _text}, url),
    do:
      "Copied from #{source_link(url)}. The summary was written by a model at cve.now " <>
        "and is shared under CC BY 4.0."

  defp credit(_description, url), do: "Copied from #{source_link(url)}."

  defp source_link("https://" <> address = url), do: "[#{text(address)}](<#{url}>)"

  defp section(_heading, []), do: ""

  defp section(heading, lines),
    do: "## #{heading}\n\n" <> Enum.map_join(lines, "\n", &("- " <> &1))

  defp severity(entry), do: cvss(entry) ++ stated(entry) ++ kev(entry) ++ exposure(entry)

  defp cvss(%{"severity" => %{"cvss" => score} = severity}) when is_number(score) do
    source = if is_binary(severity["source"]), do: " (#{text(severity["source"])})", else: ""

    vector =
      if is_binary(severity["vector"]), do: ["Vector: " <> text(severity["vector"])], else: []

    ["CVSS #{score}#{source}" | vector]
  end

  defp cvss(_entry), do: []

  defp stated(%{"statedSeverity" => stated}) when is_binary(stated),
    do: ["Stated severity: " <> text(stated)]

  defp stated(_entry), do: []

  defp kev(%{"exploitation" => %{"kev" => %{"dateAdded" => added} = kev}})
       when is_binary(added) do
    due =
      if is_binary(kev["dueDate"]), do: "; CISA's due date is #{text(kev["dueDate"])}", else: ""

    action =
      if is_binary(kev["requiredAction"]),
        do: ["CISA's required action: " <> text(kev["requiredAction"])],
        else: []

    [
      "Known exploited: on CISA's Known Exploited Vulnerabilities catalog since #{text(added)}#{due}"
      | action
    ]
  end

  defp kev(_entry), do: []

  defp exposure(%{"exposure" => exposure}) when is_binary(exposure),
    do: ["Exposure: " <> text(exposure)]

  defp exposure(_entry), do: []

  defp affected(entry) do
    vendors = for %{"name" => name} when is_binary(name) <- list(entry, "vendors"), do: name
    products = for %{"name" => name} when is_binary(name) <- list(entry, "products"), do: name

    packages =
      for %{"ecosystem" => ecosystem, "name" => name}
          when is_binary(ecosystem) and is_binary(name) <- list(entry, "packages"),
          do: "#{name} (#{ecosystem})"

    named("Vendors", vendors) ++ named("Products", products) ++ named("Packages", packages)
  end

  defp named(_label, []), do: []
  defp named(label, names), do: ["#{label}: " <> text(Enum.join(names, ", "))]

  defp fix(entry) do
    case fixed_in(entry) ++ fix_status(entry) do
      [] -> ["cve.now lists no fixed version yet"]
      lines -> lines
    end
  end

  defp fixed_in(entry) do
    case versions(list(entry, "fixedIn")) do
      [] -> []
      versions -> ["Fixed in " <> text(Enum.join(versions, ", "))]
    end
  end

  defp fix_status(%{"fixStatus" => %{"packages" => packages}}) when is_list(packages) do
    for %{"ecosystem" => ecosystem, "package" => name, "status" => status} = package
        when is_binary(ecosystem) and is_binary(name) and status in ["fixed", "none"] <- packages do
      text("#{name} (#{ecosystem}): #{package_fix(package)}#{latest(package["latest"])}")
    end
  end

  defp fix_status(_entry), do: []

  defp package_fix(%{"status" => "none"}), do: "no fixed release yet"

  defp package_fix(package) do
    case package["fixed"] |> List.wrap() |> Enum.map(&version/1) |> versions() do
      [] -> "fixed"
      versions -> "fixed in " <> Enum.join(versions, ", ")
    end
  end

  defp version(%{"version" => version}), do: version
  defp version(_release), do: nil

  defp latest(%{"version" => version, "affected" => false}) when is_binary(version),
    do: "; the latest release, #{version}, is not affected"

  defp latest(%{"version" => version, "affected" => true}) when is_binary(version),
    do: "; the latest release, #{version}, is still affected"

  defp latest(_latest), do: ""

  defp versions(values), do: Enum.filter(values, &(is_binary(&1) and &1 != ""))

  defp references(entry) do
    references =
      for %{"url" => url} = reference when is_binary(url) <- list(entry, "references"),
          Regex.match?(@web_address, url),
          do: reference(url, reference["role"])

    {listed, more} = Enum.split(references, @max_references)
    if more == [], do: listed, else: listed ++ ["#{length(more)} more on cve.now"]
  end

  defp reference(url, role) when is_binary(role) and role != "other",
    do: "#{link(url)} (#{text(role)})"

  defp reference(url, _role), do: link(url)

  defp link(url), do: "[#{url |> String.replace(~r{\Ahttps?://}, "") |> text()}](<#{url}>)"

  defp list(entry, key) do
    case entry[key] do
      values when is_list(values) -> values
      _none -> []
    end
  end

  # One line of cve.now's words, with every mark that Markdown reads escaped.
  defp text(words), do: words |> line() |> String.replace(~r/[\\`*_\[\]<>#|~]/, "\\\\\\0")

  defp line(words), do: words |> String.split() |> Enum.join(" ")
end
