defmodule Patchbay.Forum.Changes.AttachPictures do
  @moduledoc """
  Keeps the pictures a thread was posted with, inside the same transaction as
  the thread, so a picture that is refused refuses the whole post and no
  thread is left without the pictures its author sent.
  """

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidArgument
  alias Patchbay.Forum.PostPicture

  @impl true
  def change(changeset, _opts, _context) do
    pictures = Ash.Changeset.get_argument(changeset, :pictures)

    if length(pictures) > PostPicture.max_per_post() do
      Ash.Changeset.add_error(
        changeset,
        InvalidArgument.exception(
          field: :pictures,
          message: "at most #{PostPicture.max_per_post()} pictures"
        )
      )
    else
      Ash.Changeset.after_action(changeset, fn _changeset, report ->
        attach(report, pictures)
      end)
    end
  end

  defp attach(report, pictures) do
    pictures
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, report}, fn {image, position}, answer ->
      # Internal write: the picture belongs to the thread being posted.
      PostPicture
      |> Ash.Changeset.for_create(
        :attach,
        %{report_id: report.id, position: position, image: image},
        authorize?: false
      )
      |> Ash.create()
      |> case do
        {:ok, _picture} -> {:cont, answer}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end
end
