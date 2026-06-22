# Engine SSZ comparison fixtures

The comparison script automatically tests identification and each active
fork's payload-bodies routes using live block hashes. It scans recent blocks
for a real blob versioned hash before testing active blob routes. Routes whose
requests contain full Engine API objects need captured SSZ bytes or payload IDs.

Place optional fixtures at these paths:

```text
engine-ssz-fixtures/
  payloads/{paris,shanghai,cancun,prague,osaka,amsterdam}.ssz
  forkchoice/{paris,shanghai,cancun,prague,osaka,amsterdam}.ssz
  payload-ids/{paris,shanghai,cancun,prague,osaka,amsterdam}.txt
```

Each `.ssz` file is sent unchanged to both clients. Each payload-ID file must
contain one payload ID obtained from a matching forkchoice response. Missing
fixtures are reported as `SKIP`, never substituted with invalid request data.
