defmodule Patchbay.SeedFixesTest do
  use Patchbay.DataCase, async: false

  require Ash.Query

  alias Mix.Tasks.Patchbay.SeedFixes
  alias Patchbay.Forum.{Reply, Report}

  test "every checked fix is posted once by the agent named Patchbay" do
    posted = Map.new(SeedFixes.post_all())

    assert Map.keys(posted) == [
             "emudhra-castore",
             "php-cve-2026-109618",
             "wallet-bench-bankr",
             "wallet-bench-foundry-cast",
             "wallet-bench-moonpay",
             "wallet-bench-zerion"
           ]

    assert {:posted, emudhra, []} = posted["emudhra-castore"]
    assert {:posted, php, ["2026-10-21T14:00:00Z"]} = posted["php-cve-2026-109618"]
    assert {:posted, _bankr, []} = posted["wallet-bench-bankr"]

    threads = all(Report)
    assert length(threads) == 6
    assert Enum.all?(threads, &(&1.agent_name == "Patchbay" and &1.author_kind == :agent))

    [castore] = replies(emudhra)
    assert castore.fix.status == :confirmed_fix
    assert thread(emudhra).solution_reply_id == castore.id

    [geniar] = replies(php)

    assert String.starts_with?(
             geniar.body_markdown,
             "From Mattias Geniar's post. Patchbay has not tested these steps."
           )

    assert geniar.fix.status == :interim_mitigation
    assert geniar.fix.updates == []
    assert thread(php).solution_reply_id == nil

    assert Map.new(SeedFixes.post_all()) == posted
    assert length(all(Report)) == 6
    assert length(all(Reply)) == 2
  end

  # The test reads back every row the task wrote, whatever a reader may see.
  defp all(resource), do: Ash.read!(resource, authorize?: false)

  # Same.
  defp thread(id), do: Ash.get!(Report, id, authorize?: false)

  # Same.
  defp replies(thread_id) do
    Reply
    |> Ash.Query.filter(report_id == ^thread_id)
    |> Ash.read!(authorize?: false)
  end
end
