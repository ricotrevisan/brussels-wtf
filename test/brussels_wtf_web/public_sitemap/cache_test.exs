defmodule BrusselsWtfWeb.PublicSitemap.CacheTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias BrusselsWtfWeb.PublicSitemap.Cache

  defp start_cache(build, ttl) do
    name = :"sitemap_cache_#{System.unique_integer([:positive])}"
    start_supervised!({Cache, name: name, ttl: ttl, build: build})
    name
  end

  defp counting_build(result_fun \\ fn number -> "xml-#{number}" end) do
    counter = :counters.new(1, [])

    {counter,
     fn ->
       :counters.add(counter, 1, 1)
       result_fun.(:counters.get(counter, 1))
     end}
  end

  test "concurrent readers within the lifetime share one slow build" do
    {counter, build} =
      counting_build(fn number ->
        Process.sleep(50)
        "xml-#{number}"
      end)

    cache = start_cache(build, :timer.minutes(5))

    results =
      1..8
      |> Enum.map(fn _ -> Task.async(fn -> Cache.fetch(cache) end) end)
      |> Task.await_many()

    assert Enum.uniq(results) == [{:ok, "xml-1"}]
    assert :counters.get(counter, 1) == 1
  end

  test "a sitemap is rebuilt after its lifetime, so withdrawals leave it" do
    {counter, build} = counting_build()
    cache = start_cache(build, 1)

    assert {:ok, "xml-1"} = Cache.fetch(cache)
    Process.sleep(5)
    assert {:ok, "xml-2"} = Cache.fetch(cache)
    assert :counters.get(counter, 1) == 2
  end

  test "a failed build serves nothing, keeps nothing and is retried" do
    {_counter, build} =
      counting_build(fn
        1 -> "xml-first"
        2 -> raise "database unavailable with private detail"
        number -> "xml-#{number}"
      end)

    cache = start_cache(build, 1)
    assert {:ok, "xml-first"} = Cache.fetch(cache)
    Process.sleep(5)

    log =
      capture_log(fn ->
        assert {:error, :unavailable} = Cache.fetch(cache)
      end)

    refute log =~ "private detail"
    assert {:ok, "xml-3"} = Cache.fetch(cache)
  end

  test "a cache that is not running reports unavailable instead of crashing the request" do
    assert {:error, :unavailable} = Cache.fetch(:sitemap_cache_not_running)
  end
end
