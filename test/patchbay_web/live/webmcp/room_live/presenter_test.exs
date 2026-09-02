defmodule PatchbayWeb.WebMCP.RoomLive.PresenterTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PatchbayWeb.WebMCP.RoomLive.Presenter

  defp evidence_json(value) do
    html = render_component(&Presenter.evidence_text/1, value: value)

    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("pre")
    |> LazyHTML.text()
    |> Jason.decode!()
  end

  test "the evidence panel shows a nested boolean and a nested nil as JSON, not as text" do
    value = %{"applied" => true, "verified" => false, "candidate_sha256" => nil}

    assert evidence_json(value) == value
  end

  test "the evidence panel names a nested atom and an atom key as strings" do
    value = %{status: :verified_success, checks: [:frontmatter_valid]}

    assert evidence_json(value) == %{
             "status" => "verified_success",
             "checks" => ["frontmatter_valid"]
           }
  end
end
