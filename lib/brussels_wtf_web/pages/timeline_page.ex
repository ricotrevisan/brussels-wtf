defmodule BrusselsWtfWeb.TimelinePage do
  use BrusselsWtfWeb, :dstar_page

  @impl Dstar.Page
  def mount(conn, params) do
    assign(conn,
      page_title: "brussels.wtf",
      html_lang: BrusselsWtfWeb.Locale.resolve(params)
    )
  end

  @impl Dstar.Page
  def render(assigns) do
    ~H"""
    <main class="mx-auto max-w-3xl px-4 py-10 text-base-content">
      <p class="text-sm font-medium tracking-wide uppercase">brussels.wtf</p>
      <h1 class="mt-2 text-3xl font-semibold tracking-tight">Council coverage</h1>
      <p class="mt-3 max-w-prose text-base-content/70">
        Upcoming proposals and documented decisions from Ixelles, Uccle, Forest,
        and the City of Brussels.
      </p>

      <section class="mt-10" aria-labelledby="coming-up">
        <h2 id="coming-up" class="text-xl font-semibold">Coming up</h2>
        <p class="mt-2 text-base-content/70">No upcoming coverage yet.</p>
      </section>

      <section class="mt-8" aria-labelledby="decided">
        <h2 id="decided" class="text-xl font-semibold">What they decided</h2>
        <p class="mt-2 text-base-content/70">No documented decisions yet.</p>
      </section>
    </main>
    """
  end
end
