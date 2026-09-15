defmodule BrusselsWtf.TED.AwardNotice do
  @moduledoc """
  Bounded eForms result extraction for one explicitly selected lot.

  This is evidence extraction, not verification or permission to publish. It
  retains raw organization identifiers; CBE resolution and the authentic signed
  PDF/correction-chain checks are separate mandatory gates.
  """

  @namespaces %{
    root: "urn:oasis:names:specification:ubl:schema:xsd:ContractAwardNotice-2",
    cbc: "urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2",
    cac: "urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2",
    ext: "urn:oasis:names:specification:ubl:schema:xsd:CommonExtensionComponents-2",
    efext: "http://data.europa.eu/p27/eforms-ubl-extensions/1",
    efac: "http://data.europa.eu/p27/eforms-ubl-extension-aggregate-components/1",
    efbc: "http://data.europa.eu/p27/eforms-ubl-extension-basic-components/1"
  }
  @max_bytes 4 * 1_024 * 1_024

  def parse(xml, lot_id) when is_binary(xml) and is_binary(lot_id) do
    with true <- byte_size(xml) <= @max_bytes and String.valid?(xml),
         :nomatch <- :binary.match(xml, <<0>>),
         false <- String.contains?(xml, ["<!DOCTYPE", "<!ENTITY"]),
         true <- Regex.match?(~r/\ALOT-[0-9]{4}\z/, lot_id),
         {:ok, root, rest} <-
           :xmerl_sax_parser.stream(xml,
             event_fun: &event/3,
             event_state: %{stack: [], root: nil, count: 0}
           ),
         true <- String.trim(rest) == "" do
      {:ok, extract(root.root, lot_id)}
    else
      _ -> {:error, :invalid_or_unsupported_notice}
    end
  rescue
    _ -> {:error, :invalid_or_ambiguous_notice}
  catch
    {:invalid_notice, reason} -> {:error, reason}
  end

  def parse(_, _), do: {:error, :invalid_or_unsupported_notice}

  defp extract(root, lot_id) do
    require!(root.name == {@namespaces.root, "ContractAwardNotice"}, :not_result_notice)
    children(root, :cac, "ProcurementProjectLot") |> matching(&(id(&1) == lot_id))
    type = one(root, :cbc, "NoticeTypeCode")

    require!(
      type.text == "can-standard" and type.attrs["listName"] == "result",
      :not_result_notice
    )

    extension =
      path(root,
        ext: "UBLExtensions",
        ext: "UBLExtension",
        ext: "ExtensionContent",
        efext: "EformsExtension"
      )

    publication = one(extension, :efac, "Publication")
    result = one(extension, :efac, "NoticeResult")

    lot =
      children(result, :efac, "LotResult")
      |> matching(fn n -> id(one(n, :efac, "TenderLot")) == lot_id end)

    buyer_id =
      path(root, cac: "ContractingParty", cac: "Party", cac: "PartyIdentification") |> id()

    buyer = organization(extension, buyer_id)
    status = value(lot, :cbc, "TenderResultCode")

    notice = %{
      notice_id: uuid!(value(root, :cbc, "ID")),
      version: version!(value(root, :cbc, "VersionID")),
      publication_number: publication_number!(value(publication, :efbc, "NoticePublicationID")),
      published_on: date!(value(publication, :efbc, "PublicationDate")),
      procedure_id: uuid!(value(root, :cbc, "ContractFolderID")),
      correction_of: correction(extension),
      lot_id: lot_id,
      result_id: id(lot),
      buyer: buyer
    }

    case status do
      "selec-w" -> award(notice, lot, result, extension)
      status when status in ["open-nw", "clos-nw"] -> Map.put(notice, :status, :not_awarded)
      _ -> invalid!(:unsupported_result_status)
    end
  end

  defp award(notice, lot, result, extension) do
    require!(children(lot, :efac, "DecisionReason") == [], :conflicting_non_award_reason)
    require!(not withheld?(lot), :withheld_result)
    tender_id = id(one(lot, :efac, "LotTender"))
    contract_id = id(one(lot, :efac, "SettledContract"))
    tender = children(result, :efac, "LotTender") |> matching(&(id(&1) == tender_id))
    contract = children(result, :efac, "SettledContract") |> matching(&(id(&1) == contract_id))
    require!(not withheld?(tender) and not withheld?(contract), :withheld_award)
    require!(id(one(tender, :efac, "TenderLot")) == notice.lot_id, :mismatched_lot)
    require!(id(one(contract, :efac, "LotTender")) == tender_id, :mismatched_contract)
    party_id = id(one(tender, :efac, "TenderingParty"))
    party = children(result, :efac, "TenderingParty") |> matching(&(id(&1) == party_id))
    winner = organization(extension, id(one(party, :efac, "Tenderer")))
    require!(winner.id != notice.buyer.id, :buyer_is_winner)
    money = path(tender, cac: "LegalMonetaryTotal", cbc: "PayableAmount")
    require!(money.attrs["currencyID"] == "EUR", :unsupported_currency)
    require!(Regex.match?(~r/\A[0-9]{1,15}(?:\.[0-9]{1,2})?\z/, money.text), :invalid_value)
    amount = Decimal.new(money.text)
    require!(Decimal.positive?(amount), :invalid_value)
    concluded_on = date!(value(contract, :cbc, "IssueDate"))
    require!(Date.compare(concluded_on, notice.published_on) != :gt, :future_contract)

    Map.merge(notice, %{
      status: :awarded,
      tender_id: tender_id,
      contract_id: contract_id,
      winner: winner,
      concluded_on: concluded_on,
      amount: Decimal.to_string(amount, :normal),
      currency: "EUR",
      value_basis: "winning_tender_payable_amount_bt720"
    })
  end

  defp organization(extension, identifier) do
    require!(Regex.match?(~r/\AORG-[0-9]{4}\z/, identifier), :invalid_organization_reference)

    company =
      extension
      |> one(:efac, "Organizations")
      |> children(:efac, "Organization")
      |> Enum.map(&one(&1, :efac, "Company"))
      |> matching(&(id(one(&1, :cac, "PartyIdentification")) == identifier))

    require!(not withheld?(company), :withheld_organization)
    country = path(company, cac: "PostalAddress", cac: "Country", cbc: "IdentificationCode").text
    require!(country == "BEL", :unsupported_country)
    raw_identifier = path(company, cac: "PartyLegalEntity", cbc: "CompanyID").text
    names = Enum.map(children(company, :cac, "PartyName"), &one(&1, :cbc, "Name"))
    require!(names != [] and Enum.all?(names, &(&1.text != "")), :missing_organization_identity)
    languages = Enum.map(names, & &1.attrs["languageID"])
    require!(length(Enum.uniq(languages)) == length(languages), :ambiguous_organization_name)
    require!(raw_identifier != "", :missing_organization_identity)

    %{
      id: identifier,
      raw_identifier: raw_identifier,
      names: Map.new(names, &{&1.attrs["languageID"] || "und", &1.text}),
      country: country
    }
  end

  defp correction(extension) do
    case children(extension, :efac, "Changes") do
      [] ->
        nil

      [change] ->
        identifier = value(change, :efbc, "ChangedNoticeIdentifier")
        require!(Regex.match?(~r/\A[0-9a-f-]{36}-[0-9]{2}\z/, identifier), :invalid_correction)
        uuid!(String.slice(identifier, 0, 36))
        identifier

      _ ->
        invalid!(:ambiguous_correction)
    end
  end

  defp uuid!(value) do
    require!(match?({:ok, _}, Ecto.UUID.cast(value)), :invalid_notice_id)
    value
  end

  defp version!(value) do
    require!(Regex.match?(~r/\A[0-9]{2}\z/, value) and value != "00", :invalid_notice_version)
    value
  end

  defp publication_number!(value) do
    case Regex.run(~r/\A([0-9]{1,10})-([0-9]{4})\z/, value) do
      [_, number, year] -> "#{String.to_integer(number)}-#{year}"
      _ -> invalid!(:invalid_publication_number)
    end
  end

  defp date!(value) do
    require!(
      Regex.match?(
        ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}(?:Z|[+-](?:(?:0[0-9]|1[0-3]):[0-5][0-9]|14:00))?\z/,
        value
      ),
      :invalid_date
    )

    case Date.from_iso8601(String.slice(value, 0, 10)) do
      {:ok, date} -> date
      _ -> invalid!(:invalid_date)
    end
  end

  defp value(node, namespace, name), do: one(node, namespace, name).text
  defp id(node), do: value(node, :cbc, "ID")
  defp path(node, []), do: node
  defp path(node, [{namespace, name} | rest]), do: path(one(node, namespace, name), rest)

  defp one(node, namespace, name) do
    case children(node, namespace, name) do
      [child] -> child
      _ -> invalid!({:missing_or_ambiguous_element, namespace, name})
    end
  end

  defp children(node, namespace, name),
    do: Enum.filter(node.children, &(&1.name == {Map.fetch!(@namespaces, namespace), name}))

  defp matching(nodes, predicate) do
    case Enum.filter(nodes, predicate) do
      [node] -> node
      _ -> invalid!(:missing_or_ambiguous_reference)
    end
  end

  defp withheld?(node),
    do: node.name == {@namespaces.efac, "FieldsPrivacy"} or Enum.any?(node.children, &withheld?/1)

  defp require!(true, _), do: :ok
  defp require!(_, reason), do: invalid!(reason)
  defp invalid!(reason), do: throw({:invalid_notice, reason})

  # SAX keeps XML names as strings rather than creating atoms from remote input.
  defp event({:startElement, uri, name, _, attrs}, _, state) do
    require!(state.count < 10_000 and length(state.stack) < 40, :xml_structure_limit)

    attrs =
      attrs
      |> Enum.filter(fn {uri, _, _, _} -> to_string(uri) == "" end)
      |> Map.new(fn {_, _, key, value} -> {to_string(key), to_string(value)} end)

    node = %{name: {to_string(uri), to_string(name)}, attrs: attrs, children: [], text: []}
    %{state | stack: [node | state.stack], count: state.count + 1}
  end

  defp event({:characters, chars}, _, %{stack: [node | rest]} = state),
    do: %{state | stack: [%{node | text: [to_string(chars) | node.text]} | rest]}

  defp event({:endElement, _, _, _}, _, %{stack: [node | rest]} = state) do
    node = %{
      node
      | text: node.text |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim(),
        children: Enum.reverse(node.children)
    }

    case rest do
      [] -> %{state | stack: [], root: node}
      [parent | rest] -> %{state | stack: [%{parent | children: [node | parent.children]} | rest]}
    end
  end

  defp event(_, _, state), do: state
end
