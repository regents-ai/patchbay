defmodule PatchbayWeb.DiscoveryController do
  @moduledoc """
  The files an agent or crawler reads to find its way around: the API
  description, the agent guide, robots.txt, the security contact and the API
  catalog. They change only with a release, so each carries a sha256 ETag of
  its body and a five-minute public cache. No account, no database.
  """

  use PatchbayWeb, :controller

  @directory "priv/public"
  @files Map.new(~w(openapi.json llms.txt robots.txt), &{&1, Path.join(@directory, &1)})
  for {_name, path} <- @files, do: @external_resource(path)

  @sources @files
           |> Map.new(fn {name, path} -> {name, File.read!(path)} end)
           |> Map.update!(
             "llms.txt",
             &String.replace(&1, "{{key_facts}}", Patchbay.About.key_facts())
           )

  # The release time: security.txt expires a year after it.
  @released_at DateTime.utc_now() |> DateTime.truncate(:second)

  def openapi(conn, _params) do
    body = @sources["openapi.json"]
    conn |> cache(body) |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  def llms(conn, _params) do
    body = @sources["llms.txt"]
    conn |> cache(body) |> put_resp_content_type("text/plain") |> send_resp(200, body)
  end

  def robots(conn, _params) do
    body = @sources["robots.txt"]
    conn |> cache(body) |> put_resp_content_type("text/plain") |> send_resp(200, body)
  end

  @doc "The RFC 9116 security contact; it expires a year after the release."
  def security(conn, _params) do
    body = """
    Contact: mailto:build@regents.sh
    Expires: #{@released_at |> DateTime.shift(year: 1) |> DateTime.to_iso8601()}
    Preferred-Languages: en
    Canonical: #{url(~p"/.well-known/security.txt")}
    Policy: #{url(~p"/contact")}
    """

    conn |> cache(body) |> put_resp_content_type("text/plain") |> send_resp(200, body)
  end

  @doc """
  The token OpenAI's plugin portal gives for proving this address is
  Patchbay's, as plain text. Not found until the token is set.
  """
  def openai_apps_challenge(conn, _params) do
    case Application.get_env(:patchbay, :openai_apps_challenge) do
      nil -> send_resp(conn, 404, "")
      token -> conn |> put_resp_content_type("text/plain") |> send_resp(200, token)
    end
  end

  @doc "The RFC 9727 API catalog: the API, its description and its documentation."
  # The body is JSON built from this site's own addresses, sent as a linkset with
  # the RFC 9727 profile, which Sobelow does not read as a safe content type.
  # sobelow_skip ["XSS.SendResp"]
  def api_catalog(conn, _params) do
    body =
      Jason.encode!(%{
        "linkset" => [
          %{
            "anchor" => url(~p"/"),
            "service-desc" => [%{"href" => url(~p"/openapi.json"), "type" => "application/json"}],
            "service-doc" => [%{"href" => url(~p"/docs"), "type" => "text/html"}]
          }
        ]
      })

    conn
    |> cache(body)
    |> put_resp_content_type(
      ~s(application/linkset+json; profile="https://www.rfc-editor.org/info/rfc9727"),
      nil
    )
    |> send_resp(200, body)
  end

  defp cache(conn, body) do
    conn
    |> put_resp_header("etag", ~s("#{Base.encode16(:crypto.hash(:sha256, body), case: :lower)}"))
    |> put_resp_header("cache-control", "public, max-age=300")
  end
end
