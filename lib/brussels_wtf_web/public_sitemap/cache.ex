defmodule BrusselsWtfWeb.PublicSitemap.Cache do
  @moduledoc """
  Keeps the built sitemap for a few minutes.

  Building runs every public profile gate, which takes seconds on real data, and
  the route is anonymous. Readers queue on this process, so at most one build
  runs at a time. A failed build keeps nothing: an old sitemap is never served
  past its lifetime, because it may list a page withdrawn since.
  """

  use GenServer

  require Logger

  @default_ttl :timer.minutes(5)
  @reader_timeout :timer.seconds(30)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def fetch(cache \\ __MODULE__) do
    GenServer.call(cache, :fetch, @reader_timeout)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       ttl:
         Keyword.get_lazy(opts, :ttl, fn ->
           Application.get_env(:brussels_wtf, :public_sitemap_cache_ttl, @default_ttl)
         end),
       build: Keyword.get(opts, :build, &BrusselsWtfWeb.PublicSitemap.xml/0),
       xml: nil,
       expires_at: nil
     }}
  end

  @impl GenServer
  def handle_call(:fetch, _from, state) do
    if state.xml && now() < state.expires_at do
      {:reply, {:ok, state.xml}, state}
    else
      rebuild(state)
    end
  end

  defp rebuild(state) do
    xml = state.build.()
    {:reply, {:ok, xml}, %{state | xml: xml, expires_at: now() + state.ttl}}
  rescue
    error -> failed(state, error.__struct__)
  catch
    kind, _reason -> failed(state, kind)
  end

  defp failed(state, reason) do
    Logger.error("sitemap build failed: #{inspect(reason)}")
    {:reply, {:error, :unavailable}, %{state | xml: nil, expires_at: nil}}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
