defmodule BrusselsWtfWeb.Locale do
  @moduledoc """
  Skeletal locale resolution: explicit valid `lang`, otherwise English.

  Ticket #15 adds persisted reader choice and Accept-Language.
  """

  @public_locales ~w(fr nl en)

  @spec resolve(map()) :: String.t()
  def resolve(params) when is_map(params) do
    params
    |> Map.get("lang")
    |> normalize()
    |> case do
      locale when locale in @public_locales -> locale
      _ -> "en"
    end
  end

  defp normalize(nil), do: nil
  defp normalize(lang) when lang in @public_locales, do: lang
  defp normalize("fr-be"), do: "fr"
  defp normalize("fr-FR"), do: "fr"
  defp normalize("nl-be"), do: "nl"
  defp normalize("nl-NL"), do: "nl"
  defp normalize("en-gb"), do: "en"
  defp normalize("en-us"), do: "en"
  defp normalize(lang) when is_binary(lang), do: String.downcase(lang)
  defp normalize(_), do: nil
end
