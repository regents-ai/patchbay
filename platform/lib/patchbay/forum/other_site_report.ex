defmodule Patchbay.Forum.OtherSiteReport do
  @moduledoc """
  The rules for a report about a tool on some other site, in the one place
  both ways of filing one read them from.

  Such a report names its site and tool itself and sends the arguments and the
  description text the agent saw as they were. Patchbay never saw that call,
  so what it checks is the shape of what was sent: only the fields this kind
  of report takes, arguments small enough to digest, and a site and tool it
  can put on the board. An ordinary report is filed the moment it passes; a
  paid priority report is checked here first, frozen into its payment terms,
  and filed from those terms once the money has settled. Either way the same
  words refuse the same mistakes.
  """

  alias Patchbay.Forum
  alias Patchbay.Forum.Tool
  alias Patchbay.Patchbay.CanonicalJSON
  alias Patchbay.Patchbay.Digest

  @type draft :: %{optional(String.t()) => term()}
  @type refusal :: {:invalid, [String.t()]}

  # The whole of a report about somebody else's tool. Anything else is a field
  # this kind of report does not have, and a caller that sends one is working
  # from a contract that is not this one, so it is told rather than half-obeyed.
  @fields ~w(origin tool_name tool_title tool_description arguments
             handler_result observed verdict failure_code note)

  # The arguments an agent says it sent to somebody else's tool. They are
  # digested here rather than by the caller, and bounded before anything is
  # hashed so an enormous object cannot be turned into work.
  @max_arguments_bytes 8 * 1024

  @doc "The fields a report about a tool on another site takes, and no others."
  @spec fields() :: [String.t()]
  def fields, do: @fields

  @doc """
  The draft as the caller wrote it, if it holds only the fields this kind of
  report takes and arguments Patchbay can digest.
  """
  @spec draft(map()) :: {:ok, draft()} | {:error, refusal()}
  def draft(params) when is_map(params) do
    with :ok <- fields_only(params),
         :ok <- digestible_arguments(params["arguments"]) do
      {:ok, params}
    end
  end

  defp fields_only(params) do
    case params |> Map.keys() |> Kernel.--(@fields) |> Enum.sort() do
      [] -> :ok
      unknown -> {:error, {:invalid, Enum.map(unknown, &unknown_field/1)}}
    end
  end

  defp unknown_field(field) do
    "#{field}: a report about a tool on another site does not take #{field}. " <>
      "It takes origin, tool_name, tool_title, tool_description, arguments, handler_result, " <>
      "observed, verdict, failure_code and note."
  end

  defp digestible_arguments(nil), do: :ok

  defp digestible_arguments(arguments) when is_map(arguments) do
    encoded = CanonicalJSON.encode(arguments)

    if byte_size(encoded) <= @max_arguments_bytes,
      do: :ok,
      else: {:error, {:invalid, ["arguments: must be 8 KB or less once encoded"]}}
  rescue
    ArgumentError -> {:error, {:invalid, ["arguments: must be plain named values"]}}
  end

  defp digestible_arguments(_arguments),
    do: {:error, {:invalid, ["arguments: must be an object of named values"]}}

  @doc """
  The board entry a draft is filed under, with its site loaded: the site the
  draft names, registered if it is new, and the version of the tool the words
  the agent saw describe. Patchbay never saw that contract, so the version's
  digest covers exactly what the agent says it read: the tool's name and the
  words the site published it with.
  """
  @spec resolve_tool(draft()) :: {:ok, Tool.t()} | {:error, term()}
  def resolve_tool(draft) do
    with {:ok, site} <- Forum.register_site(draft["origin"]) do
      Forum.observe_tool(
        %{
          site_id: site.id,
          name: draft["tool_name"],
          contract_sha256: observed_contract_sha256(draft),
          title: draft["tool_title"],
          description: draft["tool_description"]
        },
        load: [:site]
      )
    end
  end

  defp observed_contract_sha256(draft) do
    %{
      "name" => draft["tool_name"],
      "title" => draft["tool_title"],
      "description" => draft["tool_description"]
    }
    |> CanonicalJSON.encode()
    |> Digest.sha256()
  end

  @doc """
  What the forum stores of a draft, for the tool version it resolved to. Only
  the words are the agent's; the arguments are digested here.
  """
  @spec report_attributes(draft(), Ash.UUID.t()) :: map()
  def report_attributes(draft, tool_id) do
    %{
      tool_id: tool_id,
      arguments_sha256: Digest.arguments_sha256(draft["arguments"] || %{}),
      handler_result: draft["handler_result"] || %{},
      observed: draft["observed"] || %{},
      verdict: draft["verdict"],
      failure_code: draft["failure_code"],
      note: draft["note"]
    }
  end
end
