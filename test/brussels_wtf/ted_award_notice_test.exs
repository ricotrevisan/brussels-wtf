defmodule BrusselsWtf.TED.AwardNoticeTest do
  use ExUnit.Case, async: true
  alias BrusselsWtf.TED.AwardNotice

  test "selects linked tender value and conclusion date, never aggregate, framework or placeholder date" do
    assert {:ok, award} = AwardNotice.parse(xml(), "LOT-0002")
    assert award.amount == "54192.04"
    assert award.value_basis == "winning_tender_payable_amount_bt720"
    assert award.concluded_on == ~D[2026-03-05]
    assert award.published_on == ~D[2026-03-16]
    assert award.publication_number == "181194-2026"
    assert award.winner.raw_identifier == "0844814966_suffix-is-unresolved"
    refute Map.has_key?(award.winner, :enterprise_number)
    refute inspect(award) =~ "PRIVATE ADDRESS"
  end

  test "a no-winner result supplies no winner, value or contract claim" do
    assert {:ok, %{status: :not_awarded} = result} =
             AwardNotice.parse(String.replace(xml(), "selec-w", "open-nw"), "LOT-0002")

    refute Map.has_key?(result, :winner)
    refute Map.has_key?(result, :amount)
    refute Map.has_key?(result, :concluded_on)
  end

  test "malformed, conflicting and withheld fields fail closed" do
    for {old, new} <- [
          {"listName=\"result\"", "listName=\"competition\""},
          {"<cbc:PayableAmount currencyID=\"EUR\">54192.04</cbc:PayableAmount>", ""},
          {"54192.04", "not-an-amount"},
          {"currencyID=\"EUR\">54192", "currencyID=\"USD\">54192"},
          {"2026-03-05", "2027-03-05"},
          {"<cac:ProcurementProjectLot><cbc:ID>LOT-0002</cbc:ID></cac:ProcurementProjectLot>",
           ""},
          {"currencyID=\"EUR\">54192", "cbc:currencyID=\"EUR\">54192"},
          {"<efac:LotTender><cbc:ID>TEN-0002</cbc:ID></efac:LotTender>",
           "<efac:LotTender><cbc:ID>TEN-9999</cbc:ID></efac:LotTender>"},
          {"<cbc:TenderResultCode>selec-w</cbc:TenderResultCode>",
           "<cbc:TenderResultCode>selec-w</cbc:TenderResultCode><efac:DecisionReason><efbc:DecisionReasonCode>no-rece</efbc:DecisionReasonCode></efac:DecisionReason>"},
          {"<cbc:PayableAmount currencyID=\"EUR\">",
           "<efac:FieldsPrivacy/><cbc:PayableAmount currencyID=\"EUR\">"},
          {"<cbc:IdentificationCode>BEL</cbc:IdentificationCode>",
           "<cbc:IdentificationCode>FRA</cbc:IdentificationCode>"}
        ] do
      assert {:error, _} = AwardNotice.parse(String.replace(xml(), old, new), "LOT-0002"), old
    end
  end

  test "duplicate and mismatched references cannot create a winner" do
    duplicated =
      String.replace(
        xml(),
        "</efac:TenderingParty></efac:NoticeResult>",
        "<efac:Tenderer><cbc:ID>ORG-0001</cbc:ID></efac:Tenderer></efac:TenderingParty></efac:NoticeResult>"
      )

    assert {:error, _} = AwardNotice.parse(duplicated, "LOT-0002")
    assert {:error, _} = AwardNotice.parse(xml(), "LOT-0003")
  end

  test "XML entity declarations and resource exhaustion are rejected" do
    for xml <- [
          "<!DOCTYPE a [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><a>&x;</a>",
          :binary.copy("a", 4 * 1_024 * 1_024 + 1),
          "<a>\0</a>",
          String.duplicate("<a>", 45) <> String.duplicate("</a>", 45)
        ] do
      assert {:error, _} = AwardNotice.parse(xml, "LOT-0002")
    end
  end

  test "only whitespace may follow the document" do
    assert {:ok, _} = AwardNotice.parse(xml() <> "\n\t ", "LOT-0002")
    assert {:error, _} = AwardNotice.parse(xml() <> "<other/>", "LOT-0002")
    assert {:error, _} = AwardNotice.parse(xml() <> "garbage", "LOT-0002")
  end

  @tag :external
  test "the two retained official notices change the selected lot from no award to one winner" do
    directory = System.fetch_env!("TED_EVIDENCE_DIR")

    assert {:ok, before} =
             AwardNotice.parse(File.read!(Path.join(directory, "22171-2026.xml")), "LOT-0002")

    assert {:ok, after_change} =
             AwardNotice.parse(File.read!(Path.join(directory, "181194-2026.xml")), "LOT-0002")

    assert before.status == :not_awarded
    assert after_change.status == :awarded
    assert after_change.correction_of == before.notice_id <> "-" <> before.version
    assert after_change.winner.raw_identifier == "0844814966_8106565a-eb99-4a8d-a4df-2263a7e4511c"
    assert after_change.amount == "54192.04"
    assert after_change.concluded_on == ~D[2026-03-05]
  end

  defp company(id, number, name) do
    """
    <efac:Organization><efac:Company>
    <cac:PartyIdentification><cbc:ID>#{id}</cbc:ID></cac:PartyIdentification>
    <cac:PartyName><cbc:Name languageID="FRA">#{name}</cbc:Name></cac:PartyName>
    <cac:PartyLegalEntity><cbc:CompanyID>#{number}</cbc:CompanyID></cac:PartyLegalEntity>
    <cac:PostalAddress><cbc:StreetName>PRIVATE ADDRESS</cbc:StreetName><cac:Country><cbc:IdentificationCode>BEL</cbc:IdentificationCode></cac:Country></cac:PostalAddress>
    </efac:Company></efac:Organization>
    """
  end

  defp xml do
    """
    <ContractAwardNotice xmlns="urn:oasis:names:specification:ubl:schema:xsd:ContractAwardNotice-2"
      xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2"
      xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2"
      xmlns:ext="urn:oasis:names:specification:ubl:schema:xsd:CommonExtensionComponents-2"
      xmlns:efext="http://data.europa.eu/p27/eforms-ubl-extensions/1"
      xmlns:efac="http://data.europa.eu/p27/eforms-ubl-extension-aggregate-components/1"
      xmlns:efbc="http://data.europa.eu/p27/eforms-ubl-extension-basic-components/1">
    <cbc:ID>d05b0e27-f6e7-492f-bb0a-3f8c46e2df8f</cbc:ID><cbc:VersionID>01</cbc:VersionID>
    <cbc:ContractFolderID>9c9061ce-00ff-4fbd-9e54-9ffee357fc81</cbc:ContractFolderID>
    <cac:ProcurementProjectLot><cbc:ID>LOT-0002</cbc:ID></cac:ProcurementProjectLot>
    <cbc:NoticeTypeCode listName="result">can-standard</cbc:NoticeTypeCode>
    <cac:ContractingParty><cac:Party><cac:PartyIdentification><cbc:ID>ORG-0001</cbc:ID></cac:PartyIdentification></cac:Party></cac:ContractingParty>
    <ext:UBLExtensions><ext:UBLExtension><ext:ExtensionContent><efext:EformsExtension>
    <efac:Publication><efbc:NoticePublicationID>00181194-2026</efbc:NoticePublicationID><efbc:PublicationDate>2026-03-16+01:00</efbc:PublicationDate></efac:Publication>
    <efac:Changes><efbc:ChangedNoticeIdentifier>b05e2a20-b2f4-40c0-8e08-e14f310c600a-01</efbc:ChangedNoticeIdentifier></efac:Changes>
    <efac:Organizations>#{company("ORG-0001", "0207401341_7321", "Fixture buyer")}#{company("ORG-0005", "0844814966_suffix-is-unresolved", "Fixture winner")}</efac:Organizations>
    <efac:NoticeResult><cbc:TotalAmount currencyID="EUR">1965934.93</cbc:TotalAmount>
    <efac:LotResult><cbc:ID>RES-0002</cbc:ID><cbc:TenderResultCode>selec-w</cbc:TenderResultCode>
    <efac:LotTender><cbc:ID>TEN-0002</cbc:ID></efac:LotTender><efac:SettledContract><cbc:ID>CON-0002</cbc:ID></efac:SettledContract>
    <efac:FrameworkAgreementValues><cbc:MaximumValueAmount currencyID="EUR">9999999</cbc:MaximumValueAmount></efac:FrameworkAgreementValues>
    <efac:TenderLot><cbc:ID>LOT-0002</cbc:ID></efac:TenderLot></efac:LotResult>
    <efac:LotTender><cbc:ID>TEN-0002</cbc:ID><cac:LegalMonetaryTotal><cbc:PayableAmount currencyID="EUR">54192.04</cbc:PayableAmount></cac:LegalMonetaryTotal>
    <efac:TenderingParty><cbc:ID>TPA-0002</cbc:ID></efac:TenderingParty><efac:TenderLot><cbc:ID>LOT-0002</cbc:ID></efac:TenderLot></efac:LotTender>
    <efac:SettledContract><cbc:ID>CON-0002</cbc:ID><cbc:IssueDate>2026-03-05+01:00</cbc:IssueDate><cbc:AwardDate>2000-01-01</cbc:AwardDate>
    <efac:LotTender><cbc:ID>TEN-0002</cbc:ID></efac:LotTender></efac:SettledContract>
    <efac:TenderingParty><cbc:ID>TPA-0002</cbc:ID><efac:Tenderer><cbc:ID>ORG-0005</cbc:ID></efac:Tenderer></efac:TenderingParty></efac:NoticeResult>
    </efext:EformsExtension></ext:ExtensionContent></ext:UBLExtension></ext:UBLExtensions></ContractAwardNotice>
    """
  end
end
