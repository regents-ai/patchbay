defmodule Patchbay.Forum.ListedSitePicture do
  @moduledoc """
  The picture Patchbay took of a listed site's home page, for its row on
  /sites (`Patchbay.Forum.SiteDirectory`) while the site has no board of its
  own: one per listed domain, taken once
  (`Patchbay.Forum.ListedSitePictureSweep`). A site with a board shows the
  board's picture instead (`Patchbay.Forum.SiteScreenshot`).

  A domain whose page gave no picture keeps a row without one, so it is not
  asked for again.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Patchbay.Forum.Origin

  postgres do
    table("forum_listed_site_pictures")
    repo(Patchbay.Repo)
  end

  attributes do
    attribute :domain, :string do
      primary_key?(true)
      allow_nil?(false)
      public?(true)
      constraints(min_length: 1, max_length: Origin.max_host_length())
    end

    # Nil when no picture came back.
    attribute(:image, :binary, allow_nil?: true, public?: true)
    attribute(:taken_at, :utc_datetime_usec, allow_nil?: false, public?: true)
  end

  calculations do
    calculate(:pictured?, :boolean, expr(not is_nil(image)))
    # Counted by the database, so the picture itself is never read for it.
    calculate(:bytes, :integer, expr(fragment("octet_length(?)", image)))
  end

  actions do
    defaults([:read])

    read :pictured do
      description("The listed sites' pictures that came back.")
      filter(expr(not is_nil(image)))
    end

    read :kept do
      description("Every listed domain tried so far, and whether a picture came back.")
      prepare(build(select: [:domain], load: [:pictured?]))
    end

    read :shown do
      description(
        "When the pictures of the home pages of `domains` were taken, without the images."
      )

      argument(:domains, {:array, :string}, allow_nil?: false)
      filter(expr(domain in ^arg(:domains) and not is_nil(image)))
      prepare(build(select: [:domain, :taken_at]))
    end

    create :take do
      description("""
      Has the screenshot machine take a picture of a listed site's home page
      and keeps it, or keeps that none came back. It waits on that machine,
      so nothing here holds a transaction open.
      """)

      accept([:domain])
      argument(:last_try?, :boolean, allow_nil?: false, default: false)
      transaction?(false)
      upsert?(true)
      upsert_fields([:image, :taken_at])
      change(Patchbay.Forum.Changes.TakeListedSitePicture)
    end
  end

  policies do
    # The picture is shown on the public list. Taking one is Patchbay's own
    # work and is never reached from outside.
    policy action_type(:read) do
      authorize_if(always())
    end
  end

  @doc "Where the site's row loads the picture from; `at` changes with each picture."
  @spec path(Ash.Resource.record()) :: String.t()
  def path(picture),
    do: "/listed-site-pictures/#{picture.domain}?at=#{DateTime.to_unix(picture.taken_at)}"
end
