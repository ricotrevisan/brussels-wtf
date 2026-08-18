defmodule BrusselsWtf.Review.Preparations.FilterInbox do
  @moduledoc false
  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    query
    |> filter_kind()
    |> filter_commune()
    |> filter_status()
    |> filter_generation()
    |> filter_age()
    |> Ash.Query.sort(urgency: :desc, inserted_at: :asc)
  end

  defp filter_kind(query) do
    case Ash.Query.get_argument(query, :kind) do
      nil -> query
      value -> Ash.Query.filter(query, kind == ^value)
    end
  end

  defp filter_commune(query) do
    case Ash.Query.get_argument(query, :commune_id) do
      nil -> query
      value -> Ash.Query.filter(query, commune_id == ^value)
    end
  end

  defp filter_status(query) do
    case Ash.Query.get_argument(query, :status) do
      nil -> query
      value -> Ash.Query.filter(query, status == ^value)
    end
  end

  defp filter_generation(query) do
    case Ash.Query.get_argument(query, :generation) do
      nil -> query
      value -> Ash.Query.filter(query, processing_generation == ^value)
    end
  end

  defp filter_age(query) do
    case Ash.Query.get_argument(query, :age_days) do
      nil ->
        query

      days ->
        oldest = DateTime.add(BrusselsWtf.Clock.utc_now(), -days * 86_400, :second)
        Ash.Query.filter(query, inserted_at >= ^oldest)
    end
  end
end
