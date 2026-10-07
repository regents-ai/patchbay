defmodule Patchbay.Patchbay.RoomEntrance do
  @moduledoc """
  Whose repair room is whose: a person's room lives at a stable slug made
  from their profile, and only they may change it.
  """

  alias Patchbay.Identity.AgentProfile

  @doc "The room slug that belongs to this signed-in profile."
  @spec personal_slug(AgentProfile.t()) :: String.t()
  def personal_slug(%{public_id: public_id}) when is_binary(public_id), do: "p-" <> public_id
end
