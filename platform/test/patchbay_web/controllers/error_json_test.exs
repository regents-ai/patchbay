defmodule PatchbayWeb.ErrorJSONTest do
  use PatchbayWeb.ConnCase, async: true

  alias PatchbayWeb.SiteEdition

  test "renders 404 with a code and a hint naming this address's map" do
    SiteEdition.put(:main)
    main = SiteEdition.url(:main)

    assert %{
             error: %{code: "not_found", message: "There is nothing at this address.", hint: hint}
           } =
             PatchbayWeb.ErrorJSON.render("404.json", %{})

    assert hint =~ "#{main}/openapi.json"
    assert hint =~ "#{main}/llms.txt"
  end

  test "renders 500 with a code" do
    SiteEdition.put(:main)

    assert %{error: %{code: "internal_error", message: "Patchbay could not answer that request."}} =
             PatchbayWeb.ErrorJSON.render("500.json", %{})
  end

  test "an unknown status still carries a code derived from its name" do
    SiteEdition.put(:main)

    assert %{error: %{code: "unprocessable_content"}} =
             PatchbayWeb.ErrorJSON.render("422.json", %{})
  end
end
