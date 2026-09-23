defmodule PatchbayWeb.Forum.Fix do
  @moduledoc """
  The fix form at the top of the home page: what it sends, turned into an
  assist request; which way the form works right now, free, after a sign-in
  or for the fee, and the person's Patchbay Credits once it is the fee; and
  what the page says when a fix cannot start.
  """

  alias Patchbay.Assist
  alias Patchbay.Assist.Allowance
  alias Patchbay.Assist.Request
  alias Patchbay.Payments.Credits
  alias Patchbay.Payments.PaymentIntent
  alias PatchbayWeb.ClientAddress

  @fields ~w(goal site_url expected_result sign_in tool arguments)
  @sign_ins ~w(none unknown required)
  @fee "0.10"

  @type draft :: %{String.t() => String.t()}
  @type mode :: :free | :sign_in | :pay | :closed
  @type problem :: %{said: String.t()}

  @doc "The fee a fix costs once the free ones are used, in USDC."
  @spec fee() :: String.t()
  def fee, do: @fee

  @doc "The form's fields as text, and nothing else."
  @spec draft(term()) :: draft()
  def draft(params) when is_map(params), do: Map.new(@fields, &{&1, text(params[&1])})
  def draft(_absent), do: Map.new(@fields, &{&1, ""})

  @doc "The request the form asks for, or why it cannot be one."
  @spec request(draft()) :: {:ok, Request.request()} | {:error, problem()}
  def request(draft) do
    with {:ok, believed_calls} <- believed_calls(draft["tool"], draft["arguments"]) do
      %{
        "goal" => draft["goal"],
        "site_url" => draft["site_url"],
        "expected_result" => draft["expected_result"],
        "sign_in" => sign_in(draft["sign_in"]),
        "believed_calls" => believed_calls
      }
      |> Request.draft()
      |> refusal()
    end
  end

  @doc """
  What is left for this request's connection and person, which way the form
  works, and, once a fix costs the fee, the signed-in person's Patchbay
  Credits.
  """
  @spec offer(Plug.Conn.t()) :: %{
          allowance: Allowance.t(),
          mode: mode(),
          fee: String.t(),
          credits: credits() | nil
        }
  def offer(conn) do
    profile = conn.assigns.current_profile
    allowance = Allowance.remaining(ClientAddress.visitor_key(conn), profile)
    mode = mode(allowance, profile)

    %{allowance: allowance, mode: mode, fee: @fee, credits: credits(mode, profile)}
  end

  @typedoc """
  The signed-in person's Patchbay Credits as the form shows them: the balance
  written out, whether it covers a fix, whether more can be bought by card,
  and where.
  """
  @type credits :: %{
          balance: String.t(),
          covers?: boolean(),
          on_sale?: boolean(),
          buy_at: String.t()
        }

  defp credits(:pay, profile) do
    balance = Credits.balance_atomic(profile.id)

    %{
      balance: Credits.written(balance),
      covers?: balance >= PaymentIntent.assist_fee_atomic(),
      on_sale?: Patchbay.Stripe.configured?(),
      buy_at: "/agents/#{profile.public_id}#patchbay-credits"
    }
  end

  defp credits(_mode, _profile), do: nil

  @doc "The grant the next free fix from this request opens under, or why there is none."
  @spec grant(Plug.Conn.t()) :: {:ok, :visitor | :member} | {:error, problem()}
  def grant(conn) do
    profile = conn.assigns.current_profile

    case Allowance.grant(ClientAddress.visitor_key(conn), profile) do
      {:ok, grant} -> {:ok, grant}
      :none -> {:error, %{said: used_up(profile)}}
      :given_out -> {:error, %{said: given_out(mode(%{free: 0, given_out: true}, profile))}}
    end
  end

  @doc "The words for the free fixes left, or for what the next fix costs."
  @spec terms(%{allowance: Allowance.t(), mode: mode()}) :: String.t()
  def terms(%{mode: :free, allowance: %{free: free, sign_in_adds: adds}}) do
    left =
      "#{free} free #{if free == 1, do: "fix", else: "fixes"} left today from this connection"

    more = if adds > 0, do: ", and #{adds} more when you sign in", else: ""
    "#{left}#{more}. After that, a fix is #{@fee} #{either_way()}."
  end

  def terms(%{mode: mode, allowance: %{given_out: true}}), do: given_out(mode)

  def terms(%{mode: :sign_in, allowance: %{sign_in_adds: adds}}),
    do: "This connection's free fix for today is used. Sign in for #{adds} more free fixes today."

  def terms(%{mode: :pay}), do: "Your free fixes for today are used. " <> paid_from_wallet()

  def terms(%{mode: :closed}), do: "Your free fixes for today are used. Come back tomorrow."

  @doc "What the form's button says."
  @spec button(%{allowance: Allowance.t(), mode: mode()}) :: String.t()
  def button(%{mode: :free}), do: "Fix it free"
  def button(%{mode: :sign_in, allowance: %{given_out: true}}), do: "Sign in to fix it"
  def button(%{mode: :sign_in}), do: "Sign in for free fixes"
  def button(%{mode: :pay}), do: "Fix it for #{@fee} USDC"
  def button(%{mode: :closed}), do: "Free fixes used for today"

  @doc """
  What the page says when the run could not be opened: when the free fix
  was taken by another request in the meantime, the words for what is left
  now.
  """
  @spec refused(term(), Plug.Conn.t()) :: problem()
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

  defp used_up(nil),
    do: "This connection's free fix for today is used. Sign in for two more free fixes today."

  defp used_up(_profile) do
    if Assist.pay_to_address(),
      do: "Your free fixes for today are used. The next one is #{@fee} #{either_way()}.",
      else: "Your free fixes for today are used. Come back tomorrow."
  end

  defp given_out(:sign_in),
    do: "Today's free fixes are all given out. Sign in to fix it for #{@fee} #{either_way()}."

  defp given_out(:pay), do: "Today's free fixes are all given out. " <> paid_from_wallet()
  defp given_out(:closed), do: "Today's free fixes are all given out. Come back tomorrow."

  defp paid_from_wallet, do: "This one is #{@fee} USDC from the wallet you signed in with."

  defp either_way, do: "USDC from your wallet, or #{@fee} in Patchbay Credits"

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_other), do: ""

  defp sign_in(value) when value in @sign_ins, do: value
  defp sign_in(_blank), do: "unknown"

  # A tool the person tried, with its arguments as they wrote them, or no
  # believed calls at all. Arguments have to be a JSON object.
  defp believed_calls("", _arguments), do: {:ok, []}
  defp believed_calls(tool, ""), do: {:ok, [%{"tool" => tool, "arguments" => %{}}]}

  defp believed_calls(tool, arguments) do
    case Jason.decode(arguments) do
      {:ok, %{} = decoded} ->
        {:ok, [%{"tool" => tool, "arguments" => decoded}]}

      _not_an_object ->
        {:error, %{said: "Write the arguments as a JSON object, like {\"party\": 2}."}}
    end
  end

  defp refusal({:ok, request}), do: {:ok, request}

  defp refusal({:error, :needs_sign_in}) do
    {:error,
     %{
       said:
         "That site needs a signed-in user, and Patchbay never acts on anyone's account. " <>
           "Try what works signed out."
     }}
  end

  defp refusal({:error, {:invalid, [rule | _rest]}}) do
    said =
      case String.split(rule, ":", parts: 2) do
        ["goal" | _] -> "Say what you were trying to do, in up to 1,000 characters."
        ["expected_result" | _] -> "Say what should happen, in up to 1,000 characters."
        ["site_url" | _] -> "The site needs a public https address, like https://example.com/app."
        ["sign_in" | _] -> "Say whether the site needs you signed in."
        _believed_calls -> "The tool name or its arguments could not be read."
      end

    {:error, %{said: said}}
  end
end
