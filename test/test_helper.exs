{:ok, _} = BrusselsWtf.Clock.Controlled.start_link()
{:ok, _} = BrusselsWtf.HTTP.Stub.start_link()
{:ok, _} = BrusselsWtf.Processors.Stub.start_link()
{:ok, _} = BrusselsWtf.CBE.Stub.start_link()

ExUnit.start(exclude: [:external, :browser])
Ecto.Adapters.SQL.Sandbox.mode(BrusselsWtf.Repo, :manual)
