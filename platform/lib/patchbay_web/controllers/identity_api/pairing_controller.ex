defmodule PatchbayWeb.IdentityAPI.PairingController do
  @moduledoc """
  Where an agent, signing with its wallet, sends the code a person gave it to
  pair with them. The wallet is the one the signed request proved; the code
  names the person.
  """

  use PatchbayWeb, :controller

  alias PatchbayWeb.IdentityAPI.Pairing

  def create(conn, %{"code" => code}) do
    case Pairing.run(conn.assigns.current_profile, code) do
      {:ok, paired} -> json(conn, paired)
      {:error, refused} -> conn |> put_status(:unprocessable_entity) |> json(refused)
    end
  end
end
