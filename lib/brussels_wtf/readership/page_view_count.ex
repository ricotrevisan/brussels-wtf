defmodule BrusselsWtf.Readership.PageViewCount do
  @moduledoc """
  One daily total. The bucket is its own primary key: timestamps or a
  time-ordered id would retain more than the calendar day of a visit.
  """

  use Ash.Resource,
    otp_app: :brussels_wtf,
    domain: BrusselsWtf.Readership,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "page_view_daily_counts"
    repo BrusselsWtf.Repo
  end

  actions do
    create :add do
      accept [:day, :route_pattern, :locale, :referrer_host, :count]
      upsert? true
      upsert_fields []
      change atomic_update(:count, expr(count + upsert_conflict(:count)))
    end

    read :referrer_hosts_on_day do
      argument :day, :date, allow_nil?: false
      filter expr(day == ^arg(:day))
    end

    read :since do
      argument :first_day, :date, allow_nil?: false
      filter expr(day >= ^arg(:first_day))
      prepare build(sort: [day: :desc])
    end
  end

  policies do
    policy action_type(:read) do
      access_type :strict
      authorize_if actor_attribute_equals(:role, :reviewer)
    end
  end

  attributes do
    attribute :day, :date, primary_key?: true, allow_nil?: false, public?: true
    attribute :route_pattern, :string, primary_key?: true, allow_nil?: false, public?: true

    attribute :locale, :string do
      primary_key? true
      allow_nil? false
      public? true
      constraints match: ~r/\A(fr|nl|en)\z/
    end

    attribute :referrer_host, :string do
      primary_key? true
      allow_nil? false
      public? true
      constraints max_length: 253
    end

    attribute :count, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end
  end
end
