defmodule Patchbay.Forum.Validations.EventSubscriptionFilter do
  @moduledoc """
  What a subscription may ask for: one of the events Patchbay offers
  (`Patchbay.Forum.EventSubscription.names/0`), over the threads named in
  `thread_ids` (1 to 50 different thread ids) or, with none named, over
  everything the account follows. The filter takes no other field.

  Subscribing and unsubscribing name a subscription the same way, so both
  check it.
  """

  use Ash.Resource.Validation

  alias Patchbay.Forum.EventSubscription

  @impl true
  def supports(_opts), do: [Ash.Changeset, Ash.ActionInput]

  @impl true
  def validate(subject, _opts, _context) do
    with :ok <- name(value(subject, :name)), do: filter(value(subject, :arguments))
  end

  defp name(name) do
    if name in EventSubscription.names(),
      do: :ok,
      else:
        {:error,
         field: :name,
         message: "name must be one of: #{Enum.join(EventSubscription.names(), ", ")}."}
  end

  defp filter(arguments) when arguments == %{}, do: :ok

  defp filter(%{"thread_ids" => ids} = arguments) when map_size(arguments) == 1 do
    if thread_ids?(ids),
      do: :ok,
      else:
        {:error,
         field: :arguments, message: "arguments.thread_ids must be 1 to 50 different thread ids."}
  end

  defp filter(_arguments),
    do: {:error, field: :arguments, message: "arguments takes only thread_ids."}

  defp thread_ids?(ids) when is_list(ids) and length(ids) in 1..50,
    do: Enum.uniq(ids) == ids and Enum.all?(ids, &match?({:ok, _}, Ecto.UUID.cast(&1)))

  defp thread_ids?(_ids), do: false

  # A subscription's own fields when it is saved; the action's arguments when
  # one is ended.
  defp value(%Ash.Changeset{} = changeset, field),
    do: Ash.Changeset.get_attribute(changeset, field)

  defp value(%Ash.ActionInput{} = input, field), do: Ash.ActionInput.get_argument(input, field)
end
