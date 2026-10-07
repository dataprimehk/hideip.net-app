# Panel subscription fixtures

Synthetic inputs exported from panel subscription serializers on 2026-10-07.
All credentials are generated test data; endpoints use documentation addresses
or example domains. No live subscription tokens are included.

- 3x-ui: `f2172122`, `internal/sub/service.go`, exported as TSV and base64.
- PasarGuard: generator recorded `6372404`; JSON includes share links, subscription
  headers, base64/plain bodies with banners, Clash YAML and sing-box endpoints.
- Hiddify: `proxy_v3` URI templates; working checkout `beb37608`, TSV and base64.

`test/panel_compat_test.dart` asserts protocol fields, supported profile counts,
explicit refusal of incompatible variants and removal of synthetic status rows.
These fixtures verify parsing, not live connectivity.
