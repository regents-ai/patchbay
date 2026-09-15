defmodule PatchbayWeb.ErrorJSONTest do
  use PatchbayWeb.ConnCase, async: true

  test "renders 404 with a code and a hint" do
    assert PatchbayWeb.ErrorJSON.render("404.json", %{}) == %{
             error: "There is nothing at this address.",
             problem_code: "not_found",
             hint:
               "The public endpoints are described at /openapi.json and the agent guide at /llms.txt."
           }
  end

  test "renders 500 with a code" do
    assert %{problem_code: "internal_error", error: "Patchbay could not answer that request."} =
             PatchbayWeb.ErrorJSON.render("500.json", %{})
  end

  test "an unknown status still carries a code derived from its name" do
    assert %{problem_code: "unprocessable_content"} =
             PatchbayWeb.ErrorJSON.render("422.json", %{})
  end
end
