defmodule Patchbay.PaymentService do
  @moduledoc """
  Points the payments library at a stand-in payment service for one test, and
  back at the configured one when the test ends. The library's client is
  started with its address, so it is restarted each way.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @key RegentPayments.Facilitator

  @doc "Sends every verify and settle to `url` until the calling test ends."
  @spec stand_in(String.t(), keyword()) :: :ok
  def stand_in(url, options \\ []) do
    original = Application.fetch_env!(:regent_payments, @key)
    restart(Keyword.merge(original, [url: url, auth: nil] ++ options))
    on_exit(fn -> restart(original) end)
  end

  defp restart(config) do
    :ok = Supervisor.terminate_child(Patchbay.Supervisor, RegentPayments.Supervisor)
    Application.put_env(:regent_payments, @key, config)
    {:ok, _} = Supervisor.restart_child(Patchbay.Supervisor, RegentPayments.Supervisor)
    :ok
  end
end
