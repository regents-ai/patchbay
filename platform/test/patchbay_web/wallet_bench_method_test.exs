defmodule PatchbayWeb.WalletBenchMethodTest do
  @moduledoc "How the bench works: each test's checks and each result's meaning, read without any run."

  use PatchbayWeb.ConnCase, async: true

  # One judged check of one run, as Techtree publishes it.
  defp check!(grid, criterion_id, criterion) do
    Patchbay.Repo.query!(
      """
      INSERT INTO techtree_app.wallet_bench_checks
        (attempt_id, grid, criterion_id, harness_id, wallet_id, run, criterion, result)
      VALUES ($1, $2, $3, 'H1', 'W1', 1, $4, 'true')
      """,
      [Ecto.UUID.dump!(Ecto.UUID.generate()), grid, criterion_id, criterion]
    )
  end

  test "lists each test's checks once, in order, and what each result means", %{conn: conn} do
    # Three runs of the install test judged on the same two checks.
    for _run <- 1..3 do
      check!("install", "C2", "The wallet tool reports its version.")
      check!("install", "C1", "The agent installs the wallet tool.")
    end

    Patchbay.Repo.query!(
      "INSERT INTO techtree_app.wallet_bench_notes (key, text) VALUES ('PASS', 'Pass: every check held.')"
    )

    page = conn |> get("/wallet-bench/how-it-works") |> html_response(200)
    assert page =~ "The agent installs the wallet tool."
    assert page =~ "Pass: every check held."

    markdown =
      conn
      |> put_req_header("accept", "text/markdown")
      |> get("/wallet-bench/how-it-works")
      |> response(200)

    assert markdown =~
             "### Install\n\n1. The agent installs the wallet tool.\n2. The wallet tool reports its version.\n\n### Make a wallet\n\nListed once this test has run."

    assert markdown =~ "- `PASS`: Pass: every check held."
  end
end
