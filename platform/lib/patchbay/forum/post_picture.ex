defmodule Patchbay.Forum.PostPicture do
  @moduledoc """
  A picture a person added to their forum post: a PNG, JPEG or WebP of up to
  3 MB, at most three to a post. Kept apart from the post so the image is
  read only when it is served, and shown only while its post is.
  """

  use Ash.Resource,
    otp_app: :patchbay,
    domain: Patchbay.Forum,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @max_bytes 3 * 1024 * 1024
  @max_per_post 3

  postgres do
    table("forum_post_pictures")
    repo(Patchbay.Repo)

    references do
      reference(:report, on_delete: :delete)
    end
  end

  attributes do
    uuid_primary_key(:id)

    # Read from the picture's first bytes, never from what the sender said.
    attribute(:format, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:png, :jpeg, :webp]]
    )

    attribute(:image, :binary, allow_nil?: false, public?: true)

    # Where it sits among its post's pictures: 0, 1 or 2.
    attribute(:position, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 0, max: @max_per_post - 1]
    )

    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to(:report, Patchbay.Forum.Report, allow_nil?: false, public?: true)
  end

  identities do
    identity(:one_per_place, [:report_id, :position])
  end

  actions do
    defaults([:read])

    create :attach do
      description("Keeps one picture of a post, as its author sent it with the post.")
      accept([:report_id, :position, :image])

      change(fn changeset, _context ->
        case changeset |> Ash.Changeset.get_attribute(:image) |> detect_format() do
          {:ok, format} ->
            Ash.Changeset.force_change_attribute(changeset, :format, format)

          :error ->
            Ash.Changeset.add_error(changeset,
              field: :image,
              message: "must be a PNG, JPEG or WebP picture"
            )
        end
      end)

      validate(
        {Patchbay.Forum.Validations.MaxByteLength, attribute: :image, max_bytes: @max_bytes}
      )
    end
  end

  policies do
    # A picture is public exactly while its post is. Keeping one is part of
    # posting and is never reached from outside.
    policy action_type(:read) do
      authorize_if(expr(report.visibility == :published))
    end
  end

  @doc "The most bytes one picture may hold."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "The most pictures one post may carry."
  @spec max_per_post() :: pos_integer()
  def max_per_post, do: @max_per_post

  @doc "The media type a picture is served as."
  @spec content_type(%{format: atom()}) :: String.t()
  def content_type(%{format: format}), do: "image/#{format}"

  @doc "Which kind of picture these bytes are, read from their first bytes."
  @spec detect_format(term()) :: {:ok, :png | :jpeg | :webp} | :error
  def detect_format(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _rest::binary>>), do: {:ok, :png}
  def detect_format(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: {:ok, :jpeg}
  def detect_format(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>), do: {:ok, :webp}
  def detect_format(_other), do: :error
end
