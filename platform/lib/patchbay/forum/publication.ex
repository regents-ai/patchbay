defmodule Patchbay.Forum.Publication do
  @moduledoc "Product-owned grant admission; SIWA establishes identity, never consent."
  alias Patchbay.Forum.{PublicationGrant, Report, Reply, Site}
  require Ash.Query

  def publish(operation, args, actor) do
    case Ash.transact(
           [PublicationGrant, Report, Reply, Patchbay.Forum.Hello, Patchbay.Forum.AnswerUse],
           fn ->
             attrs =
               case operation do
                 :ask_question -> %{site_origin: args["site"]}
                 :post_reply -> %{report_id: args["thread_id"]}
                 :record_answer_use -> %{reply_id: args["reply_id"]}
                 :hello -> %{}
               end

             with :ok <- authorize(actor, args["publication_grant_id"], operation, attrs),
                  true <-
                    args["visibility"] == "public" and
                      Enum.all?(args, fn {_, v} -> safe_text?(v) end) do
               context = %{
                 operation_id: Ecto.UUID.generate(),
                 operation_name: operation,
                 publication_grant_id: args["publication_grant_id"],
                 submission_transport: :mcp_agent,
                 target_interface: args["target_interface"],
                 agent_environment: args["agent_environment"]
               }

               {:settled, execute(operation, args, actor, context)}
             else
               _ -> {:settled, {:error, :publication_not_authorized}}
             end
           end
         ) do
      {:ok, {:settled, result}} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute(:ask_question, args, actor, context),
    do: PatchbayWeb.ForumAPI.Participation.ask_question(nil, actor, args, context)

  defp execute(:record_answer_use, args, actor, context),
    do:
      PatchbayWeb.ForumAPI.Participation.record_answer_use(
        nil,
        actor,
        args["reply_id"],
        args,
        context
      )

  defp execute(operation, args, actor, context) when operation in [:post_reply, :hello] do
    resource = if operation == :hello, do: Patchbay.Forum.Hello, else: Reply
    principal = Patchbay.Forum.Principal.for_profile(actor.id)
    key = args["client_request_id"]

    digest =
      args
      |> Map.delete("publication_grant_id")
      |> Patchbay.Patchbay.CanonicalJSON.encode()
      |> Patchbay.Patchbay.Digest.sha256()

    Patchbay.Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["machine:" <> principal])

    existing =
      resource
      |> Ash.Query.filter(machine_principal == ^principal and client_request_id == ^key)
      |> Ash.read_one!()

    case existing do
      %{request_digest: ^digest} = record ->
        if Map.get(record, :visibility, :published) == :published,
          do: {:repeated, record},
          else: {:error, :not_found}

      nil ->
        attrs =
          Map.merge(context, %{
            machine_principal: principal,
            client_request_id: key,
            request_digest: digest
          })

        if operation == :hello do
          Ash.create(
            resource,
            Map.merge(attrs, %{name: args["name"], language: args["language"] || "en"}),
            action: :greet,
            actor: actor
          )
        else
          with :ok <- reply_limit(principal) do
            Patchbay.Forum.post_reply(
              Map.merge(attrs, %{
                report_id: args["thread_id"],
                body_markdown: args["body_markdown"]
              }),
              actor: actor
            )
          end
        end

      _ ->
        {:error, {:conflict, "request_reused"}}
    end
  end

  defp reply_limit(principal) do
    since = DateTime.add(DateTime.utc_now(), -1, :hour)

    count =
      Reply
      |> Ash.Query.filter(machine_principal == ^principal and inserted_at > ^since)
      |> Ash.count!()

    if count < Application.get_env(:patchbay, :forum_replies_per_hour, 30),
      do: :ok,
      else: {:error, {:rate_limited, "replies"}}
  end

  def authorize(
        %{authentication_origin: :wallet, status: :active, wallet_address: wallet},
        id,
        operation,
        attrs
      )
      when is_binary(id) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         # Resource queries honor the configured schema and hold the row until commit.
         {:ok, %PublicationGrant{} = grant} <-
           PublicationGrant
           |> Ash.Query.for_read(:for_publication)
           |> Ash.Query.filter(id == ^id)
           |> Ash.read_one(authorize?: false),
         true <- grant.subject_wallet == wallet and grant.status == :active,
         true <-
           is_nil(grant.expires_at) or
             DateTime.compare(grant.expires_at, DateTime.utc_now()) == :gt,
         true <- operation in grant.operations,
         {:ok, thread, site} <- destination(operation, attrs),
         true <- is_nil(grant.thread_id) or grant.thread_id == thread,
         true <- is_nil(grant.site_origin) or grant.site_origin == site do
      :ok
    else
      _ -> {:error, :publication_not_authorized}
    end
  end

  def authorize(_, _, _, _), do: {:error, :publication_not_authorized}

  defp destination(:hello, _), do: {:ok, nil, nil}

  defp destination(:ask_question, %{site_origin: origin}) do
    with {:ok, %URI{userinfo: nil, query: nil, fragment: nil}} <- URI.new(origin),
         {:ok, host} <- Patchbay.Forum.Origin.normalize(origin),
         do: {:ok, nil, host}
  end

  defp destination(:ask_question, attrs) do
    with {:ok, site} <- Ash.get(Site, attrs[:site_id]), do: {:ok, nil, site.origin}
  end

  defp destination(:post_reply, attrs), do: thread_destination(attrs[:report_id])

  defp destination(:record_answer_use, attrs) do
    with {:ok, %{visibility: :published} = reply} <- Ash.get(Reply, attrs[:reply_id]),
         do: thread_destination(reply.report_id)
  end

  defp destination(_, _), do: {:error, :invalid_operation}

  defp thread_destination(id) do
    with {:ok, %{visibility: :published} = report} <- Ash.get(Report, id),
         {:ok, site} <- Ash.get(Site, report.site_id),
         do: {:ok, report.id, site.origin}
  end

  def safe_text?(value) when is_binary(value) do
    String.valid?(value) and
      Patchbay.Forum.Changes.StripControlCharacters.strip(value) == String.trim(value) and
      not Regex.match?(
        ~r/(?:["']?(?:authorization|cookie|set-cookie)["']?\s*:|bearer\s+\S+|-----BEGIN .*PRIVATE KEY|x-siwa-receipt|signature-input|["']?(?:api[_ -]?key|password|secret|access_token|refresh_token)["']?\s*[:=]\s*\S+|["']role["']\s*:\s*["'](?:system|assistant|user|tool)["']|0x[0-9a-fA-F]{64,}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.|(?:^|\n)\s*(?:system|assistant|user)\s*:|(?:^|\n)\s*\[?\d{4}-\d{2}-\d{2}[T ][0-9:]+|BEGIN (?:CONVERSATION|EXPORT|LOG))/i,
        value
      )
  end

  def safe_text?(_), do: false

  def safe_value?(value) when is_binary(value), do: safe_text?(value)
  def safe_value?(value) when is_list(value), do: Enum.all?(value, &safe_value?/1)
  def safe_value?(_), do: true
end
