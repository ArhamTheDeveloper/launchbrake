# JSON API

`appblock list --json` prints one JSON document on stdout. Reconciliation
messages go to stderr.

```json
{
  "schema": 1,
  "version": "0.3.0",
  "state_dir": "/home/you/.local/share/appblock",
  "count": 1,
  "blocked": [
    {
      "id": "rmpc",
      "enforcement": "enforced",
      "until": null,
      "unblock_at": 1789402126,
      "until_in": null,
      "unblock_in": 591
    }
  ],
  "managed": ["rmpc"]
}
```

- `schema` is the compatibility contract. Consumers must reject unsupported
  schemas rather than guessing.
- `version` is the appblock release version.
- `count` equals the number of entries in `blocked`.
- `enforcement` is appblock's current human-readable verdict and is not an enum.
- `until` and `unblock_at` are authoritative Unix epochs or `null`.
- `until_in` and `unblock_in` are snapshots of remaining seconds.
- `managed` contains launch command names with installed PATH shims.

Consumers must use this API instead of reading appblock's internal state files.
