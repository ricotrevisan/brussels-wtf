defmodule BrusselsWtf.CBE.RuntimeTest do
  use ExUnit.Case, async: true

  alias BrusselsWtf.CBE.{Indexed, OpenData, Runtime, Unconfigured}

  @sha String.duplicate("aB", 32)

  test "absent configuration preserves CSV default and unconfigured enrichment" do
    for env <- [
          %{},
          %{"CBE_LOOKUP_MODE" => "csv"},
          %{"CBE_OPEN_DATA_DIRECTORY" => "", "CBE_OPEN_DATA_SHA256" => ""}
        ] do
      assert Runtime.load(env) == %{source: Unconfigured, source_config: []}
    end
  end

  test "CSV selection requires a directory and digest together, without reading either" do
    for mode <- [nil, "csv"] do
      assert Runtime.load(%{
               "CBE_LOOKUP_MODE" => mode,
               "CBE_OPEN_DATA_DIRECTORY" => "/not-mounted/private",
               "CBE_OPEN_DATA_SHA256" => @sha
             }) == %{
               source: OpenData,
               source_config: [
                 directory: "/not-mounted/private",
                 release_sha256: String.downcase(@sha)
               ]
             }
    end

    for env <- [
          %{"CBE_OPEN_DATA_DIRECTORY" => "/private"},
          %{"CBE_OPEN_DATA_SHA256" => @sha},
          %{"CBE_OPEN_DATA_DIRECTORY" => "", "CBE_OPEN_DATA_SHA256" => @sha},
          %{"CBE_OPEN_DATA_DIRECTORY" => "/private", "CBE_OPEN_DATA_SHA256" => ""}
        ] do
      assert_raise ArgumentError,
                   "CBE Open Data requires both CBE_OPEN_DATA_DIRECTORY and CBE_OPEN_DATA_SHA256",
                   fn -> Runtime.load(env) end
    end
  end

  test "indexed selects an exact normalized digest independently of readiness or directory" do
    for directory <- [nil, "", "/not-mounted/private"] do
      assert Runtime.load(%{
               "CBE_LOOKUP_MODE" => "indexed",
               "CBE_OPEN_DATA_DIRECTORY" => directory,
               "CBE_OPEN_DATA_SHA256" => @sha
             }) == %{source: Indexed, source_config: [release_sha256: String.downcase(@sha)]}
    end
  end

  test "missing or malformed indexed digests and malformed CSV digests fail safely" do
    for sha <- [
          nil,
          "",
          "secret-not-a-digest",
          String.duplicate("a", 63),
          String.duplicate("a", 65),
          String.duplicate("g", 64),
          @sha <> "\n",
          " " <> @sha
        ] do
      assert_raise ArgumentError,
                   "CBE_OPEN_DATA_SHA256 must be a 64-character SHA-256 digest",
                   fn ->
                     Runtime.load(%{
                       "CBE_LOOKUP_MODE" => "indexed",
                       "CBE_OPEN_DATA_SHA256" => sha
                     })
                   end

      if sha not in [nil, ""] do
        assert_raise ArgumentError,
                     "CBE_OPEN_DATA_SHA256 must be a 64-character SHA-256 digest",
                     fn ->
                       Runtime.load(%{
                         "CBE_OPEN_DATA_DIRECTORY" => "/private",
                         "CBE_OPEN_DATA_SHA256" => sha
                       })
                     end
      end
    end
  end

  test "unknown and empty modes are rejected without echoing the input" do
    for mode <- ["", "CSV", "Indexed", "auto", "secret-mode"] do
      assert_raise ArgumentError, "CBE_LOOKUP_MODE must be csv or indexed", fn ->
        Runtime.load(%{"CBE_LOOKUP_MODE" => mode})
      end
    end
  end
end
