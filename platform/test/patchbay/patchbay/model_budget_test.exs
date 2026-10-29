defmodule Patchbay.Patchbay.ModelBudgetTest do
  use Patchbay.DataCase, async: false

  alias Patchbay.Assist.ModelCalls
  alias Patchbay.Patchbay.ModelBudget

  setup do
    on_exit(fn -> Application.delete_env(:patchbay, :daily_model_calls) end)
    Application.put_env(:patchbay, :daily_model_calls, 2)
  end

  test "the day's questions are allowed up to the deployment's ceiling and refused after it" do
    assert :ok = ModelBudget.allow()

    ModelCalls.ask(:read_report, "test/model")
    assert :ok = ModelBudget.allow()

    ModelCalls.ask(:read_report, "test/model")

    assert ModelBudget.allow() ==
             {:error,
              "Patchbay has used all 2 of its model calls for the last 24 hours. Try again later."}
  end
end
