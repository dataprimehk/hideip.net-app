# URL scheme and app links

How third-party panels and seller buttons open hideip.net with a
subscription URL or share link already filled in.

Neither shape imports anything by itself. The app opens the import screen
with the field prefilled; a person still has to press the button.

Source of truth in the app: `lib/core/deep_link.dart`.

## Panel recommendation

For Remnawave, Marzban, 3x-ui, and similar subscription UIs, emit:

```
hideip://add?url=<urlencoded-subscription-or-share-link>
```

Optional display name:

```
hideip://add?url=<urlencoded>&name=<urlencoded-label>
```

Also link the store pages so users who do not have the app yet can install
it first:

- Google Play: <https://play.google.com/store/apps/details?id=net.hideip.vpn>
- App Store: <https://apps.apple.com/app/id6793134083>
- GitHub Releases: <https://github.com/dataprimehk/hideip.net-app/releases>

Seller kit (local generator, no upload): <https://hideip.net/sellers>

Do **not** invent other scheme names (for example `install-sub`). Stick to
the shapes below.

## Preferred: HTTPS app link

Payload rides in the URL fragment so it never appears in the request line
or server logs. The OS verifies the link against hideip.net
(`assetlinks.json` / Apple App Site Association).

```
https://hideip.net/add#url=<urlencoded>&name=<optional>
```

`/import` is accepted by the app as the same destination. Prefer `/add` in
new panel snippets: the live site currently serves `/add` and the Apple
association file lists `/add`; `/import` may 404 on the website even though
the client still parses it.

`www.hideip.net` is accepted. A trailing slash on the path is fine. If a
middlebox drops the fragment, the app also reads `url` / `name` from the
query string as a fallback.

## Transitional: `hideip://` custom scheme

Any app may register a custom scheme, which is why HTTPS app links are the
long-term target. Custom-scheme buttons already sit in third-party panels,
so the client keeps accepting them.

| Form | Example |
| --- | --- |
| Query `add` | `hideip://add?url=<urlencoded>` |
| Query `install-config` | `hideip://install-config?url=<urlencoded>` |
| Query `import` | `hideip://import?url=<urlencoded>` |
| Path `import` | `hideip://import/<payload>` |

`url` is a share link (`vless://…`, …), an `https://` subscription feed, or
another body the import screen already accepts. Percent-encode the whole
payload when it sits in a query parameter.

Path form: everything after `import/` is the payload (decoded once). Senders
should URL-encode a full share link so its own `?` / `#` survive. A trailing
`#name` on the path payload is treated as a label only when the payload is
not itself a `scheme://` share link.

Some launchers normalize `hideip://x` to `hideip:/x`; the parser accepts
both.

## Device pairing (not for panels)

```
hideip://link?v=1&id=<link_id>
```

Opens a linked-device approval flow. Do not use this for subscription
install buttons.

## Known site follow-ups (out of scope for this doc PR)

- Public `/import` path may 404 while `/add` works.
- Apple App Site Association currently lists `/add` only.
- `assetlinks.json` currently ships one Play App Signing fingerprint;
  GitHub-signed APKs use a different certificate and will not verify the
  same app link until a second fingerprint is published.
