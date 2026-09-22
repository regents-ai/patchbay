defmodule PatchbayWeb.PublicationAuthorizationController do
  use PatchbayWeb, :controller
  alias Patchbay.Forum.PublicationGrant
  require Ash.Query

  def index(conn, _params), do: page(conn, %{})

  def create(%{assigns: %{current_profile: nil}} = conn, _),
    do:
      page(put_status(conn, :unauthorized), %{notice: "Sign in before approving public posting."})

  def create(%{assigns: %{current_profile: %{status: status}}} = conn, _) when status != :active,
    do: page(put_status(conn, :unauthorized), %{notice: "An active profile is required."})

  def create(conn, %{"grant" => params}) when is_map(params) do
    if valid_shape?(params) do
      submit(conn, params)
    else
      page(put_status(conn, :unprocessable_entity), %{
        notice: "Use text fields and a list of selected public operations."
      })
    end
  end

  def create(conn, _), do: page(put_status(conn, :unprocessable_entity), %{})

  defp submit(conn, params) do
    form =
      AshPhoenix.Form.for_create(PublicationGrant, :approve,
        actor: conn.assigns.current_profile,
        as: "grant"
      )

    case AshPhoenix.Form.submit(form, params: params) do
      {:ok, _grant} -> redirect(conn, to: ~p"/publication-authorizations")
      {:error, form} -> page(put_status(conn, :unprocessable_entity), %{form: form})
    end
  end

  defp valid_shape?(params) do
    Enum.all?(params, fn
      {"operations", values} ->
        is_list(values) and Enum.all?(values, &is_binary/1)

      {key, value}
      when key in ~w(subject_wallet purpose mode site_origin thread_id expires_at public_confirmation) ->
        is_binary(value)

      _ ->
        false
    end)
  end

  def finish(%{assigns: %{current_profile: nil}} = conn, _),
    do: page(put_status(conn, :unauthorized), %{notice: "Sign in to manage your permissions."})

  def finish(%{assigns: %{current_profile: %{status: status}}} = conn, _) when status != :active,
    do: page(put_status(conn, :unauthorized), %{notice: "An active profile is required."})

  def finish(conn, %{"id" => id, "action" => action}) when action in ["revoke", "complete"] do
    actor = conn.assigns.current_profile

    with {:ok, grant} <- Ash.get(PublicationGrant, id, actor: actor),
         {:ok, _} <-
           Ash.update(grant, %{},
             action: if(action == "revoke", do: :revoke, else: :complete),
             actor: actor
           ) do
      redirect(conn, to: ~p"/publication-authorizations")
    else
      _ ->
        page(put_status(conn, :not_found), %{
          notice: "Authorization unavailable or already ended."
        })
    end
  end

  def finish(conn, _),
    do: page(put_status(conn, :bad_request), %{notice: "Choose revoke or complete."})

  defp page(conn, values) do
    actor =
      case conn.assigns[:current_profile] do
        %{authentication_origin: :privy, status: :active} = actor -> actor
        _ -> nil
      end

    grants =
      if actor,
        do: PublicationGrant |> Ash.Query.sort(inserted_at: :desc) |> Ash.read!(actor: actor),
        else: []

    form =
      values[:form] ||
        AshPhoenix.Form.for_create(PublicationGrant, :approve, actor: actor, as: "grant")

    conn
    |> assign(:current_profile, actor)
    |> put_resp_header("cache-control", "no-store")
    |> put_view(html: PatchbayWeb.PublicationAuthorizationHTML)
    |> render(:index,
      page_title: "Public posting permissions",
      grants: grants,
      form: Phoenix.Component.to_form(form),
      notice: values[:notice]
    )
  end
end
