defmodule PatchbayWeb.MetricsTest do
  # The private listener Fly reads the site's numbers from.
  use ExUnit.Case, async: false

  import Plug.Test

  alias PatchbayWeb.Metrics

  test "the numbers are served at /metrics alone, with the names the site watch reads" do
    :telemetry.execute([:patchbay, :post_readings, :day_full], %{count: 3, ceiling: 3}, %{})
    :telemetry.execute([:patchbay, :post_readings, :half_spent], %{count: 2, ceiling: 3}, %{})

    :telemetry.execute(
      [:patchbay, :post_readings, :words_not_kept],
      %{count: 500, ceiling: 500},
      %{}
    )

    :telemetry.execute(
      [:patchbay, :model_call, :stop],
      %{prompt_tokens: 120, completion_tokens: 8, cost_usd: 0.0002},
      %{purpose: :check_post, model: "jev", outcome: :answered}
    )

    answer = Metrics.call(conn(:get, "/metrics"), [])

    assert answer.status == 200
    assert answer.resp_body =~ ~r/^patchbay_post_readings_day_full_total \d+$/m
    assert answer.resp_body =~ ~r/^patchbay_post_readings_half_spent_total \d+$/m
    assert answer.resp_body =~ ~r/^patchbay_post_readings_words_not_kept_total \d+$/m
    assert answer.resp_body =~ ~s(patchbay_jev_questions_total{outcome="answered"})
    assert answer.resp_body =~ "patchbay_jev_input_tokens_total"
    assert answer.resp_body =~ "patchbay_jev_cost_usd_sum"
    # Nothing a caller chose is a label: the purpose and the model stay out.
    refute answer.resp_body =~ "check_post"

    assert Metrics.call(conn(:get, "/"), []).status == 404
    assert Metrics.call(conn(:post, "/metrics"), []).status == 404
  end
end
