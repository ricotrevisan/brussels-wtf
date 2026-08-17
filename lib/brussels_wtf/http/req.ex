defmodule BrusselsWtf.HTTP.Req do
  @moduledoc false
  @behaviour BrusselsWtf.HTTP

  @impl true
  def get(url) do
    case Req.get(url, redirect: true, decode_body: false) do
      {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
        {:ok,
         %{
           status: status,
           headers: headers,
           body: IO.iodata_to_binary(body),
           final_url: url
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
