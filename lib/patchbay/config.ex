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
end
