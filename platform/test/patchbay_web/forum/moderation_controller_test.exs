defmodule PatchbayWeb.Forum.ModerationControllerTest do
  @moduledoc """
  The moderation door: who may open it, what a decision does to the public
  record, and that every decision is written down.
  """

  use PatchbayWeb.ConnCase, async: false

  alias Patchbay.Forum
  alias Patchbay.Forum.ModerationAction
  alias Patchbay.Forum.Report

  @wallet "0x" <> String.duplicate("a", 40)

  defp moderator!(wallet \\ @wallet) do
    Patchbay.Identity.upsert_from_privy!(%{
      privy_user_id: "did:privy:" <> String.replace(wallet, "0x", ""),
      wallet_address: wallet
    })
  end

  defp signed_in(conn, profile) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> PatchbayWeb.Plugs.CurrentProfile.sign_in(profile.id)
  end

  defp allow_moderator(wallet) do
    previous = Application.get_env(:patchbay, :moderator_wallets)
    Application.put_env(:patchbay, :moderator_wallets, [wallet])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:patchbay, :moderator_wallets, previous),
        else: Application.delete_env(:patchbay, :moderator_wallets)
    end)
  end

  defp thread!(attrs \\ %{}) do
    {:ok, site} = Forum.register_site("shop.example")

    # Seeded by Patchbay itself, as nobody in particular: posting takes a signed-in poster.
    Forum.ask_question!(
      Map.merge(
        %{
          site_id: site.id,
          browser_session_id: Ash.UUID.generate(),
          title: "Does checkout handle declined cards?",
          thread_kind: :help_needed,
          body_markdown: "A declined card leaves the cart empty. Is that the site's doing?"
        },
        attrs
      ),
      authorize?: false
    )
  end

  describe "the door" do
    test "answers 404 to a visitor, and to a signed-in profile off the allowlist",
         %{conn: conn} do
      assert conn |> get(~p"/moderation") |> html_response(404) =~
               "There is nothing at this address."

      signed_out_of_list = moderator!("0x" <> String.duplicate("b", 40))

      assert conn
             |> signed_in(signed_out_of_list)
             |> get(~p"/moderation")
             |> html_response(404) =~ "There is nothing at this address."
    end
  end

  describe "a decision" do
    setup do
      allow_moderator(@wallet)
      :ok
    end

    test "holds a thread out of every public view, with its reason on record",
         %{conn: conn} do
      thread = thread!()
      moderator = moderator!()

      conn =
        conn
        |> signed_in(moderator)
        |> post(~p"/moderation", %{
          "subject" => %{
            "kind" => "thread",
            "id" => thread.id,
            "action" => "quarantine",
            "reason" => "Read like an advertisement, not a question."
          }
        })

      assert redirected_to(conn) == ~p"/moderation"
      assert Ash.get!(Report, thread.id).visibility == :quarantined

      # The page itself lists what waits, and what it decided.
      board =
        conn
        |> recycle()
        |> signed_in(moderator)
        |> get(~p"/moderation")
        |> html_response(200)

      assert board =~ "Waiting for a decision"
      assert board =~ "Read like an advertisement, not a question."
      assert board =~ "Decisions on record"

      # Publicly the thread answers like one that does not exist, everywhere.
      assert_error_sent(404, fn ->
        conn |> recycle() |> get(~p"/posts/#{thread.id}")
      end)

      refute conn |> recycle() |> get(~p"/") |> html_response(200) =~ thread.title

      refute conn |> recycle() |> get(~p"/shop.example") |> html_response(200) =~
               thread.title

      assert json_response(
               conn |> recycle() |> get("/forum/search", %{"q" => "declined cards"}),
               200
             )["results"] == []

      assert json_response(
               conn |> recycle() |> get("/forum/threads/#{thread.id}"),
               404
             )["error"]["code"] == "not_found"

      assert [%{action: :quarantine, subject_id: id, actor_profile_id: actor, reason: reason}] =
               Ash.read!(ModerationAction, authorize?: false)

      assert id == thread.id
      assert actor == moderator.id
      assert reason == "Read like an advertisement, not a question."
    end

    test "puts a held thread back in public view", %{conn: conn} do
      thread = thread!()
      conn = signed_in(conn, moderator!())

      for action <- ["quarantine", "publish"] do
        post(conn, ~p"/moderation", %{
          "subject" => %{
            "kind" => "thread",
            "id" => thread.id,
            "action" => action,
            "reason" => "Decided twice, on purpose."
          }
        })
      end

      assert Ash.get!(Report, thread.id).visibility == :published

      assert conn |> recycle() |> get(~p"/posts/#{thread.id}") |> html_response(200) =~
               thread.title

      assert Ash.read!(ModerationAction, authorize?: false)
             |> Enum.map(& &1.action)
             |> Enum.sort() ==
               [:publish, :quarantine]
    end

    test "is a moderator's alone, even when it skips the door" do
      thread = thread!()

      reply =
        Forum.add_reply!(
          %{
            report_id: thread.id,
            browser_session_id: Ash.UUID.generate(),
            verdict: :unknown,
            note: "Declined cards empty the cart on purpose."
          },
          authorize?: false
        )

      not_a_moderator = moderator!("0x" <> String.duplicate("b", 40))

      for subject <- [thread, reply] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Forum.moderate(subject, :quarantine, "Not mine to decide.", not_a_moderator)
      end

      assert Ash.get!(Report, thread.id).visibility == :published
      assert Ash.get!(Patchbay.Forum.Reply, reply.id).visibility == :published
      assert Ash.read!(ModerationAction, authorize?: false) == []

      assert {:ok, %{visibility: :quarantined}} =
               Forum.moderate(reply, :quarantine, "Off topic.", moderator!())
    end

    test "is refused with no one acting, and to an agent acting for a moderator" do
      thread = thread!()
      moderator = moderator!()

      agent_for_moderator = %Patchbay.Agents.Actor{
        id: Ash.UUID.generate(),
        wallet_address: "0x" <> String.duplicate("c", 40),
        privy_user_id: moderator.privy_user_id,
        pairing_id: Ash.UUID.generate(),
        beneficiary_profile_id: moderator.id
      }

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.update(thread, %{visibility: :quarantined}, action: :set_visibility)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.update(thread, %{visibility: :redacted},
                 action: :set_visibility,
                 actor: agent_for_moderator
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Forum.moderate(thread, :redact, "Not an agent's call.", agent_for_moderator)

      assert Ash.get!(Report, thread.id).visibility == :published
      assert Ash.read!(ModerationAction, authorize?: false) == []
    end

    test "putting a held thread back is refused when nobody is signed in" do
      {:ok, held} = Forum.moderate(thread!(), :quarantine, "Held for a look.", moderator!())

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.update(held, %{visibility: :published}, action: :set_visibility)

      assert {:error, %Ash.Error.Forbidden{}} =
               Forum.moderate(held, :publish, "Nobody signed in.", nil)

      assert Ash.get!(Report, held.id, authorize?: false).visibility == :quarantined

      assert Ash.read!(ModerationAction, authorize?: false) |> Enum.map(& &1.action) == [
               :quarantine
             ]
    end
  end
end
