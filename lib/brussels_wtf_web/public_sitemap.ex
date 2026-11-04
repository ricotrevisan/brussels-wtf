defmodule BrusselsWtfWeb.PublicSitemap do
  @moduledoc """
  Builds `sitemap.xml` from the same gates the public pages use.

  A resource is listed only when its page would publicly render in French,
  Dutch and English. Candidates that fail a gate are omitted, never guessed.
  """

  alias BrusselsWtf.{Council, Identity}
  alias BrusselsWtfWeb.PublicUrl

  @static_paths ~w(
    /
    /about
    /coverage
    /coverage/coming-up
    /coverage/awaiting-outcome
    /coverage/decisions
    /coverage/contested-votes
    /mandates
  )

  def xml do
    urls =
      (Enum.map(@static_paths, &{&1, nil}) ++ meetings() ++ dossiers() ++ profiles())
      |> Enum.flat_map(&urls/1)

    [
      ~s(<?xml version="1.0" encoding="UTF-8"?>\n),
      ~s(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">\n),
      urls,
      "</urlset>\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp meetings do
    Council.list_indexable_meeting_pages!()
    |> Enum.filter(&all_locales?/1)
    |> Enum.map(fn page ->
      meeting = page.council_meeting

      {PublicUrl.meeting_path(meeting.commune.slug, meeting.municipal_identifier),
       page.revision_published_at}
    end)
    |> Enum.sort()
  end

  defp all_locales?(page) do
    Enum.all?(PublicUrl.locales(), fn locale ->
      Enum.any?(page.locale_variants, &(&1.locale == locale))
    end)
  end

  defp dossiers do
    Council.list_dossier_slug_candidates!()
    |> Enum.flat_map(fn %{slug: slug} ->
      case Council.get_dossier(slug) do
        {:ok, dossier} ->
          if BrusselsWtfWeb.DossierPage.indexable?(dossier),
            do: [{PublicUrl.dossier_path(slug), nil}],
            else: []

        {:error, _} ->
          []
      end
    end)
    |> Enum.sort()
  end

  defp profiles do
    Identity.list_public_profile_refs!()
    |> Enum.map(fn
      {:person, id} -> {PublicUrl.person_path(id), nil}
      {:company, number} -> {PublicUrl.company_path(number), nil}
    end)
    |> Enum.sort()
  end

  defp urls({path, last_modified}) do
    alternates =
      for {hreflang, href} <- PublicUrl.alternates(path) do
        [
          ~s(<xhtml:link rel="alternate" hreflang="),
          hreflang,
          ~s(" href="),
          escape(href),
          ~s("/>)
        ]
      end

    for locale <- PublicUrl.locales() do
      [
        "<url><loc>",
        escape(PublicUrl.localized(path, locale)),
        "</loc>",
        last_modified(last_modified),
        alternates,
        "</url>\n"
      ]
    end
  end

  defp last_modified(nil), do: []

  defp last_modified(%DateTime{} = value) do
    ["<lastmod>", value |> DateTime.truncate(:second) |> DateTime.to_iso8601(), "</lastmod>"]
  end

  defp escape(value), do: value |> Plug.HTML.html_escape_to_iodata() |> IO.iodata_to_binary()
end
