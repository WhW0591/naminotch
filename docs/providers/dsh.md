# DeepSeek Harness

Codenotch for macOS reads the DeepSeek Platform account through the grant
**DeepSeek Harness** already holds, and follows the sessions Harness is running.
Enable or disable it in **Settings → Accounts** like any other provider — it is
off until switched on, the way every provider but Claude and Codex is.
Disabling it stops polling, forgets Codenotch's readings and touches nothing in
Harness: the grant belongs to Harness, and signing out is Harness's business.

Discovered automatically. A Mac with no Harness install gets no ring, and
because there is no sign-in Codenotch could perform on Harness's behalf, it
draws no placeholder asking for one either.

## Readings

- **Account usage:** the headline ring is `spent / (spent + balance)` from the
  account's normal wallet, with `.derived` fidelity — the money is Platform's
  own, the percentage is Codenotch's. The card shows the amounts and the
  outstanding balance. This is the same window, read from the same endpoint, as
  the signed-in **DeepSeek** provider; the two differ only in whose credential
  they use.
- **Available tokens (estimate):** shown when the account summary carries a
  total estimation. The wallet-level `token_estimation` fields are a different
  figure and are not used for it.

There is no quota percentage to show, because DeepSeek Platform does not meter
one: the account is funded and spent. Bonus wallets are a separate pot and stay
off the ring rather than being folded into the balance.

## Activity

Harness publishes more than any other agent Codenotch follows, and in a form
that needs no guessing:

- **Liveness** is the session's own `session.lock`. Harness takes an exclusive
  `flock` on it for the life of the session and the kernel drops it when the
  process exits, so "is this session running" is answered by the kernel rather
  than by a timestamp a long think would age out. Codenotch takes and
  immediately releases the lock to ask — it never holds it.
- **State** is the Host's own projection cache,
  `~/.dsh/storages/session_projcache/sessions/<session>.json`. `pendingCalls`
  is non-empty exactly while tools are out, and `openStep` is present while a
  step is open; either means the turn has not finished. `questions.active`
  being non-empty means Harness has **stopped to ask you something**, which is
  the amber pulse rather than the spinning arc.

Nothing is decompressed: the `session.v4.jsonl.zstd` transcript is never read,
so no prompt, reply or tool output ever passes through Codenotch.

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

That file is YAML and Swift ships no YAML reader, so Codenotch reads the one
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

## Codenotch never writes

The grant is read and never refreshed, rewritten or deleted — it has no expiry
and no refresh flow of its own. Signing out is done in Harness, which clears the
local grant before revoking it remotely; Codenotch's switch only stops polling.
