defmodule Patchbay.WalletBenchPublicRunTest do
  @moduledoc """
  A run's public record from Techtree (`/wallet-bench/<id>/results.json`), as
  the pair page's full report reads and shows it.
  """

  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias Patchbay.WalletBench.PublicRun
  alias PatchbayWeb.WalletBenchRunHTML

  @id "09cda9c0-8d16-46fd-a81d-e7b7ec83f0d7"
  @run %{attempt_id: @id, harness_id: "H10", wallet_id: "W03"}

  # Shaped as Techtree's live record for this run on 24 Oct 2026, trimmed.
  defp record do
    %{
      "id" => @id,
      "harness_id" => "H10",
      "wallet_id" => "W03",
      "page" => "https://techtree.sh/wallet-bench/" <> @id,
      "agent" => "Hermes Agent",
      "wallet_tool" => "Coinbase Agentic Wallet",
      "status" => "Stopped",
      "started_at" => "2026-10-21T09:37:47.861723Z",
      "failure" => nil,
      "machine" => %{
        "harness_version" => "0.9.1",
        "model" => "claude-opus-5-5",
        "os" => "Ubuntu 26.04.1 LTS",
        "reasoning_effort" => "high"
      },
      "agent_address" => nil,
      "model_cost_usd" => "0.31",
      "judge_cost_usd" => "0.29",
      "funding" => [
        %{"sent" => "0.02 USDC", "state" => "Confirmed on Base", "transaction" => "0x0916e735"}
      ],
      "timeline" => [
        %{
          "at" => "2026-10-21T09:37:47.861723Z",
          "label" => "Waiting for a machine",
          "failure" => nil
        }
      ],
      "tests" => [
        %{
          "test" => "Wallet",
          "folder" => "T2",
          "state" => "Judged",
          "prompt" => "Make a wallet.",
          "started_at" => "2026-10-21T09:41:00Z",
          "ended_at" => "2026-10-21T09:42:10Z",
          "seconds" => "70.0",
          "model_cost_usd" => "0.15",
          "judge_cost_usd" => "0.20",
          "failure" => nil,
          "version_installed" => "1.2.0, the release this run asked for.",
          "base_check" => "On Base at block 52893196, 0x2604 holds 0 ETH and 0 USDC.",
          "storage_finding" => "plain password file",
          "ruling" => %{
            "outcome" => "Pass, flagged: plain password file",
            "judged_by" => "claude-opus-5-5",
            "summary" => "Made a new wallet.",
            "reasoning" => "C1: the wallet was made.",
            "checks" => [
              %{
                "check" => "The test was set up as written",
                "answer" => "Yes",
                "why" => "It was."
              },
              %{
                "check" => "It said where the key is kept",
                "answer" => "Open",
                "why" => "Unclear."
              }
            ]
          },
          "files" => %{"transcript.md" => %{"bytes" => 1278, "sha256" => "8162"}}
        },
        %{
          "test" => "Refund",
          "folder" => "T3",
          "state" => "Stopped",
          "prompt" => nil,
          "started_at" => nil,
          "ended_at" => nil,
          "seconds" => nil,
          "model_cost_usd" => nil,
          "judge_cost_usd" => nil,
          "failure" => "The run stopped first.",
          "version_installed" => nil,
          "base_check" => nil,
          "storage_finding" => nil,
          "ruling" => nil,
          "files" => %{}
        }
      ]
    }
  end

  test "the record for the run and pair asked for is accepted" do
    assert PublicRun.valid?(record(), @run)
  end

  test "a record for another run or pair, or one the report cannot show, is refused" do
    refute PublicRun.valid?(record(), %{@run | wallet_id: "W04"})
    refute PublicRun.valid?(record(), %{@run | attempt_id: Ecto.UUID.generate()})
    refute PublicRun.valid?(put_in(record(), ["tests", Access.at(0), "folder"], "../x"), @run)
    refute PublicRun.valid?(put_in(record(), ["tests", Access.at(0), "files"], %{"a" => 1}), @run)
    refute PublicRun.valid?(Map.put(record(), "timeline", nil), @run)
  end

  test "the report shows each step's checks, the storage note, the bench's check and the history" do
    assigns = %{report: record()}

    html =
      rendered_to_string(~H"""
      <WalletBenchRunHTML.report report={@report} selected_check="C2" />
      """)
      |> String.replace(~r/\s+/, " ")

    assert html =~ "Pass, flagged: plain password file"
    assert html =~ "How the wallet keeps its key:</strong> plain password file."
    assert html =~ "The bench's own check:</strong> On Base at block 52893196"
    assert html =~ "Files · 1"
    assert html =~ ~s(id="wb-check-T2-C2" class="is-selected")
    assert html =~ "Unclear"
    assert html =~ "This step has no checks."
    assert html =~ "The run stopped first."
    assert html =~ "Waiting for a machine"
    assert html =~ "0.02 USDC · Confirmed on Base"
    assert html =~ "https://techtree.sh/wallet-bench/#{@id}/evidence/T2/transcript.md"
  end

  test "a wallet address in a run's words is drawn as an address that opens and copies in full" do
    wallet = "0x" <> String.duplicate("e4", 20)
    why = "It sent 0.01 USDC from #{wallet} to the bench."

    assigns = %{
      report:
        put_in(record(), ["tests", Access.at(0), "ruling", "checks", Access.at(0), "why"], why)
    }

    html =
      rendered_to_string(~H"""
      <WalletBenchRunHTML.report report={@report} />
      """)

    cell = html |> LazyHTML.from_fragment() |> LazyHTML.query("#wb-check-T2-C1 td:last-child")
    assert LazyHTML.text(LazyHTML.query(cell, ".rg-address__label")) =~ "0xe4e4..e4e4"
    assert [_] = cell |> LazyHTML.query(".rg-address .rg-copy") |> Enum.to_list()
    assert LazyHTML.text(cell) =~ "It sent 0.01 USDC from"
  end
end
