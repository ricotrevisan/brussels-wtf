defmodule BrusselsWtf.PDF.QualityCalibrationTest do
  use ExUnit.Case, async: true

  @manifest Path.expand("../../support/pdf_calibration/manifest.json", __DIR__)

  test "production thresholds are versioned against all four commune profiles" do
    manifest = @manifest |> File.read!() |> Jason.decode!()
    communes = manifest["fixtures"] |> Enum.map(& &1["commune"]) |> MapSet.new()

    assert MapSet.subset?(
             MapSet.new(["ixelles", "uccle", "forest", "city-of-brussels"]),
             communes
           )

    calibrated =
      manifest["calibration"]["thresholds"]
      |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)

    assert BrusselsWtf.PDF.Quality.thresholds() == calibrated
    assert manifest["licensing_disposition"] =~ "municipal administrative documents"

    assert Enum.all?(
             manifest["fixtures"],
             &String.starts_with?(&1["official_origin"], "https://")
           )
  end

  test "one poor page rejects a partially readable document" do
    readable =
      "Conseil communal Gemeenteraad proposition officielle openbaar besluit avec suffisamment de texte"

    result = BrusselsWtf.PDF.Quality.assess([readable, "", readable])
    refute result["accepted"]
    assert result["rejected_pages"] == [2]
    assert Enum.at(result["pages"], 0)["decision"] == "accepted"

    assert Enum.at(result["pages"], 1)["reasons"] == [
             "too_few_characters",
             "too_few_words",
             "low_alphanumeric_ratio"
           ]
  end
end
