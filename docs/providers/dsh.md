---
summary: "DeepSeek Harness: the grant it files, the Platform endpoints it answers, and what decides the platform's day."
read_when:
  - Changing the DeepSeek Harness provider, its credential or its daily figures
  - Changing the session monitor, or anything that files by day
---

# DeepSeek Harness

NamiNotch for macOS reads the DeepSeek Platform account through the grant
**DeepSeek Harness** already holds, and follows the sessions Harness is running.
Enable or disable it in **Settings → Accounts** like any other provider — it is
off until switched on, the way every provider but Claude and Codex is.
Disabling it stops polling, forgets NamiNotch's readings and touches nothing in
Harness: the grant belongs to Harness, and signing out is Harness's business.

Discovered automatically. A Mac with no Harness install gets no ring, and
because there is no sign-in NamiNotch could perform on Harness's behalf, it
draws no placeholder asking for one either.

## Readings

- **Account usage:** the headline ring is `spent / (spent + balance)` from the
  account's normal wallet, with `.derived` fidelity — the money is Platform's
  own, the percentage is NamiNotch's. The card shows the amounts and the
  outstanding balance. This is the same window, read from the same endpoint, as
  the signed-in **DeepSeek** provider; the two differ only in whose credential
  they use.
- **Available tokens (estimate):** shown when the account summary carries a
  total estimation. The wallet-level `token_estimation` fields are a different
  figure and are not used for it.

There is no quota percentage to show, because DeepSeek Platform does not meter
one: the account is funded and spent. Bonus wallets are a separate pot and stay
off the ring rather than being folded into the balance.

### What decides the platform's "day"

The card's **Today** row comes from `/api/v0/usage/by_api_key/amount`, which
answers in daily buckets. Where those buckets are cut is worth writing down,
because the obvious readings of it are both wrong, and each one was measured:

- **`tz` does nothing.** The same window asked for at `tz=0`, `+39600` and
  `-39600` comes back with byte-identical bucket keys *and* values.
- **`x-client-timezone-offset` does nothing either.** `+39600`, `0`, `+28800`
  and `-18000` likewise change nothing. So the platform is not reading the
  reader's zone off the request.
- **`start` decides it.** A window beginning at 00:00, 14:00 and 18:00 UTC comes
  back cut at 00:00, 14:00 and 18:00 UTC — and one beginning at local 06:00
  comes back cut at local 06:00.

So the platform has no opinion about the reader's day. It cuts wherever it is
asked to, and NamiNotch has always asked for local midnight, which is why the
buckets have always looked like local calendar days. **Moving the boundary is a
matter of moving that one line** — the constants in `amountQuery` — and of
looking the day up the same way; nothing has to be asked of the platform.

The window must be **thirty days**: a ten-day one is refused with
`biz_code: 1, "INVALID_PARAM"`. Its alignment is not checked.

`dayKey` labels each bucket with the local calendar date of the bucket's *start*,
so whichever boundary is sent is also the one the card looks up. Those two must
move together or the row reads "Pending" forever.

## Activity

Harness publishes more than any other agent NamiNotch follows, and in a form
that needs no guessing:

- **Liveness** is the session's own `session.lock`. Harness takes an exclusive
  `flock` on it for the life of the session and the kernel drops it when the
  process exits, so "is this session running" is answered by the kernel rather
  than by a timestamp a long think would age out. NamiNotch takes and
  immediately releases the lock to ask — it never holds it.
- **State** is the Host's own projection cache,
  `~/.dsh/storages/session_projcache/sessions/<session>.json`. `pendingCalls`
  is non-empty exactly while tools are out, and `openStep` is present while a
  step is open; either means the turn has not finished. `questions.active`
  being non-empty means Harness has **stopped to ask you something**, which is
  the amber pulse rather than the spinning arc.

Nothing is decompressed: the `session.v4.jsonl.zstd` transcript is never read,
so no prompt, reply or tool output ever passes through NamiNotch.

The session's own title names the cell once the model has written one, and the
working directory is the second line until then. The peek click raises the
Harness application; Harness publishes no pid per session, so the application is
the only thing there is to raise.

## Source and credentials

`DSH_HOME` moves the data root; the default is `~/.dsh`. The grant is read from
`~/.dsh/.credentials.yaml`, record `deepseek-account-platform/default`:

```yaml
records:
  deepseek-account-platform/default:
    kind: grant
    payload:
      version: 1
      token: <64-character grant>
      issuer: https://platform.deepseek.com
```

That file is YAML and Swift ships no YAML reader, so NamiNotch reads the one
shape it needs — nested block mappings of plain scalars — and treats anything it
does not recognise as no credential rather than as a wrong one. The store holds
a browser session and a device identity alongside the account grant; only the
named record is ever claimed.

One read-only request per refresh:

```http
GET <issuer>/api/v0/users/get_user_summary
x-dsh-auth-token: <grant>
x-client-platform: desktop-mac
x-client-bundle-id:
x-client-version: <app version>
x-client-locale: en_US
x-client-timezone-offset: <whole seconds east of UTC>
```

Harness's own account provider owns those five headers and builds them the same
way; `x-client-bundle-id` is empty on purpose, and the locale is reduced to the
two the Platform serves. **The grant is sent only to the origin that issued
it** — the `issuer` field, not a constant — and an issuer that is not `https` is
refused outright.

HTTP 401, or a top-level `code: 40003` under HTTP 200, is the owning package's
own "this grant is no longer good" and becomes `needsAuth`; everything else
keeps the last reading and degrades to a visible status rather than clearing it.

## NamiNotch never writes

The grant is read and never refreshed, rewritten or deleted — it has no expiry
and no refresh flow of its own. Signing out is done in Harness, which clears the
local grant before revoking it remotely; NamiNotch's switch only stops polling.
