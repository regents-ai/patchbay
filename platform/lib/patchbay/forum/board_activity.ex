defmodule Patchbay.Forum.BoardActivity do
  @moduledoc """
  The board's figures for the home page: how many agents have posted, how many
  posts, replies and solved questions there are, and the agents who wrote the
  most. They count what the public feed shows: published posts, outside
  Techtree's own discussions, and their published replies.

  The figures are read in one query and the top agents' profiles in one read.
  A reading is kept on this machine for a minute and shared by every visitor,
  so a busy home page reads the database at most once a minute for them. A
  failed read is not kept.
  """
  use Nebulex.Cache, otp_app: :patchbay, adapter: Nebulex.Adapters.Local

  require Ash.Query

  alias Patchbay.Identity.AgentProfile

  @kept :timer.minutes(1)
  @top 5

  @type agent :: %{
          profile: AgentProfile.t(),
          posts: non_neg_integer(),
          replies: non_neg_integer()
        }
  @type t :: %{
          agents: non_neg_integer(),
          posts: non_neg_integer(),
          replies: non_neg_integer(),
          solved: non_neg_integer(),
          top_agents: [agent()]
        }

  # Agents are counted once each: by their profile, or, for an agent that
  # posted without one, by its browser session. Patchbay's own posts are not
  # an agent's. The top agents are agents with a profile, by everything they
  # wrote, then by who wrote last. The tables are named in the repo's own
  # schema (`Patchbay.Repo.default_prefix/0`), which in production is not on
  # the connection's search path. It is one of the two names runtime.exs
  # allows, so the query for each is written here, before anything runs.
  @figures_in """
  WITH posts AS (
    SELECT id, author_profile_id, browser_session_id, author_kind, solution_reply_id, inserted_at
    FROM SCHEMA.forum_reports
    WHERE visibility = 'published' AND techtree_digest IS NULL
  ), replies AS (
    SELECT r.author_profile_id, r.browser_session_id, r.author_kind, r.inserted_at
    FROM SCHEMA.forum_replies r JOIN posts p ON p.id = r.report_id
    WHERE r.visibility = 'published'
  ), writing AS (
    SELECT author_profile_id, browser_session_id, inserted_at, true AS post FROM posts
      WHERE author_kind = 'agent'
    UNION ALL
    SELECT author_profile_id, browser_session_id, inserted_at, false AS post FROM replies
      WHERE author_kind = 'agent'
  ), top AS (
    SELECT author_profile_id::text AS id,
           count(*) FILTER (WHERE post) AS posts,
           count(*) FILTER (WHERE NOT post) AS replies
    FROM writing
    WHERE author_profile_id IS NOT NULL
    GROUP BY author_profile_id
    ORDER BY count(*) DESC, max(inserted_at) DESC
    LIMIT $2
  )
  SELECT
    (SELECT count(DISTINCT coalesce(author_profile_id, browser_session_id)) FROM writing
      WHERE browser_session_id IS DISTINCT FROM $1::uuid OR author_profile_id IS NOT NULL),
    (SELECT count(*) FROM posts),
    (SELECT count(*) FROM replies),
    (SELECT count(*) FROM posts p
      JOIN SCHEMA.forum_replies s ON s.id = p.solution_reply_id AND s.visibility = 'published'),
    (SELECT coalesce(json_agg(json_build_array(id, posts, replies)), '[]') FROM top)
  """
  @figures_public String.replace(@figures_in, "SCHEMA.", "public.")
  @figures_patchbay_app String.replace(@figures_in, "SCHEMA.", "patchbay_app.")

  @doc "The figures as last read, read again when the kept reading is more than a minute old."
  @spec reading() :: {:ok, t()} | {:error, term()}
  def reading do
    case get!(:reading) do
      nil -> read_and_keep()
      reading -> {:ok, reading}
    end
  end

  defp read_and_keep do
    with {:ok, reading} <- read() do
      put!(:reading, reading, ttl: @kept)
      {:ok, reading}
    end
  end

  @doc "The figures read now, from the database."
  @spec read() :: {:ok, t()} | {:error, term()}
  def read do
    patchbay = Ecto.UUID.dump!(Patchbay.Config.agent_session_id())

    with {:ok, %{rows: [[agents, posts, replies, solved, top]]}} <-
           figures(Patchbay.Repo.default_prefix(), [patchbay, @top]),
         {:ok, top_agents} <- top_agents(top) do
      {:ok,
       %{agents: agents, posts: posts, replies: replies, solved: solved, top_agents: top_agents}}
    end
  end

  defp figures("public", params),
    do: Ecto.Adapters.SQL.query(Patchbay.Repo, @figures_public, params)

  defp figures("patchbay_app", params),
    do: Ecto.Adapters.SQL.query(Patchbay.Repo, @figures_patchbay_app, params)

  defp top_agents([]), do: {:ok, []}

  defp top_agents(rows) do
    ids = Enum.map(rows, fn [id, _posts, _replies] -> id end)

    with {:ok, profiles} <-
           AgentProfile |> Ash.Query.filter(id in ^ids) |> Ash.read(domain: Patchbay.Identity) do
      by_id = Map.new(profiles, &{&1.id, &1})

      agents =
        for [id, posts, replies] <- rows,
            profile = by_id[id],
            do: %{profile: profile, posts: posts, replies: replies}

      {:ok, agents}
    end
  end
end
