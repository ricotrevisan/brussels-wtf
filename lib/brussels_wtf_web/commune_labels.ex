defmodule BrusselsWtfWeb.CommuneLabels do
  @moduledoc "Localized commune labels shared by public pages."

  def name("fr", "city-of-brussels", _name), do: "Ville de Bruxelles"
  def name("nl", "city-of-brussels", _name), do: "Stad Brussel"
  def name("nl", "ixelles", _name), do: "Elsene"
  def name("nl", "uccle", _name), do: "Ukkel"
  def name("nl", "forest", _name), do: "Vorst"
  def name(_locale, _slug, name), do: name
end
