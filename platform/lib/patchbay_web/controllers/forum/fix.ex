defmodule PatchbayWeb.Forum.Fix do
  @moduledoc """
  Asking Jev from the form at the top of the home page: what the form sends
  (what the person is trying to do or expects, the site, up to five of the
  site's tools they picked and, under Add details, what happened), turned
  into an assist request; which way
  the Jev button works right now, free, after a sign-in or for the fee;
  whether the WebMCP Site Directory is offered; and what the page says when
  a fix cannot start.
  """

  require Logger

  alias Patchbay.Assist
  alias Patchbay.Assist.Allowance
  alias Patchbay.Assist.Request
  alias PatchbayWeb.ClientAddress
  alias PatchbayWeb.Forum.FixCheck
  alias PatchbayWeb.Forum.Hero

  @fee "0.10"

  @type mode :: :free | :sign_in | :pay | :closed | :unknown
  @type problem :: %{said: String.t()}

  @doc "The fee a fix costs once the free ones are used, in USDC."
  @spec fee() :: String.t()
  def fee, do: @fee

  @doc """
  The request the form asks for, or why it cannot be one. The page never
  asks about signing in: Patchbay acts on no one's account, and says so.
  """
  @spec request(Hero.draft()) :: {:ok, Request.request()} | {:error, problem()}
  def request(draft) do
    %{
      "goal" => draft["goal"],
      "site_url" => draft["site_url"],
      "error" => draft["details"],
      "sign_in" => "unknown",
      "believed_calls" => Enum.map(draft["tools"], &%{"tool" => &1})
    }
    |> Request.draft()
    |> refusal()
  end

  @doc """
  What is left for this request's connection and person, and which way the
  form works. When the free fixes could not be counted the form still takes
  a request, and Patchbay counts again when it is sent.
  """
  @spec offer(Plug.Conn.t()) :: %{
          allowance: Allowance.t() | nil,
          mode: mode(),
          fee: String.t(),
          directory: boolean()
        }
  def offer(conn) do
    profile = conn.assigns.current_profile

    {allowance, mode} =
      case Allowance.remaining(ClientAddress.visitor_key(conn), profile) do
        {:ok, allowance} ->
          {allowance, mode(allowance, profile)}

        {:error, failure} ->
          log_uncounted(failure)
          {nil, :unknown}
      end

    %{
      allowance: allowance,
      mode: mode,
      fee: @fee,
      directory: FixCheck.directory?(conn)
    }
  end

  @doc "The grant the next free fix from this request opens under, or why there is none."
  @spec grant(Plug.Conn.t()) :: {:ok, :visitor | :member} | {:error, problem()}
  def grant(conn) do
    profile = conn.assigns.current_profile

    case Allowance.grant(ClientAddress.visitor_key(conn), profile) do
      {:ok, grant} -> {:ok, grant}
      :none -> {:error, %{said: used_up(profile)}}
      :given_out -> {:error, %{said: given_out(mode(%{free: 0, given_out: true}, profile))}}
      {:error, failure} -> {:error, uncounted(failure)}
    end
  end

  @doc "What the form's button says."
  @spec button(%{allowance: Allowance.t() | nil, mode: mode()}) :: String.t()
  def button(%{mode: :free}), do: "Fix it free"
  def button(%{mode: :sign_in, allowance: %{given_out: true}}), do: "Sign in to fix it"
  def button(%{mode: :sign_in}), do: "Sign in for free fixes"
  def button(%{mode: :pay}), do: "Fix it for #{@fee} USDC"
  def button(%{mode: :closed}), do: "Free fixes used for today"
  def button(%{mode: :unknown}), do: "Fix it"

  @doc """
  What the page says when the run could not be opened: when the free fix
  was taken by another request in the meantime, the words for what is left
  now; when Patchbay could not tell whether a fix is already under way, that.
  """
  @spec refused(term(), Plug.Conn.t()) :: problem()
  def refused(:open_run_unknown, _conn),
    do: %{
      said:
        "Patchbay could not check whether a fix is already under way for you, so it did not start another. Try again in a moment."
    }

  def refused(%Ash.Error.Forbidden{}, conn) do
    case grant(conn) do
      {:error, problem} -> problem
      {:ok, _grant} -> not_started()
    end
  end

  def refused(_failure, _conn), do: not_started()

  defp not_started, do: %{said: "That fix could not be started just now. Try again in a moment."}

  defp mode(%{free: free}, _profile) when free > 0, do: :free
  defp mode(%{given_out: false}, nil), do: :sign_in

  defp mode(_used, profile) do
    cond do
      is_nil(Assist.pay_to_address()) -> :closed
      is_nil(profile) -> :sign_in
      true -> :pay
    end
  end

  defp uncounted(failure) do
    log_uncounted(failure)

    %{
      said:
        "Patchbay could not check your free fixes just now, so it did not start a fix. Try again in a moment."
    }
  end

  defp log_uncounted(failure),
    do:
      Logger.warning("Free fixes could not be counted", error_type: inspect(error_type(failure)))

  defp error_type(failure) when is_struct(failure), do: failure.__struct__
  defp error_type(failure), do: failure

  defp used_up(nil),
    do: "This connection's free fix for today is used. Sign in for two more free fixes today."

  defp used_up(_profile) do
    if Assist.pay_to_address(),
      do:
        "Your free fixes for today are used. The next one is #{@fee} USDC from your USDC Balance.",
      else: "Your free fixes for today are used. Come back tomorrow."
  end

  defp given_out(:sign_in),
    do:
      "Today's free fixes are all given out. Sign in to fix it for #{@fee} USDC from your USDC Balance."

  defp given_out(:pay), do: "Today's free fixes are all given out. " <> paid_from_wallet()
  defp given_out(:closed), do: "Today's free fixes are all given out. Come back tomorrow."

  defp paid_from_wallet, do: "This one is #{@fee} USDC from your USDC Balance."

  defp refusal({:ok, request}), do: {:ok, request}

  defp refusal({:error, {:invalid, [rule | _rest]}}) do
    said =
      case String.split(rule, ":", parts: 2) do
        ["goal" | _] ->
          "Say what you are trying to do or the result you expect, in up to 1,000 characters."

        ["site_url" | _] ->
          "The site needs a public https address, like https://example.com/app."

        ["error" | _] ->
          "To ask Jev, say what happened in up to 4,000 characters."

        _believed_calls ->
          "Pick up to 5 of the site's tools."
      end

    {:error, %{said: said}}
  end
end
