defmodule Patchbay.Forum.Shots do
  @moduledoc """
  Asks Patchbay's screenshot machine for a picture of a page. That machine
  runs the browser, holds no keys and reaches only public sites; Patchbay
  receives nothing from it but the image.
  """

  @max_bytes 3 * 1024 * 1024

  @doc """
  A WebP picture of the page at `page_url`, or why none came back: the
  error status the page itself answered with (`{:page_status, 403}`), the
  machine's status, `:not_a_picture`, why the call ended (`:timeout`), or the
  exception Req raised.
  """
  @spec take(String.t()) :: {:ok, binary()} | {:error, term()}
  def take(page_url) do
    options =
      [
        url: Application.fetch_env!(:patchbay, :shots_url) <> "/shot",
        json: %{url: page_url},
        receive_timeout: 60_000,
        retry: false,
        decode_body: false,
        # The machine's private address on Fly is IPv6 only.
        connect_options: [transport_opts: [inet6: true]]
      ] ++ Application.get_env(:patchbay, :shots_req_options, [])

    case Req.post(options) do
      {:ok,
       %Req.Response{
         status: 200,
         body: <<"RIFF", _size::binary-size(4), "WEBP", _::binary>> = image
       }}
      when byte_size(image) <= @max_bytes ->
        {:ok, image}

      {:ok, %Req.Response{status: 200}} ->
        {:error, :not_a_picture}

      # The page answered with an error status, so the machine took no picture of it.
      {:ok, %Req.Response{status: 422, body: body}} ->
        %{"page_status" => status} = Jason.decode!(body)
        {:error, {:page_status, status}}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:status, status}}

      # Why the call ended, such as :timeout.
      {:error, %Req.TransportError{reason: reason}} ->
        {:error, reason}

      {:error, exception} ->
        {:error, exception}
    end
  end
end
