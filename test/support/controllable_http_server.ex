defmodule BrusselsWtf.Test.ControllableHTTPServer do
  @moduledoc false

  defmodule Plug do
    @behaviour Elixir.Plug

    @impl true
    def init(agent), do: agent

    @impl true
    def call(conn, agent) do
      {response, request_number} =
        Agent.get_and_update(agent, fn state ->
          path = conn.request_path
          responses = Map.get(state.responses, path, [%{status: 404, body: "not found"}])
          {response, remaining} = pop_response(responses)
          count = Map.get(state.counts, path, 0) + 1

          request = %{
            path: path,
            number: count,
            headers: Map.new(conn.req_headers)
          }

          {{response, count},
           %{
             state
             | responses: Map.put(state.responses, path, remaining),
               counts: Map.put(state.counts, path, count),
               requests: state.requests ++ [request]
           }}
        end)

      conn =
        Enum.reduce(Map.get(response, :headers, %{}), conn, fn {name, value}, conn ->
          Elixir.Plug.Conn.put_resp_header(conn, to_string(name), to_string(value))
        end)

      if delay = Map.get(response, :delay_ms) do
        Process.sleep(delay)
      end

      body = Map.get(response, :body, "")

      conn
      |> Elixir.Plug.Conn.put_resp_header("x-request-number", Integer.to_string(request_number))
      |> Elixir.Plug.Conn.send_resp(Map.get(response, :status, 200), body)
    end

    defp pop_response([response]), do: {response, [response]}
    defp pop_response([response | remaining]), do: {response, remaining}
  end

  def start do
    {:ok, agent} = Agent.start_link(fn -> %{responses: %{}, counts: %{}, requests: []} end)
    {:ok, bandit} = Bandit.start_link(plug: {Plug, agent}, ip: {127, 0, 0, 1}, port: 0)
    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    %{agent: agent, bandit: bandit, base_url: "http://127.0.0.1:#{port}"}
  end

  def stop(server) do
    if Process.alive?(server.bandit) do
      Process.unlink(server.bandit)
      Process.exit(server.bandit, :shutdown)
    end

    if Process.alive?(server.agent) do
      Process.unlink(server.agent)
      Process.exit(server.agent, :shutdown)
    end

    :ok
  end

  def put(server, path, response), do: put_sequence(server, path, [response])

  def put_sequence(server, path, responses) when is_list(responses) and responses != [] do
    Agent.update(server.agent, fn state ->
      %{state | responses: Map.put(state.responses, path, responses)}
    end)
  end

  def requests(server, path) do
    Agent.get(server.agent, fn state -> Enum.filter(state.requests, &(&1.path == path)) end)
  end
end
