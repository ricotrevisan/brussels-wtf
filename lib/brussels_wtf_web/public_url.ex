defmodule BrusselsWtfWeb.PublicUrl do
  @moduledoc """
  Absolute public URLs for search engines.

  The origin comes from endpoint configuration, never from the request's Host
  header. Each language URL is its own canonical; the path without `lang`
  negotiates the language and is the `x-default`.
  """

  @locales ~w(fr nl en)

  def locales, do: @locales

  def meeting_path(commune_slug, municipal_identifier),
    do: "/meetings/#{segment(commune_slug)}/#{segment(municipal_identifier)}"

  def dossier_path(slug), do: "/dossiers/#{segment(slug)}"
  def person_path(id), do: "/people/#{segment(id)}"
  def company_path(enterprise_number), do: "/companies/#{segment(enterprise_number)}"

  def absolute(path), do: BrusselsWtfWeb.Endpoint.url() <> path
  def localized(path, locale) when locale in @locales, do: absolute(path) <> "?lang=" <> locale

  @doc "Every `{hreflang, url}` alternate of a resource, including its `x-default`."
  def alternates(path) do
    Enum.map(@locales, &{&1, localized(path, &1)}) ++ [{"x-default", absolute(path)}]
  end

  defp segment(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)
end
