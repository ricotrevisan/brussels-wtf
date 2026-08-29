defmodule BrusselsWtfWeb.SuggestionClientAddress do
  @moduledoc false

  import Plug.Conn, only: [get_req_header: 2]

  def get(conn) do
    {:ok, peer} = BrusselsWtf.Suggestions.canonical_client_address(conn.remote_ip)
    trusted = trusted_proxies()

    if MapSet.member?(trusted, peer) do
      forwarded_client(conn, peer, trusted)
    else
      peer
    end
  end

  defp forwarded_client(conn, peer, trusted) do
    case get_req_header(conn, "x-forwarded-for") do
      [header] ->
        with {:ok, addresses} <- parse_chain(header),
             client when is_binary(client) <- first_untrusted(addresses ++ [peer], trusted) do
          client
        else
          _ -> peer
        end

      _ ->
        peer
    end
  end

  defp parse_chain(header) do
    header
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, addresses} ->
      case BrusselsWtf.Suggestions.canonical_client_address(value) do
        {:ok, address} -> {:cont, {:ok, addresses ++ [address]}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, []} -> :error
      result -> result
    end
  end

  defp first_untrusted(chain, trusted) do
    chain
    |> Enum.reverse()
    |> Enum.drop_while(&MapSet.member?(trusted, &1))
    |> List.first()
  end

  defp trusted_proxies do
    :brussels_wtf
    |> Application.fetch_env!(:suggestions)
    |> Keyword.fetch!(:trusted_proxies)
    |> Enum.reduce(MapSet.new(), fn value, trusted ->
      case BrusselsWtf.Suggestions.canonical_client_address(value) do
        {:ok, address} -> MapSet.put(trusted, address)
        _ -> trusted
      end
    end)
  end
end
