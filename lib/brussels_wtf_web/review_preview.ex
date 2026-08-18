defmodule BrusselsWtfWeb.ReviewPreview do
  @moduledoc "Creates short-lived, application-mediated private artifact access tokens."

  @salt "review-artifact-preview"

  def sign(source_version_id) do
    Phoenix.Token.sign(BrusselsWtfWeb.Endpoint, @salt, source_version_id)
  end

  def verify(token) when is_binary(token) do
    Phoenix.Token.verify(BrusselsWtfWeb.Endpoint, @salt, token, max_age: 60)
  end

  def verify(_), do: {:error, :invalid}
end
