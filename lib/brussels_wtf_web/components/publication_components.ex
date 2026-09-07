defmodule BrusselsWtfWeb.PublicationComponents do
  use Phoenix.Component

  attr :locale, :string, required: true

  def footer(assigns) do
    ~H"""
    <footer class="mt-10 border-t border-base-300 pt-4 text-sm">
      <a href={"/coverage?lang=#{@locale}"} class="underline">{copy(@locale, :coverage)}</a>
      <span class="mx-2">·</span>
      <a href={"/about?lang=#{@locale}"} class="underline">{copy(@locale, :about)}</a>
    </footer>
    """
  end

  attr :locale, :string, required: true
  attr :item_id, :string, required: true

  def correction_form(assigns) do
    ~H"""
    <details :if={BrusselsWtf.Suggestions.enabled?()} class="mt-5 text-sm">
      <summary class="cursor-pointer underline">{copy(@locale, :correct)}</summary>
      <p class="mt-2">{copy(@locale, :private)}</p>
      <form
        method="post"
        action={"/items/#{@item_id}/suggestions/correction?lang=#{@locale}"}
        class="mt-3 space-y-3"
      >
        <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
        <label class="block">
          {copy(@locale, :body)}
          <textarea
            name="body"
            required
            minlength="10"
            maxlength="10000"
            rows="4"
            class="textarea textarea-bordered mt-1 w-full"
          ></textarea>
        </label>
        <label class="block">
          {copy(@locale, :contact)}
          <input name="contact" maxlength="500" class="input input-bordered mt-1 w-full" />
        </label>
        <label class="sr-only" aria-hidden="true">Website<input
          name="website"
          tabindex="-1"
          autocomplete="off"
        /></label>
        <button class="btn btn-sm" type="submit">{copy(@locale, :send)}</button>
      </form>
    </details>
    """
  end

  defp copy(locale, key) do
    %{
      "en" => %{
        coverage: "Coverage and source checks",
        about: "About and corrections",
        correct: "Report an error in this item",
        private:
          "Your report goes privately to editorial review. It does not change the published page automatically. Contact details are optional and never published.",
        body: "What should we check? Include a source or page reference if possible.",
        contact: "Contact details (optional)",
        send: "Send private correction"
      },
      "fr" => %{
        coverage: "Couverture et vérification des sources",
        about: "À propos et corrections",
        correct: "Signaler une erreur dans ce point",
        private:
          "Votre signalement est transmis à la rédaction en privé. Il ne modifie pas automatiquement la page publiée. Vos coordonnées sont facultatives et ne sont jamais publiées.",
        body: "Que devons-nous vérifier ? Indiquez si possible une source ou une page.",
        contact: "Coordonnées (facultatives)",
        send: "Envoyer la correction en privé"
      },
      "nl" => %{
        coverage: "Dekking en broncontroles",
        about: "Over de site en correcties",
        correct: "Een fout in dit punt melden",
        private:
          "Uw melding gaat privé naar de redactie. Ze wijzigt de gepubliceerde pagina niet automatisch. Contactgegevens zijn optioneel en worden nooit gepubliceerd.",
        body: "Wat moeten we controleren? Vermeld indien mogelijk een bron of paginanummer.",
        contact: "Contactgegevens (optioneel)",
        send: "Privécorrectie versturen"
      }
    }[locale][key]
  end
end
