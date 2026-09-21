defmodule BrusselsWtfWeb.PublicMandate do
  @moduledoc false
  use BrusselsWtfWeb, :html

  attr :relationship, :map, required: true
  attr :locale, :string, required: true

  def installation_period(assigns) do
    ~H"""
    <p class="mt-2 text-sm text-base-content/70">
      {installation_text(@locale, @relationship)}
    </p>
    """
  end

  def role_label(locale, %{role_labels: labels}) when is_map(labels),
    do: Map.fetch!(labels, locale)

  def role_label(locale, %{mandate_declaration: %{"role_labels" => labels}}),
    do: Map.fetch!(labels, locale)

  defp installation_text(locale, relationship) do
    Gettext.with_locale(BrusselsWtfWeb.Gettext, locale, fn ->
      if relationship.effective_to do
        gettext("Installation documented on %{date}; end date: %{end_date}",
          date: Date.to_iso8601(relationship.effective_from),
          end_date: Date.to_iso8601(relationship.effective_to)
        )
      else
        gettext("Installation documented on %{date}; end date not established",
          date: Date.to_iso8601(relationship.effective_from)
        )
      end
    end)
  end
end
