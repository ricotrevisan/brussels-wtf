# Ixelles proposal fixture

This scenario uses a captured, minimal representation of the authoritative Ixelles council index and **minimal representative text extracts**, not redistributed copies of the full municipal PDFs.

Authoritative origins observed for meeting `268`:

- Agenda: <https://www.ixelles.be/uploads/conseil/odj/268.pdf>
- Project material: <https://www.ixelles.be/uploads/conseil/projets/268.pdf>
- Parent index: <https://www.ixelles.be/site/11-Ordres-du-jour-et-proces-verbaux?langue=fr>

The extracts retain only the meeting context and one proposal needed by the acceptance scenario. They are intentionally not valid PDFs and cannot reproduce the full municipal documents. Recorded HTTP metadata in `scenario.json` describes the authoritative observations used to prepare the fixture; controlled test bodies are the minimal extracts.

The SHA-256 values in `scenario.json` identify **only these minimal test-extract bytes**. They are not presented as checksums of the full official PDFs. Production/public citations continue to use the authoritative municipal URLs.
