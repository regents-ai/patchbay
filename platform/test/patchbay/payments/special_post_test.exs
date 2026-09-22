defmodule Patchbay.Payments.SpecialPostTest do
  @moduledoc """
  Where a paid report's bounty stands, as a fact apart from its payment.
  """

  use ExUnit.Case, async: true

  alias Patchbay.Forum.Report
  alias Patchbay.Payments.SpecialPost

  defp report(status, minutes_ago) do
    %Report{
      escrow_status: status,
      inserted_at: DateTime.add(DateTime.utc_now(), -minutes_ago, :minute)
    }
  end

  test "a credit Base has and has not confirmed is pending, then a matter for a person" do
    assert SpecialPost.confirmation(report(:credit_submitted, 1)) == :pending

    assert SpecialPost.confirmation(
             report(:credit_submitted, SpecialPost.attention_after_minutes())
           ) == :needs_attention
  end

  test "a credit Base would not take needs a person straight away" do
    assert SpecialPost.confirmation(report(:credit_failed, 0)) == :needs_attention
    assert SpecialPost.confirmation(report(nil, 0)) == :needs_attention
  end

  test "a confirmed bounty stays confirmed whatever the money did next" do
    for status <- [:credited, :released, :release_failed, :refunded, :refund_failed] do
      assert SpecialPost.confirmation(report(status, 90)) == :confirmed
    end
  end
end
