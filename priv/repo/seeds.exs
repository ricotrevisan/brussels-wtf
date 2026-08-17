# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Index URLs here are local placeholders. Authoritative locators are discovered
# by commune adapters from live municipal indexes.

alias BrusselsWtf.Ingestion

Enum.each(
  [
    %{slug: "ixelles", name: "Ixelles", index_url: "https://fixtures.test/ixelles"},
    %{slug: "uccle", name: "Uccle", index_url: "https://fixtures.test/uccle"},
    %{slug: "forest", name: "Forest", index_url: "https://fixtures.test/forest"},
    %{
      slug: "city-of-brussels",
      name: "City of Brussels",
      index_url: "https://fixtures.test/city-of-brussels"
    }
  ],
  &Ingestion.create_commune!/1
)

# Development-only, visibly synthetic public interface records.
BrusselsWtf.Seeds.PublicTimeline.run!()
