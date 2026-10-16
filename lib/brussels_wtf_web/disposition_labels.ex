defmodule BrusselsWtfWeb.DispositionLabels do
  @moduledoc "Localized decision disposition labels shared by public pages."

  def label("fr", :approved), do: "approuvée"
  def label("fr", :postponed), do: "reportée"
  def label("fr", :rejected), do: "rejetée"
  def label("fr", :amended), do: "amendée"
  def label("fr", :withdrawn), do: "retirée"
  def label("fr", :other), do: "autre"
  def label("nl", :approved), do: "goedgekeurd"
  def label("nl", :postponed), do: "uitgesteld"
  def label("nl", :rejected), do: "verworpen"
  def label("nl", :amended), do: "gewijzigd"
  def label("nl", :withdrawn), do: "ingetrokken"
  def label("nl", :other), do: "andere"
  def label(_locale, value), do: value |> to_string() |> String.replace("_", " ")
end
