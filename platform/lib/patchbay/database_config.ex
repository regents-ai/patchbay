defmodule Patchbay.DatabaseConfig do
  @moduledoc """
  The database Patchbay connects to, as in the Regent template.

  Production serves through `DATABASE_POOLED_URL` and runs release commands
  through `DATABASE_DIRECT_URL`, both on the shared cluster's direct host over
  verified TLS. Patchbay runs in production only, so `PATCHBAY_DEPLOYMENT_ROLE`
  accepts `production` and nothing else. A developer may point a local
  Patchbay at the shared cluster by naming it in `PATCHBAY_DATABASE_CLUSTER_ID`
  and `PATCHBAY_DATABASE_CLUSTER_NAME`; otherwise `config/dev.exs` holds the
  local database.
  """

  @cluster_id "dzx6qo6xqzvojpv5"
  @cluster_name "regents-platform-prod"
  @production_database_host "direct.dzx6qo6xqzvojpv5.flympg.net"
  # Superseded identities refused in production configuration: the legacy
  # platform application and the retired rehearsal cluster.
  @production_identities ["platform-phx", "regents-pg-test", "nvwq9ozp9ye03kl1"]
  @deployment_role_error ~s(PATCHBAY_DEPLOYMENT_ROLE must be set to "production")
  @remote_target_error "remote database access requires cluster dzx6qo6xqzvojpv5 named regents-platform-prod"

  def runtime_config!(environment, getenv \\ &System.get_env/1)

  def runtime_config!(:prod, getenv) do
    :production = deployment_role!(getenv)
    getenv |> database_url!("DATABASE_POOLED_URL", :production) |> serving()
  end

  def runtime_config!(:dev, getenv) do
    case remote_target(getenv) do
      :local -> []
      :remote -> database_url!(getenv, "DATABASE_POOLED_URL", :remote)
    end
  end

  def release_config!(getenv \\ &System.get_env/1) do
    :production = deployment_role!(getenv)
    require_production_target!(getenv)
    database_url!(getenv, "DATABASE_DIRECT_URL", :production)
  end

  # The serving connection shares one database with every other site, so it holds
  # five connections, names itself in pg_stat_activity, keeps connection details out
  # of its errors, and gives up on a statement, a lock wait or an idle open transaction
  # before it can stall anyone else. Release commands connect with their own login
  # and none of these limits.
  defp serving(options) do
    Keyword.merge(options,
      pool_size: 5,
      show_sensitive_data_on_connection_error: false,
      parameters: [
        application_name: "patchbay-web",
        statement_timeout: "15000",
        lock_timeout: "5000",
        idle_in_transaction_session_timeout: "15000"
      ]
    )
  end

  # No default: an unset or unrecognized role stops the boot before any database
  # URL is read.
  defp deployment_role!(getenv) do
    case getenv.("PATCHBAY_DEPLOYMENT_ROLE") do
      "production" -> :production
      _unset_or_unknown -> raise @deployment_role_error
    end
  end

  # The hosts a venue admits (any, for a developer's remote target) and the terms
  # its URL may not name anywhere.
  defp venue(:production), do: {[@production_database_host], @production_identities}
  defp venue(:remote), do: {nil, @production_identities}

  defp database_url!(getenv, variable, venue) do
    {admitted_hosts, refused_terms} = venue(venue)

    with value when is_binary(value) and value != "" <- getenv.(variable),
         {:ok, %URI{scheme: scheme, host: host, path: "/" <> database, userinfo: userinfo} = uri}
         when scheme in ["postgres", "postgresql"] <- URI.new(value),
         true <- present?(host) and present?(database) and valid_userinfo?(userinfo),
         false <- refused_identity?(uri, refused_terms),
         {:ok, url, admitted_host} <- admit(value, uri, admitted_hosts),
         true <- fixed_endpoint?(uri) and valid_ecto_url?(value) do
      connection_options(url, admitted_host)
    else
      value when value in [nil, ""] -> raise "#{variable} is required"
      _ -> raise "#{variable} must be a valid PostgreSQL URL for the approved target"
    end
  end

  defp admit(value, %URI{host: host}, nil), do: {:ok, value, host}

  defp admit(_value, %URI{host: host} = uri, admitted_hosts) do
    admitted_host = String.downcase(host)

    if admitted_host in admitted_hosts,
      do: {:ok, URI.to_string(%{uri | host: admitted_host}), admitted_host},
      else: :error
  end

  defp valid_ecto_url?(value) do
    Ecto.Repo.Supervisor.parse_url(value)
    true
  rescue
    _error -> false
  end

  # Every host an allowlist admits is fixed by its hostname alone, so none may carry
  # a port other than PostgreSQL's or any query option: Ecto turns every URL query key
  # into an atom and merges parsed URL options after the explicit Repo configuration,
  # so even encoded or future aliases could otherwise weaken TLS, replace the endpoint,
  # or restore named prepares after this module's checks.
  defp fixed_endpoint?(%URI{host: host, port: port, query: query}) do
    not fly_mpg_host?(host) or (port in [nil, 5432] and query in [nil, ""])
  end

  # A URL without a port connects to PostgreSQL's, not a port an explicit option
  # elsewhere would otherwise keep.
  defp connection_options(url, host) do
    options = [url: url, port: URI.parse(url).port || 5432, socket_options: [:inet6]]
    if fly_mpg_host?(host), do: fly_mpg_options(host) ++ options, else: options
  end

  defp fly_mpg_options(host) do
    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    if host |> String.downcase() |> String.starts_with?("pgbouncer."),
      do: [prepare: :unnamed, ssl: ssl],
      else: [ssl: ssl]
  end

  defp fly_mpg_host?(host) do
    host = String.downcase(host)
    host != "flympg.net" and String.ends_with?(host, ".flympg.net")
  end

  defp remote_target(getenv) do
    cluster_id = getenv.("PATCHBAY_DATABASE_CLUSTER_ID")
    cluster_name = getenv.("PATCHBAY_DATABASE_CLUSTER_NAME")

    cond do
      production_identity?(getenv.("FLY_APP_NAME")) -> raise @remote_target_error
      is_nil(cluster_id) and is_nil(cluster_name) -> :local
      cluster_id == @cluster_id and cluster_name == @cluster_name -> :remote
      true -> raise @remote_target_error
    end
  end

  defp require_production_target!(getenv) do
    if getenv.("PATCHBAY_DATABASE_TARGET_MODE") == "production" and
         getenv.("PATCHBAY_DATABASE_CLUSTER_ID") == @cluster_id and
         getenv.("PATCHBAY_DATABASE_CLUSTER_NAME") == @cluster_name and
         not production_identity?(getenv.("FLY_APP_NAME")) do
      :ok
    else
      raise "database migration requires production mode for cluster dzx6qo6xqzvojpv5 named regents-platform-prod"
    end
  end

  defp valid_userinfo?(userinfo) when is_binary(userinfo),
    do: userinfo |> String.split(":", parts: 2) |> Enum.map(&present?/1) == [true, true]

  defp valid_userinfo?(_userinfo), do: false

  defp refused_identity?(%URI{} = uri, refused_terms) do
    Enum.any?([uri.host, uri.path, uri.userinfo], &names_any?(&1, refused_terms))
  end

  defp production_identity?(value), do: names_any?(value, @production_identities)

  defp names_any?(value, terms) when is_binary(value) do
    decoded = value |> decode() |> String.downcase()
    Enum.any?(terms, &String.contains?(decoded, &1))
  end

  defp names_any?(_value, _terms), do: false

  defp decode(value) do
    URI.decode(value)
  rescue
    _error -> value
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
