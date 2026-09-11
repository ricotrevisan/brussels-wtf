defmodule BrusselsWtfWeb.PublicStaticTest do
  use BrusselsWtfWeb.ConnCase, async: false

  test "rendered favicon links serve the real digested assets", %{conn: conn} do
    static_dir = Application.app_dir(:brussels_wtf, "priv/static")
    fixture_name = "static-test-#{System.unique_integer([:positive])}"
    fixture_dir = Application.app_dir(:brussels_wtf, fixture_name)
    input_dir = Path.join(fixture_dir, "input")
    output_dir = Path.join(fixture_dir, "output")

    config =
      Application.fetch_env!(:brussels_wtf, @endpoint)
      |> Keyword.put(:cache_static_manifest, @endpoint.config(:cache_static_manifest))

    on_exit(fn ->
      @endpoint.config_change([{@endpoint, config}], [])
      File.rm_rf!(fixture_dir)
    end)

    for path <- ["favicon.ico", "images/brand/favicon.svg"] do
      target = Path.join(input_dir, path)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(Path.join(static_dir, path), target)
    end

    unlisted_file = "#{fixture_name}.txt"
    File.write!(Path.join(input_dir, unlisted_file), "This root asset is not allowlisted.")

    Mix.Task.run("phx.digest", [input_dir, "-o", output_dir, "--no-compile"])
    manifest = output_dir |> Path.join("cache_manifest.json") |> File.read!() |> Jason.decode!()

    for digested <- Map.values(manifest["latest"]) do
      target = Path.join(static_dir, digested)

      unless File.exists?(target) do
        on_exit(fn -> File.rm!(target) end)
        File.cp!(Path.join(output_dir, digested), target)
      end
    end

    @endpoint.config_change(
      [
        {@endpoint,
         Keyword.put(config, :cache_static_manifest, "#{fixture_name}/output/cache_manifest.json")}
      ],
      []
    )

    document = conn |> get("/?lang=en") |> html_response(200) |> LazyHTML.from_document()
    icon_links = document[~s(link[rel="icon"])] |> LazyHTML.attribute("href")
    assert length(icon_links) == 2

    for {extension, content_type, original} <- [
          {"ico", "image/vnd.microsoft.icon", "favicon.ico"},
          {"svg", "image/svg+xml", "images/brand/favicon.svg"}
        ] do
      href = Enum.find(icon_links, &String.ends_with?(&1, ".#{extension}?vsn=d"))
      assert href =~ ~r/favicon-[a-f0-9]{32}\./
      asset = get(build_conn(), href)
      assert response(asset, 200) == File.read!(Path.join(static_dir, original))
      assert get_resp_header(asset, "content-type") == [content_type]
    end

    assert conn |> get("/favicon.ico") |> response(200) ==
             File.read!(Path.join(static_dir, "favicon.ico"))

    assert conn
           |> get("/#{manifest["latest"][unlisted_file]}?vsn=d")
           |> response(404) == "Not Found"
  end
end
