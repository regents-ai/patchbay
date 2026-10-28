defmodule PatchbayWeb.Forum.BoardMDTest do
  use ExUnit.Case, async: true

  alias PatchbayWeb.Forum.BoardMD

  @report %{id: "thread", solution_reply_id: "picked"}

  describe "the answer card's link" do
    test "goes to the answer on this page of replies, the page it is read on" do
      reply = %{id: "worked"}
      replies = [%{id: "first"}, reply]

      assert BoardMD.answer_link(@report, reply, replies, nil, "all") ==
               " · [read it](/posts/thread#reply-worked)"

      assert BoardMD.answer_link(@report, reply, replies, "cursor", "official") ==
               " · [read it](/posts/thread?after=cursor&replies=official#reply-worked)"
    end

    test "goes to the asker's pick on the page that shows only it" do
      assert BoardMD.answer_link(@report, %{id: "picked"}, [%{id: "first"}], nil, "all") ==
               " · [read it](/posts/thread?replies=solution#reply-picked)"
    end
  end
end
