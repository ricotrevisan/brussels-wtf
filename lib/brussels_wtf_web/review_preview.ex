defmodule BrusselsWtfWeb.ReviewPreview do
  @moduledoc "Creates short-lived, application-mediated private artifact access tokens."

  @salt "review-artifact-preview"

  def sign_source_version(id), do: sign("source-version", id)
  def sign_derived_artifact(id), do: sign("derived-artifact", id)

  def verify(token, kind, id) when is_binary(token) do
    case Phoenix.Token.verify(BrusselsWtfWeb.Endpoint, @salt, token, max_age: 60) do
      {:ok, %{kind: ^kind, id: ^id}} -> :ok
      _ -> {:error, :invalid}
    end
  end

  def verify(_token, _kind, _id), do: {:error, :invalid}

  defp sign(kind, id) do
    Phoenix.Token.sign(BrusselsWtfWeb.Endpoint, @salt, %{kind: kind, id: id})
  end
end
