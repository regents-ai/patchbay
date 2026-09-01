defmodule Patchbay.Config do
  @moduledoc """
  Runtime switches for the two generation modes.

  Both are read on demand rather than at boot, so a machine picks them up from
  the environment it was started with. The API key's value never leaves this
  module.
  """

  @doc """
  Whether the deterministic checked-in fallback may stand in for live inference.
  """
  def demo_fallback? do
    Application.get_env(:patchbay, :demo_fallback, false) or
      System.get_env("PATCHBAY_DEMO_FALLBACK") in ["true", "1"]
  end

  @doc """
  Whether this server process holds an OpenAI key.
  """
  def live_inference_configured? do
    key = System.get_env("OPENAI_API_KEY")
    is_binary(key) and key != ""
  end

  @default_daily_model_calls 300
  @default_room_daily_model_calls 30
  @default_room_cooldown_seconds 20

  @doc """
  How many live model calls the whole deployment may make in 24 hours.
  """
  def daily_model_calls do
    whole_number(
      :daily_model_calls,
      "PATCHBAY_DAILY_MODEL_CALLS",
      @default_daily_model_calls
    )
  end

  @doc """
  How many live model calls one room may make in 24 hours.
  """
  def room_daily_model_calls do
    whole_number(
      :room_daily_model_calls,
      "PATCHBAY_ROOM_DAILY_MODEL_CALLS",
      @default_room_daily_model_calls
    )
  end

  @doc """
  How long a room waits between candidate generations.
  """
  def room_cooldown_seconds do
    whole_number(
      :room_cooldown_seconds,
      "PATCHBAY_ROOM_COOLDOWN_SECONDS",
      @default_room_cooldown_seconds
    )
  end

  # A limit set to something that is not a whole number is treated as unset, so
  # a typo in a deploy leaves the documented limit standing rather than removing
  # it.
  defp whole_number(key, variable, default) do
    case Application.get_env(:patchbay, key) || System.get_env(variable) do
      value when is_integer(value) and value >= 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed >= 0 -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end
end
