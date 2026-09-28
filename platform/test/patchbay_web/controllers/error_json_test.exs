defmodule PatchbayWeb.ErrorJSONTest do
  use PatchbayWeb.ConnCase, async: true

  test "renders 404 with a code and a hint" do
    assert PatchbayWeb.ErrorJSON.render("404.json", %{}) == %{
             error: %{
               code: "not_found",
               message: "There is nothing at this address.",
               hint:
                 "The public endpoints are described at /openapi.json and the agent guide at /llms.txt."
             }
           }
  end

  test "renders 500 with a code" do
    assert %{error: %{code: "internal_error", message: "Patchbay could not answer that request."}} =
             PatchbayWeb.ErrorJSON.render("500.json", %{})
  end

  test "an unknown status still carries a code derived from its name" do
    assert %{error: %{code: "unprocessable_content"}} =
             PatchbayWeb.ErrorJSON.render("422.json", %{})
  end
end
