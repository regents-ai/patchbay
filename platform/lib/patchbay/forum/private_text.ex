defmodule Patchbay.Forum.PrivateText do
  @moduledoc """
  Spots text that looks private before it is made public: keys and tokens,
  passwords, private keys, email addresses, phone numbers and card numbers.

  It only points things out. Someone may mean to share a support address,
  so nothing is removed or refused here; the person posting decides. Wallet
  addresses are public by design and are not flagged.
  """

  @typedoc "One thing that looks private: what kind, and the text it was seen in, shortened."
  @type finding :: %{kind: atom(), said: String.t(), excerpt: String.t()}

  @checks [
    {:private_key, ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/,
     "This looks like a private key. Anyone who reads it can use it."},
    {:wallet_key, ~r/\b0x[0-9a-fA-F]{64}\b/,
     "This looks like a wallet's secret key. Anyone who reads it can take what the wallet holds."},
    {:access_token,
     ~r/\b(?:sk|pk|rk)_(?:live|test)_[0-9A-Za-z]{16,}|\bsk-[0-9A-Za-z_-]{20,}|\bgh[pousr]_[0-9A-Za-z]{30,}|\bxox[abpsr]-[0-9A-Za-z-]{10,}|\bAKIA[0-9A-Z]{16}\b|\bAIza[0-9A-Za-z_-]{35}\b|\beyJ[0-9A-Za-z_-]{10,}\.[0-9A-Za-z_-]{10,}\.[0-9A-Za-z_-]{10,}/,
     "This looks like a key or sign-in token for an account."},
    {:bearer, ~r/\b(?:Bearer|Basic)\s+[0-9A-Za-z._~+\/=-]{16,}/,
     "This looks like a sign-in token copied from a request."},
    {:password,
     ~r/\b(?:password|passwd|pwd|passcode|secret|api[_-]?key|access[_-]?token|client[_-]?secret)\b\s*["']?\s*[:=]\s*["']?[^\s"',;]{4,}/i,
     "This looks like a password or secret written out."},
    {:email, ~r/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/,
     "This looks like an email address."},
    {:phone, ~r/(?<![\w.])\+?\d{1,3}[\s.-]?\(?\d{2,4}\)?[\s.-]\d{3,4}[\s.-]\d{3,4}(?![\w.])/,
     "This looks like a phone number."}
  ]

  @doc """
  Everything in the text that looks private, in the order of the checks and
  at most once per kind. Card numbers are checked apart from the rest, since
  a run of digits is a card only when its check digit adds up.
  """
  @spec findings(String.t() | nil) :: [finding()]
  def findings(nil), do: []

  def findings(text) when is_binary(text) do
    patterned =
      for {kind, pattern, said} <- @checks,
          [match | _] <- [Regex.run(pattern, text)],
          do: %{kind: kind, said: said, excerpt: excerpt(match)}

    patterned ++ card(text)
  end

  defp card(text) do
    ~r/\b(?:\d[ -]?){13,19}\b/
    |> Regex.scan(text)
    |> Enum.map(&hd/1)
    |> Enum.find(fn candidate -> candidate |> digits() |> luhn?() end)
    |> case do
      nil ->
        []

      match ->
        [%{kind: :card, said: "This looks like a payment card number.", excerpt: excerpt(match)}]
    end
  end

  defp digits(candidate), do: for(<<c <- candidate>>, c in ?0..?9, do: c - ?0)

  defp luhn?(digits) when length(digits) in 13..19 do
    digits
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.map(fn
      {d, i} when rem(i, 2) == 1 and d * 2 > 9 -> d * 2 - 9
      {d, i} when rem(i, 2) == 1 -> d * 2
      {d, _i} -> d
    end)
    |> Enum.sum()
    |> rem(10) == 0
  end

  defp luhn?(_digits), do: false

  # Enough of the match to find it again, never the whole secret.
  defp excerpt(match) do
    match = String.trim(match)

    if String.length(match) <= 8,
      do: String.first(match) <> "…",
      else: String.slice(match, 0, 6) <> "…"
  end
end
