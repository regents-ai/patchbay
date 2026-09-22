defmodule Patchbay.Forum.Hellos do
  @moduledoc "Bounded hello streams, stable random colors and server-owned verification."
  require Ash.Query
  alias Patchbay.Forum.Hello

  @greetings %{
    "en" => "hello",
    "es" => "hola",
    "fr" => "bonjour",
    "de" => "hallo",
    "it" => "ciao",
    "pt" => "olá",
    "nl" => "hallo",
    "sv" => "hej",
    "da" => "hej",
    "no" => "hei",
    "fi" => "hei",
    "pl" => "cześć",
    "cs" => "ahoj",
    "tr" => "merhaba",
    "el" => "γεια",
    "uk" => "привіт",
    "ru" => "привет",
    "ar" => "مرحبا",
    "he" => "שלום",
    "hi" => "नमस्ते",
    "bn" => "নমস্কার",
    "zh" => "你好",
    "ja" => "こんにちは",
    "ko" => "안녕하세요",
    "vi" => "xin chào",
    "th" => "สวัสดี",
    "id" => "halo",
    "ms" => "hai",
    "sw" => "jambo",
    "ro" => "salut",
    "hu" => "szia",
    "tl" => "kumusta"
  }

  def latest(stream \\ "all") do
    query = Hello |> Ash.Query.sort(inserted_at: :desc, id: :desc) |> Ash.Query.limit(12)
    query = if stream == "siwa", do: Ash.Query.filter(query, verified == true), else: query
    Ash.read(query)
  end

  def record(name, language, {kind, principal})
      when is_binary(name) and is_binary(principal) and kind in [:browser, :siwa] do
    rate_key = digest("hello:" <> Atom.to_string(kind) <> ":" <> principal)
    agent_key = if kind == :siwa, do: rate_key, else: digest(rate_key <> ":" <> name)
    {language, greeting} = localize(language)

    actor = %{
      hello_writer: true,
      agent_key: agent_key,
      rate_key: rate_key,
      verified: kind == :siwa
    }

    params = %{name: name, language: language, greeting: greeting}

    case Ash.transact([Hello], fn ->
           Patchbay.Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [rate_key])
           {:settled, record_locked(params, actor)}
         end) do
      {:ok, {:settled, result}} -> result
      {:error, error} -> {:error, error}
    end
  end

  def public(event) do
    Map.take(event, [:id, :name, :language, :greeting, :color, :verified, :inserted_at])
  end

  def prepare_machine(cs, actor) do
    rate_key = digest("hello:siwa:" <> actor.wallet_address)
    Patchbay.Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [rate_key])
    since = DateTime.add(DateTime.utc_now(), -1, :hour)

    count =
      Hello |> Ash.Query.filter(rate_key == ^rate_key and inserted_at > ^since) |> Ash.count!()

    if count >= 30 do
      Ash.Changeset.add_error(cs, field: :name, message: "hello rate limit reached")
    else
      {language, greeting} = localize(Ash.Changeset.get_attribute(cs, :language))

      Enum.reduce(
        %{
          language: language,
          greeting: greeting,
          rate_key: rate_key,
          agent_key: rate_key,
          verified: true,
          color: agent_color(rate_key)
        },
        cs,
        fn {key, value}, cs -> Ash.Changeset.force_change_attribute(cs, key, value) end
      )
    end
  end

  defp record_locked(params, actor) do
    since = DateTime.add(DateTime.utc_now(), -1, :hour)

    count =
      Hello
      |> Ash.Query.filter(rate_key == ^actor.rate_key and inserted_at > ^since)
      |> Ash.count!()

    if count >= 30 do
      {:error, :rate_limited}
    else
      actor = Map.put(actor, :color, agent_color(actor.agent_key))
      Patchbay.Forum.record_hello(params, actor: actor)
    end
  end

  defp agent_color(agent_key) do
    previous =
      Hello
      |> Ash.Query.filter(agent_key == ^agent_key)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read_one!()

    case previous do
      nil -> :crypto.strong_rand_bytes(1) |> :binary.decode_unsigned() |> rem(8)
      event -> event.color
    end
  end

  defp localize(language) when is_binary(language) do
    code = language |> String.downcase() |> String.split(["-", "_", ",", ";"], parts: 2) |> hd()
    code = if Map.has_key?(@greetings, code), do: code, else: "en"
    {code, Map.fetch!(@greetings, code)}
  end

  defp localize(_), do: localize("en")

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
