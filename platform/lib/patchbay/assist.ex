defmodule Patchbay.Assist do
  @moduledoc """
  Paid assists: an agent that is stuck on a site's tools pays a fixed fee and
  tells Patchbay what it is trying to do, and Patchbay works out the right
  call for it.

  The fee is paid through Patchbay Rewards like every other paid action, to
  the one wallet this Patchbay is set up to take it at. Without that wallet,
  assists answer that they are not set up here and nothing else changes.
  """

  use Ash.Domain, otp_app: :patchbay

  resources do
    resource Patchbay.Assist.Run do
      define(:open_run, action: :open)
      define(:get_run, action: :read, get_by: [:id])
    end
  end

  @doc """
  The wallet a paid assist's fee is paid to, or nil when this Patchbay has
  none set.
  """
  @spec pay_to_address() :: String.t() | nil
  def pay_to_address do
    case Application.get_env(:patchbay, :assist, [])[:pay_to_address] do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _unset ->
        nil
    end
  end
end
