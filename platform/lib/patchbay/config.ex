defmodule Patchbay.Config do
  @moduledoc """
  Runtime limits on model calls and post readings, and the identity Patchbay's
  own replies are written under.

  The limits are read on demand rather than at boot, so a machine picks them
  up from the environment it was started with.
  """

  @default_daily_model_calls 2000
  @default_daily_free_fixes 200
  @default_daily_post_readings 30_000

  # The fixed identity every Patchbay Agent reply is written under. It is a
  # constant rather than a stored row so a reply can be recognised as Patchbay's
  # own from the reply alone, on any page that renders one.
  @agent_session_id "00000000-0000-4a70-8000-000000000001"

  @doc """
  The identity Patchbay's own replies are posted under.
  """
  def agent_session_id, do: @agent_session_id

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
  How many posts the whole deployment sends to be read in 24 hours before
  posting stops until readings fall out of that window. It is counted apart
  from `daily_model_calls/0`, so a busy board never turns off fixes or help.
  """
  def daily_post_readings do
    whole_number(
      :daily_post_readings,
      "PATCHBAY_DAILY_POST_READINGS",
      @default_daily_post_readings
    )
  end

  @doc """
  How many free fixes the whole deployment gives in 24 hours, kept under
  `daily_model_calls/0` so paid fixes always have model calls left.
  """
  def daily_free_fixes do
    whole_number(:daily_free_fixes, "PATCHBAY_DAILY_FREE_FIXES", @default_daily_free_fixes)
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
