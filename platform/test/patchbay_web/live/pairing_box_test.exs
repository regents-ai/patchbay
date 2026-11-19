defmodule PatchbayWeb.PairingBoxTest do
  @moduledoc """
  The pairing box, as the `/pair` page holds it: each agent keeps its own code
  until it expires or a new one is asked for, and the form arriving with no agent
  chosen, as a reconnecting page sends it, changes nothing; the message names the
  address the page was drawn on, and sends the agent on to the page the link
  named only when that page is on this site.
  """

  use PatchbayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Patchbay.Identity

  test "Pair New Agent sent with no agent chosen changes nothing", %{conn: conn} do
    view = conn |> signed_in("did:privy:pair-empty", "e") |> pair_page()
    box = element(view, "#pair-pairing-box")

    render_change(box, %{"_target" => ["harness"]})
    render_submit(box, %{})

    assert has_element?(view, "#pair-pairing-box input[name=harness]")
    refute has_element?(view, "#pair-pairing-box input[name=harness][checked]")
  end

  test "each agent keeps its code, and only a new code replaces the chosen one", %{conn: conn} do
    box =
      conn
      |> signed_in("did:privy:pair-keep", "f")
      |> pair_page()
      |> element("#pair-pairing-box")

    code_for = fn harness -> box |> render_change(%{"harness" => harness}) |> code() end

    codex = code_for.("codex")
    hermes = code_for.("hermes")

    assert codex != hermes
    assert code_for.("codex") == codex

    renewed = box |> render_submit(%{"harness" => "codex"}) |> code()

    assert renewed != codex
    assert code_for.("hermes") == hermes
    assert code_for.("codex") == renewed
  end

  test "the message names the address the page was drawn on", %{conn: conn} do
    message = fn site_edition, hex ->
      conn
      |> at(site_edition)
      |> signed_in("did:privy:pair-#{site_edition}", hex)
      |> pair_page()
      |> element("#pair-pairing-box")
      |> render_change(%{"harness" => "codex"})
      |> code()
    end

    assert message.(:open, "b") =~ PatchbayWeb.SiteEdition.url(:open)

    main = message.(:main, "c")
    assert main =~ PatchbayWeb.SiteEdition.url(:main)
    refute main =~ PatchbayWeb.SiteEdition.url(:open)
  end

  test "each address offers the hosted app that connects there, and only that one", %{conn: conn} do
    old = Application.get_env(:regent_agents, :hosted_pairing, [])
    Application.put_env(:regent_agents, :hosted_pairing, [:chatgpt, :claude])
    on_exit(fn -> Application.put_env(:regent_agents, :hosted_pairing, old) end)

    page = fn site_edition, hex ->
      conn
      |> at(site_edition)
      |> signed_in("did:privy:pair-hosted-#{site_edition}", hex)
      |> pair_page()
    end

    choose = fn view, harness ->
      view |> element("#pair-pairing-box") |> render_change(%{"harness" => harness}) |> code()
    end

    for {site_edition, hex, offered, other} <- [
          {:open, "1", "chatgpt", "claude"},
          {:main, "2", "claude", "chatgpt"}
        ] do
      view = page.(site_edition, hex)

      assert has_element?(view, "#pair-pairing-box input[name=harness][value=#{offered}]")
      refute has_element?(view, "#pair-pairing-box input[name=harness][value=#{other}]")

      # The app that connects elsewhere gets no code here, even when asked for by name.
      assert choose.(view, other) == ""
      assert choose.(view, offered) =~ ~r/Pairing code:\s*\S+/
    end
  end

  test "the message sends the agent on to the named page only when it is on this site", %{
    conn: conn
  } do
    message = fn to ->
      conn
      |> signed_in("did:privy:pair-start-" <> Base.encode16(to), "d")
      |> pair_page(to: to)
      |> element("#pair-pairing-box")
      |> render_change(%{"harness" => "codex"})
      |> code()
    end

    assert message.("/agents") =~ PatchbayWeb.SiteEdition.url(:main) <> "/agents"

    for elsewhere <- ["//elsewhere.example", "/\\elsewhere.example", "https://elsewhere.example"],
        do: refute(message.(elsewhere) =~ "elsewhere.example")
  end

  test "the code on screen gives way to the agent that used it", %{conn: conn} do
    view = conn |> signed_in("did:privy:pair-used", "a") |> pair_page()

    message =
      view |> element("#pair-pairing-box") |> render_change(%{"harness" => "codex"}) |> code()

    [_line, pairing_code] = Regex.run(~r/Pairing code:\s*(\S+)/, message)

    RegentAgents.pair_agent!(pairing_code, "Used Code Agent", :codex,
      actor: %RegentAgents.Agent{wallet: "0x" <> String.duplicate("9", 40)}
    )

    # The site hears of a pairing from the database once it commits
    # (`RegentAgents.Listener`), which a test's open transaction never does, so the
    # page is told here. It hands the news to the box on its next turn.
    send(view.pid, :agents_changed)
    _heard = render(view)
    assert render(view) =~ "Used Code Agent"
    refute has_element?(view, "#pair-pairing-box pre")
  end

  defp signed_in(conn, privy_user_id, hex) do
    person =
      Identity.upsert_from_privy!(%{
        privy_user_id: privy_user_id,
        wallet_address: "0x" <> String.duplicate(hex, 40)
      })

    sign_in(conn, person.id)
  end

  defp at(conn, :main), do: conn
  defp at(conn, :open), do: on_open(conn)

  defp pair_page(conn, params \\ []) do
    {:ok, view, _html} = live(conn, ~p"/pair?#{params}")
    view
  end

  # The message shown in the box, which holds its code.
  defp code(html),
    do:
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#pair-pairing-box pre")
      |> LazyHTML.text()
end
