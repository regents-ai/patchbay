defmodule PatchbayWeb.WalletBenchLinksTest do
  @moduledoc "A pair on the Wallet Bench leads to the forum's threads about it and to the post form."

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PatchbayWeb.WalletBenchHTML

  @harness %{id: "H1", name: "Claude Code", website: "https://claude.com/code", version: nil}
  @wallet %{id: "W1", name: "MetaMask", website: "https://metamask.io", version: nil}

  test "a pair's threads are its wallet's site searched for the agent, or both names without a site" do
    assert WalletBenchHTML.threads_path(@harness, @wallet) == "/?q=Claude+Code&site=metamask.io"

    assert WalletBenchHTML.threads_path(@harness, %{@wallet | website: nil}) ==
             "/?q=Claude+Code+MetaMask"
  end

  test "Ask about this opens the post form with the wallet's site and a title naming the pair" do
    assert WalletBenchHTML.ask_about_path(@harness, @wallet) ==
             "/?goal=Claude+Code+with+MetaMask&site_url=metamask.io#pb-hero"
  end

  test "an opened square carries both links" do
    html =
      rendered_to_string(
        WalletBenchHTML.pair_detail(%{
          __changed__: nil,
          harness: @harness,
          wallet: @wallet,
          notes: %{},
          grids: [],
          sets: [],
          shown: nil,
          selection: %{},
          comparison: nil,
          context: %{},
          extra_notes: []
        })
      )

    assert html =~ ~s(href="/?q=Claude+Code&amp;site=metamask.io">Threads about this pair</a>)

    assert html =~
             ~s(href="/?goal=Claude+Code+with+MetaMask&amp;site_url=metamask.io#pb-hero">Ask about this</a>)
  end
end
