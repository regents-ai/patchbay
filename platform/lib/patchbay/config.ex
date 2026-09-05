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
  @default_max_rooms 2000
  @default_room_idle_hours 6
  @default_agent_poll_seconds 15
  @default_agent_daily_repairs 50

  # The fixed identity every Patchbay Agent reply is written under. It is a
  # constant rather than a stored row so a reply can be recognised as Patchbay's
  # own from the reply alone, on any page that renders one.
  @agent_session_id "00000000-0000-4a70-8000-000000000001"

  @doc """
  Whether Patchbay repairs its own tools when an agent reports one as broken.

  On unless the deployment says otherwise, so turning the loop off is a
  deliberate act: `PATCHBAY_AGENT_REPAIRS=false`.
  """
  def agent_repairs_enabled? do
    case Application.get_env(:patchbay, :agent_repairs) do
      value when is_boolean(value) -> value
      _ -> System.get_env("PATCHBAY_AGENT_REPAIRS") not in ["false", "0"]
    end
  end

  @doc """
  How often Patchbay looks for a new receipt-verified report to act on.
  """
  def agent_poll_seconds do
    whole_number(:agent_poll_seconds, "PATCHBAY_AGENT_POLL_SECONDS", @default_agent_poll_seconds)
  end

  @doc """
  How many repairs Patchbay may make on its own in any rolling 24 hours.
  """
  def agent_daily_repairs do
    whole_number(
      :agent_daily_repairs,
      "PATCHBAY_AGENT_DAILY_REPAIRS",
      @default_agent_daily_repairs
    )
  end

  @doc """
  The identity Patchbay's own replies are posted under.
  """
  def agent_session_id, do: @agent_session_id

  @doc """
  How many demo rooms may exist at once.
  """
  def max_rooms do
    whole_number(:max_rooms, "PATCHBAY_MAX_ROOMS", @default_max_rooms)
  end

  @doc """
  How long an untouched room with no invocations is kept before it is reaped.
  """
  def room_idle_hours do
    whole_number(:room_idle_hours, "PATCHBAY_ROOM_IDLE_HOURS", @default_room_idle_hours)
  end

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
