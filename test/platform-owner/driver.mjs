// driver.mjs — the browser half of the Platform owner AND the first
// tenant's Owner setup-link flow (ADR-0093, hosted#201/#202).
//
// In plain words: a person receives a one-time setup link, opens it, sets a
// password, enrolls an authenticator app, and signs in. This driver does
// exactly that, through Zitadel's own hosted Login v2 UI — nothing here
// calls a Zitadel API to fabricate a password or a verified factor. Both
// setup-link recipients reuse this one driver (ADR-0027): the Platform
// owner's link arrives by mail (polled from Mailpit, the default),
// the first tenant's Owner link is offline (supplied directly via
// SETUP_LINK, read by the caller from the gibson-first-tenant-owner-setup
// Secret) — see test/demo/exit-test-enrollment.sh.
//
// SELECTORS. Login v2's exact markup is not something this repository
// controls (it ships with the Zitadel chart), so the selectors below are
// role/label-based (Playwright's getByRole / getByLabel), the most drift-
// resistant option short of running the real UI once to confirm them. If
// Login v2 changes shape, this driver goes red at a specific step and names
// it — that is the correct failure for an exit test on a surface this repo
// does not own, not a flake to silence.
//
// TOTP. The enrollment screen shows a QR code AND a manual-entry secret
// (Zitadel always offers both). This driver reads the manual-entry secret as
// text and derives the six-digit code with the `otpauth` library — no
// QR-decoding dependency needed.
//
// Modes:
//   --drill      the real drill: setup link -> set password -> enroll TOTP
//                -> sign-in. The setup link comes from Mailpit (requires
//                MAILPIT_URL, PLATFORM_OWNER_EMAIL, ISSUER_ORIGIN) unless
//                SETUP_LINK is given directly (the offline leg — nothing to
//                poll for). Always requires PLATFORM_OWNER_PASSWORD,
//                TOTP_SECRET_OUT and LANDING_ORIGIN (or CONSOLE_ORIGIN, kept
//                for the Platform owner's existing callers).
//   --resign-in  re-authenticate with the password + TOTP secret a prior
//                --drill run produced (PLATFORM_OWNER_PASSWORD,
//                PLATFORM_OWNER_TOTP_SECRET), to prove the account works on
//                a second, ordinary sign-in — not just immediately after
//                setup.
//   --first-sign-in  a person who set a password at signup signs in for the
//                first time: the landing page -> Login v2 (login name,
//                password) -> the forced TOTP enrollment -> the landing
//                origin. Requires OWNER_EMAIL, OWNER_PASSWORD,
//                LANDING_ORIGIN, TOTP_SECRET_OUT and EXPECT_WORKSPACE. Fails
//                unless the page lands under EXPECT_PATH (default
//                /dashboard) and shows the workspace: an owner who lands on
//                the onboarding page has a workspace they cannot reach
//                (gibson#1188).
//   --selftest   offline, zero-dependency: proves the setup-link parsing and
//                TOTP-code derivation can themselves fail. No network, no
//                playwright, no cluster.
//
// A skip is a failure: there is no code path here that exits 0 without a
// drill step having actually run.

import { readFileSync, writeFileSync } from "node:fs";
import process from "node:process";
import { TOTP, Secret } from "otpauth";
// findMessageFor, latestMessageFor, messagesFor and pickSetupLinkMessage live in
// test/lib/mailbox.mjs since hosted#379. Both drivers had their own copy of
// findMessageFor, same body and a different error string, and both asserted an
// invariant the first tenant's Owner cannot satisfy: that address receives a
// setup link AND a welcome email.
import {
  findMessageFor,
  latestMessageFor,
  messagesFor,
  pickSetupLinkMessage,
} from "../lib/mailbox.mjs";
import { safeText, safeURL } from "../lib/redact.mjs";

// ---------------------------------------------------------------------------
// Pure helpers (selftested, no I/O)
// ---------------------------------------------------------------------------


/**
 * extractSetupLink pulls a setup link out of a delivered message body. Login
 * v2 redeems an invite code at /ui/v2/login/verify with userId, code,
 * invite=true and organization (gibson#261, zitadelconn.SetupLinkURLTemplate,
 * which builds all three setup links). The link must point at the product
 * surface (issuerOrigin).
 *
 * The older /ui/v2/login/invite?userID= shape is refused by name. Login v2
 * has no such route: run 36324169933 opened one and got a 404 page.
 */
export function extractSetupLink(body, issuerOrigin) {
  const urls = body.match(/https?:\/\/[^\s"'<>]+/g) ?? [];
  for (let raw of urls) {
    raw = raw.replace(/[.,)\]]+$/, "");
    let u;
    try {
      u = new URL(raw);
    } catch {
      continue;
    }
    if (u.pathname.endsWith("/ui/v2/login/invite")) {
      throw new Error(
        `the setup link uses the retired /ui/v2/login/invite route, which Login v2 answers with a 404: ${safeURL(raw)}`,
      );
    }
    if (!u.pathname.endsWith("/ui/v2/login/verify")) continue;
    if (!u.searchParams.get("code") || !u.searchParams.get("userId")) continue;
    if (u.searchParams.get("invite") !== "true") {
      throw new Error(
        `the setup link does not carry invite=true, so Login v2 verifies an email instead of redeeming an invite: ${safeURL(raw)}`,
      );
    }
    if (!raw.startsWith(issuerOrigin)) {
      throw new Error(
        `the setup link points at ${u.origin}, not the product surface ${issuerOrigin} — the Platform owner's browser has no route there`,
      );
    }
    return {
      link: raw,
      userId: u.searchParams.get("userId"),
      code: u.searchParams.get("code"),
      organization: u.searchParams.get("organization"),
    };
  }
  throw new Error(
    `no /ui/v2/login/verify setup link with userId+code found in the delivered mail:\n${safeText(body.slice(0, 2000))}`,
  );
}


/**
 * secretFromOtpauthURI reads the base32 secret out of the otpauth:// URI that
 * Login v2's TOTP enrollment page shows as a link beside its QR code. The
 * page renders no bare secret text, so this is the only place to read it.
 */
export function secretFromOtpauthURI(uri) {
  let u;
  try {
    u = new URL(uri);
  } catch {
    throw new Error("the TOTP link is not a URI");
  }
  const secret = (u.searchParams.get("secret") ?? "").replace(/\s+/g, "").toUpperCase();
  if (u.protocol !== "otpauth:" || !/^[A-Z2-7]{16,}=*$/.test(secret)) {
    // The URI holds the TOTP secret, so the error names only its scheme.
    throw new Error(`the TOTP link (${u.protocol}) carries no base32 secret`);
  }
  return secret;
}

/** totpCodeFor derives the current six-digit code from a base32 secret. */
export function totpCodeFor(base32Secret, timestampMs) {
  const totp = new TOTP({
    secret: Secret.fromBase32(base32Secret.replace(/\s+/g, "")),
    digits: 6,
    period: 30,
    algorithm: "SHA1",
  });
  return totp.generate({ timestamp: timestampMs ?? Date.now() });
}

/**
 * fillUntilHeld types into a field and proves the value stayed. The login
 * pages are server-rendered Next.js, so a field is visible and fillable
 * before React hydrates, and hydration then resets it to empty. That race
 * failed the signup exit test (run 36322836959, fixed by hosted#229). Read
 * the value back and fill again until it holds. A field that never holds
 * its value is a real defect, and the error names it.
 */
export async function fillUntilHeld(locator, value, label, opts = {}) {
  const timeoutMs = opts.timeoutMs ?? 15_000;
  const settleMs = opts.settleMs ?? 300;
  const sleep = opts.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms)));
  const deadline = Date.now() + timeoutMs;
  let last = "";
  do {
    await locator.fill(value);
    await sleep(settleMs);
    last = await locator.inputValue();
    if (last === value) return;
  } while (Date.now() < deadline);
  // The message reads nothing of either value. The field can be a password,
  // so neither the text nor a property of it reaches a log.
  throw new Error(
    `the ${label} field never held its value: it holds ${last === "" ? "nothing" : "other text"}`,
  );
}

/**
 * submitFilled presses a Login v2 form's submit button once the form enables
 * it. Login v2 keeps the button disabled until react-hook-form marks the form
 * valid, and that state only moves on an input event React has seen. A fill
 * that landed before hydration leaves the value in the DOM but the form
 * "invalid", so the button never enables (runs 36349218537 and 36349218531
 * waited 30s on a disabled Continue with the code already typed). When the
 * button stays disabled, type every value again as keystrokes.
 */
async function submitFilled(page, fields, label, { timeoutMs = 20_000 } = {}) {
  const submit = page.locator('[data-testid="submit-button"]');
  const startUrl = page.url();
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    await page.waitForTimeout(500);
    // The page moved on: the form was already submitted (an earlier click, or
    // Login v2 submitting on its own). Nothing is left to type into.
    if (page.url() !== startUrl) return;
    if (await submit.isEnabled().catch(() => false)) {
      await submit.click();
      // Hand back only once the page has moved on, so the caller never sees
      // the form it just submitted and submits it a second time (demo run
      // 36353719840 did, then typed into a field that had gone).
      await page.waitForURL((u) => u.toString() !== startUrl, { timeout: 15_000 }).catch(() => {});
      return;
    }
    for (const [field, value] of fields) {
      if (!(await field.isVisible().catch(() => false))) return;
      await field.fill("", { timeout: 5_000 });
      await field.pressSequentially(value, { delay: 25, timeout: 10_000 });
    }
  }
  throw new Error(`the ${label} form never enabled its submit button`);
}

/**
 * freshTotpCode returns a TOTP code that differs from `lastCode`. Zitadel
 * refuses a code that was already used, and the enrollment just used the
 * current window's code, so wait for the next window when they match.
 */
async function freshTotpCode(secret, lastCode) {
  let code = totpCodeFor(secret);
  while (code === lastCode) {
    await new Promise((r) => setTimeout(r, 1_000));
    code = totpCodeFor(secret);
  }
  return code;
}

/**
 * signInThroughLanding opens the landing origin and finishes sign-in the way
 * a person does. Finishing Login v2's setup flow leaves a Zitadel session,
 * but an app (the dashboard, the Zitadel console) signs you in only through
 * its own OIDC round trip: run 36340039871 finished setup and was sent to the
 * dashboard's "Welcome to Gibson / Sign in" page. So press Sign in, answer
 * whatever Login v2 asks (pick the account, password, TOTP), and stop when
 * the app serves a page that is not a login page.
 */
async function signInThroughLanding(page, landingOrigin, { email, password, totpSecret, lastCode, totpSecretOut }) {
  const isLogin = (u) => /\/login|\/ui\/v2\/login/.test(new URL(u).pathname);
  // Let the TOTP enrollment submit finish first. Otherwise the loop below can
  // see the enrollment page's own code field for a moment, wait for a fresh
  // code, and then fill a field that has gone (run 36342856537 did exactly
  // that while Login v2 was already redirecting to the console).
  await page
    .waitForURL((u) => !u.pathname.includes("/otp/time-based/set"), { timeout: 30_000 })
    .catch(() => {});
  await page.goto(landingOrigin);
  const deadline = Date.now() + 120_000;
  let used = lastCode;
  while (Date.now() < deadline) {
    await page.waitForLoadState("domcontentloaded").catch(() => {});
    const here = page.url();
    if (new URL(here).pathname.startsWith("/login/error")) {
      const reason = new URL(here).searchParams.get("reason") ?? "unknown";
      throw new Error(`the app refused the sign-in: /login/error?reason=${reason}`);
    }
    if (new URL(here).origin === new URL(landingOrigin).origin && !isLogin(here)) {
      await page.waitForLoadState("networkidle").catch(() => {});
      if (!isLogin(page.url())) return page.url();
    }
    // A BUTTON only. The dashboard's header also carries a "sign in" LINK to
    // /login, first in the page, and clicking it just reloads /login (run
    // 36342856582 looped on it for 120s). The main control is a button.
    const appSignIn = page.getByRole("button", { name: /^sign in$/i });
    const account = page.getByRole("button", { name: /@/ });
    const user = page.locator('[data-testid="username-text-input"]');
    const pw = page.locator('[data-testid="password-text-input"]');
    const code = page.locator('[data-testid="code-text-input"]');
    // The forced second-factor enrollment of a first sign-in (ADR-0093: MFA
    // for each account). The chooser offers the authenticator app, and the
    // enrollment page shows the otpauth:// link that carries the secret.
    const otpauthLink = page.locator('a[href^="otpauth://"]');
    const totpChoice = page.locator('a[href*="/otp/time-based"]')
      .or(page.getByRole("button", { name: /authenticator app|totp/i }))
      .or(page.getByRole("link", { name: /authenticator app|totp/i }));
    // Only a Login v2 sign-in prompt asks for a code here, never an
    // enrollment page, and the field must still be there after the wait for a
    // fresh code.
    const onOtpPrompt = /\/ui\/v2\/login\/otp\//.test(new URL(here).pathname)
      && !new URL(here).pathname.endsWith("/set");
    if (await otpauthLink.count()) {
      // Zitadel mints a new secret on each load of the enrollment page, so
      // the link is read on every pass, never cached.
      const shown = secretFromOtpauthURI(await otpauthLink.first().getAttribute("href"));
      if (shown !== totpSecret) {
        totpSecret = shown;
        if (totpSecretOut) writeFileSync(totpSecretOut, totpSecret);
        console.log("enrolling TOTP with the secret of the otpauth link");
      }
      used = await freshTotpCode(totpSecret, used);
      await fillUntilHeld(code, used, "TOTP code");
      await submitFilled(page, [[code, used]], "TOTP enrollment");
    } else if (!totpSecret && (await totpChoice.count())) {
      await totpChoice.first().click({ noWaitAfter: true, timeout: 10_000 }).catch(() => {});
    } else if (onOtpPrompt && (await code.isVisible().catch(() => false))) {
      if (!totpSecret) throw new Error(`Login v2 asks for a code at ${safeURL(here)}, and no TOTP secret is enrolled`);
      used = await freshTotpCode(totpSecret, used);
      if (await code.isVisible().catch(() => false)) {
        await fillUntilHeld(code, used, "TOTP code");
        await submitFilled(page, [[code, used]], "TOTP code");
      }
    } else if (await pw.isVisible().catch(() => false)) {
      await fillUntilHeld(pw, password, "password");
      await submitFilled(page, [[pw, password]], "password");
    } else if (email && (await user.isVisible().catch(() => false))) {
      await fillUntilHeld(user, email, "login name");
      await submitFilled(page, [[user, email]], "login name");
    } else if (/\/ui\/v2\/login\/accounts/.test(here) && (await account.count())) {
      await account.first().click({ noWaitAfter: true, timeout: 10_000 }).catch(() => {});
    } else if (await appSignIn.first().isVisible().catch(() => false)) {
      // The click starts an OIDC redirect chain through Zitadel. Do not make
      // the click wait for that navigation (demo run 36362839244 timed out on
      // it while the page had already reached the account chooser): the loop
      // reads wherever the page lands on its next pass.
      await appSignIn.first().click({ noWaitAfter: true, timeout: 10_000 }).catch(() => {});
    }
    await page.waitForTimeout(1_000);
  }
  throw new Error(`expected to land signed in at ${landingOrigin}, still at ${safeURL(page.url())}`);
}

// ---------------------------------------------------------------------------
// Selftest — proves the assertions above can fail (guards lane, offline)
// ---------------------------------------------------------------------------

async function selftest() {
  const issuer = "https://app.localhost.zeroroot.ai";
  let failures = 0;
  const check = (name, fn, wantThrow) => {
    let threw = null;
    let out;
    try {
      out = fn();
    } catch (e) {
      threw = e;
    }
    const ok = wantThrow ? threw !== null : threw === null;
    if (!ok) {
      failures += 1;
      console.error(
        `SELFTEST FAIL: ${name} — ${wantThrow ? "should have thrown, did not" : `threw: ${threw}`}`,
      );
    } else {
      console.log(`selftest ok: ${name}`);
    }
    return out;
  };

  const good = check(
    "extracts userId/code/organization from a delivered mail",
    () =>
      extractSetupLink(
        `Hi,\nset up your account:\n${issuer}/ui/v2/login/verify?userId=U-1&code=code-abc&invite=true&organization=O-1\nThanks`,
        issuer,
      ),
    false,
  );
  if (good && (good.userId !== "U-1" || good.code !== "code-abc" || good.organization !== "O-1")) {
    failures += 1;
    console.error(`SELFTEST FAIL: extracted wrong fields: ${JSON.stringify(good)}`);
  }

  check(
    "a mail with no code param is refused",
    () => extractSetupLink(`Welcome! Visit ${issuer}/docs for help.`, issuer),
    true,
  );

  check(
    "a link on a non-product origin is refused",
    () =>
      extractSetupLink(
        `click https://evil.example.com/ui/v2/login/verify?userId=U-1&code=c1&invite=true`,
        issuer,
      ),
    true,
  );

  check(
    "a link to the retired /invite route is refused, not opened into a 404",
    () =>
      extractSetupLink(
        `${issuer}/ui/v2/login/invite?userID=U-1&code=c1&organization=O-1`,
        issuer,
      ),
    true,
  );

  check(
    "a verify link without invite=true is refused",
    () =>
      extractSetupLink(`${issuer}/ui/v2/login/verify?userId=U-1&code=c1`, issuer),
    true,
  );

  const msgs = [
    { ID: "1", To: [{ Address: "owner@x.test" }] },
    { ID: "2", To: [{ Address: "someone-else@x.test" }] },
  ];
  check("finds the message for the Platform owner's address", () => {
    const m = findMessageFor(msgs, "OWNER@x.test");
    if (m?.ID !== "1") throw new Error(`matched ${m?.ID}, want 1`);
  }, false);
  check(
    "two mails to the Platform owner's address is an error, not a free pass",
    () =>
      findMessageFor(
        [...msgs, { ID: "3", To: [{ Address: "owner@x.test" }] }],
        "owner@x.test",
      ),
    true,
  );
  check(
    "the error names the subjects it refuses, not just a count",
    () => {
      try {
        findMessageFor(
          [
            { ID: "a", Subject: "Set up your account", To: [{ Address: "o@x.test" }] },
            { ID: "b", Subject: "Welcome to ZeroRoot AI", To: [{ Address: "o@x.test" }] },
          ],
          "o@x.test",
        );
      } catch (e) {
        if (!/Set up your account/.test(e.message) || !/Welcome to ZeroRoot AI/.test(e.message)) {
          throw new Error(`error named no subjects: ${e.message}`);
        }
        return;
      }
      throw new Error("two messages did not throw");
    },
    false,
  );
  // FAILING FIXTURE for the invariant that could not hold. The first tenant's
  // Owner receives a setup link AND a welcome email, so "exactly one message"
  // is impossible for that address — it failed the drill three times on
  // 2026-10-01. pickSetupLinkMessage selects on CONTENT: the welcome email's
  // body carries no /ui/v2/login/verify link, so the extractor rejects it and
  // the next candidate is tried.
  check(
    "a mailbox holding a welcome email AND a setup link still yields the link",
    async () => {
      const bodies = {
        w: "Welcome to ZeroRoot AI. Your workspace is ready.",
        s: "Set up: https://app.localhost.zeroroot.ai/ui/v2/login/verify?userId=u1&code=c1&invite=true",
      };
      const got = await pickSetupLinkMessage(
        [
          { ID: "w", Subject: "Welcome", Created: "2026-10-02T11:05:00Z", To: [{ Address: "o@x.test" }] },
          { ID: "s", Subject: "Set up", Created: "2026-10-02T11:00:00Z", To: [{ Address: "o@x.test" }] },
        ],
        "o@x.test",
        async (id) => bodies[id],
        (body) => extractSetupLink(body, "https://app.localhost.zeroroot.ai"),
      );
      if (got?.userId !== "u1") throw new Error(`picked ${JSON.stringify(got)}`);
    },
    false,
  );

  // A known base32 secret (RFC 4226/6238 test vector-style) must derive a
  // stable 6-digit code, and two different timestamps 30s apart must derive
  // DIFFERENT codes — otherwise the derivation is not actually time-based
  // and the assertion below could never catch a broken generator.
  const secret = "JBSWY3DPEHPK3PXP";
  const t0 = Date.parse("2026-01-01T00:00:00Z");
  const code1 = check("derives a 6-digit TOTP code", () => totpCodeFor(secret, t0), false);
  if (code1 && !/^\d{6}$/.test(code1)) {
    failures += 1;
    console.error(`SELFTEST FAIL: TOTP code is not 6 digits: ${code1}`);
  }
  const code2 = totpCodeFor(secret, t0 + 30_000);
  if (code1 === code2) {
    failures += 1;
    console.error("SELFTEST FAIL: TOTP codes 30s apart are identical; the derivation is not time-based");
  } else {
    console.log("selftest ok: TOTP codes 30s apart differ");
  }

  const fromUri = check(
    "reads the secret from Login v2's otpauth link",
    () => secretFromOtpauthURI("otpauth://totp/ZITADEL:owner%40x.test?algorithm=SHA1&digits=6&issuer=ZITADEL&period=30&secret=JBSWY3DPEHPK3PXP"),
    false,
  );
  if (fromUri && fromUri !== "JBSWY3DPEHPK3PXP") {
    failures += 1;
    console.error(`SELFTEST FAIL: read the wrong secret: ${fromUri}`);
  }
  check(
    "an otpauth link with no secret is refused",
    () => secretFromOtpauthURI("otpauth://totp/ZITADEL:owner?issuer=ZITADEL"),
    true,
  );
  check(
    "a non-otpauth link is refused",
    () => secretFromOtpauthURI("https://app.example.test/?secret=JBSWY3DPEHPK3PXP"),
    true,
  );
  // hosted is public: no error or log line may carry a secret (hosted#47).
  {
    let msg = "";
    try {
      secretFromOtpauthURI("https://app.example.test/?secret=JBSWY3DPEHPK3PXP");
    } catch (e) {
      msg = String(e?.message ?? e);
    }
    if (!msg || msg.includes("JBSWY3DPEHPK3PXP")) {
      failures += 1;
      console.error("SELFTEST FAIL: the refusal of a TOTP link shows its secret");
    } else {
      console.log("selftest ok: the refusal of a TOTP link shows no secret");
    }
  }
  {
    const shown = safeText("open https://app.example.test/ui/v2/login/verify?userId=123456789&code=SECRETCODE#frag now");
    if (shown.includes("SECRETCODE") || shown.includes("frag") || !shown.includes("code=SECR")) {
      failures += 1;
      console.error(`SELFTEST FAIL: safeText does not shorten a link in a text: ${shown}`);
    } else {
      console.log("selftest ok: safeText cuts each query value of a link to four characters");
    }
  }

  const fakeField = (resets) => {
    let v = "";
    let fills = 0;
    return {
      fill: async (x) => {
        fills += 1;
        v = fills <= resets ? "" : x;
      },
      inputValue: async () => v,
    };
  };
  const noSleep = async () => {};
  const asyncCheck = async (name, fn, wantThrow) => {
    let threw = null;
    try {
      await fn();
    } catch (e) {
      threw = e;
    }
    if (wantThrow ? threw === null : threw !== null) {
      failures += 1;
      console.error(
        `SELFTEST FAIL: ${name} — ${wantThrow ? "should have thrown, did not" : `threw: ${threw}`}`,
      );
    } else {
      console.log(`selftest ok: ${name}`);
    }
  };
  await asyncCheck(
    "a field that hydration resets once is filled again",
    () => fillUntilHeld(fakeField(1), "pw", "password", { sleep: noSleep }),
    false,
  );
  await asyncCheck(
    "a field that never keeps its value fails",
    () =>
      fillUntilHeld(fakeField(Infinity), "pw", "password", {
        sleep: noSleep,
        timeoutMs: 0,
      }),
    true,
  );
  {
    // A field that holds other text: the error names neither the typed text
    // nor the text in the field.
    const other = { fill: async () => {}, inputValue: async () => "held-s3cr3t" };
    let msg = "";
    try {
      await fillUntilHeld(other, "typed-s3cr3t", "password", { sleep: noSleep, timeoutMs: 0 });
    } catch (e) {
      msg = String(e?.message ?? e);
    }
    if (!msg || msg.includes("s3cr3t")) {
      failures += 1;
      console.error("SELFTEST FAIL: the error of a field that never holds its value shows a value");
    } else {
      console.log("selftest ok: the error of a field that never holds its value shows no value");
    }
  }

  const verdictCases = [
    ["a landing under /dashboard that shows the workspace passes",
      { path: "/dashboard", body: "Welcome to sg-1\nFindings" }, null],
    ["the onboarding page fails",
      { path: "/onboarding", body: "You are signed in as x, but you don't belong to any organization yet." }, "organization"],
    ["a landing outside /dashboard fails",
      { path: "/login", body: "Sign in" }, "not under"],
    ["a /dashboard page that does not show the workspace fails",
      { path: "/dashboard/no-workspace", body: "Something went wrong" }, "does not show"],
    ["a /dashboard page that shows only the owner email fails",
      { path: "/dashboard", body: "Findings\nsg-1@signup.example.test" }, "does not show"],
  ];
  for (const [name, landing, want] of verdictCases) {
    const got = landingVerdict(landing, {
      expectPath: "/dashboard", workspace: "sg-1", ownerEmail: "sg-1@signup.example.test",
    });
    const ok = want === null ? got === null : typeof got === "string" && got.includes(want);
    if (!ok) {
      failures += 1;
      console.error(`SELFTEST FAIL: ${name} — verdict ${JSON.stringify(got)}`);
    } else {
      console.log(`selftest ok: ${name}`);
    }
  }
  if (failures > 0) {
    console.error(`selftest: ${failures} assertion(s) cannot fail correctly`);
    process.exit(1);
  }
  console.log("selftest: all assertions can fail — guard is honest");
}

if (process.argv.includes("--selftest")) {
  await selftest();
  process.exit(0);
}

// ---------------------------------------------------------------------------
// Shared browser plumbing (mirrors test/signup/driver.mjs)
// ---------------------------------------------------------------------------

function requireEnv(name) {
  const v = process.env[name];
  if (!v) {
    console.error(`FATAL: ${name} is required`);
    process.exit(1);
  }
  return v;
}

function resolverArgs() {
  const ip = process.env.EDGE_IP ?? "";
  const hosts = (process.env.EDGE_HOSTS ?? "").split(/\s+/).filter(Boolean);
  if (!ip || hosts.length === 0) return [];
  const rules = hosts.map((h) => `MAP ${h} ${ip}`).join(", ");
  return [`--host-resolver-rules=${rules}`];
}

async function newPage(chromium, diagDir) {
  const browser = await chromium.launch({
    args: ["--no-sandbox", ...resolverArgs()],
  });
  const context = await browser.newContext({ ignoreHTTPSErrors: true });
  const page = await context.newPage();
  page.setDefaultTimeout(30_000);
  return { browser, context, page };
}

async function diagnose(page, diagDir, label) {
  if (!diagDir) return;
  try {
    await page.screenshot({ path: `${diagDir}/${label}.png`, fullPage: true });
    writeFileSync(`${diagDir}/${label}.html`, await page.content());
    console.error(`diagnostics written: ${diagDir}/${label}.{png,html} (url=${safeURL(page.url())})`);
  } catch (e) {
    console.error(`diagnostics failed for ${label}: ${e}`);
  }
}

async function pollMailpitForSetupLink(mailpitURL, email, issuerOrigin, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let lastCount = -1;
  while (Date.now() < deadline) {
    const resp = await fetch(`${mailpitURL}/api/v1/messages?limit=200`).catch(() => null);
    if (resp && resp.ok) {
      const body = await resp.json();
      const messages = body.messages ?? [];
      if (messages.length !== lastCount) {
        lastCount = messages.length;
        console.log(`mailpit holds ${messages.length} message(s)`);
      }
      // PICK THE SETUP MAIL, do not assume it is the only mail. The first
      // tenant's Owner receives a setup link AND a welcome email, so demanding
      // exactly one message for this address is an invariant that cannot hold —
      // it is what failed the drill three times on 2026-10-01. Candidates are
      // tried newest first and a body with no link is skipped, which is how the
      // welcome email is passed over rather than mistaken for a setup mail.
      const link = await pickSetupLinkMessage(
        messages,
        email,
        async (id) => {
          const full = await fetch(`${mailpitURL}/api/v1/message/${id}`).then((r) => r.json());
          return full.Text || full.HTML || "";
        },
        (body) => extractSetupLink(body, issuerOrigin),
      );
      if (link) return link;
    }
    await new Promise((r) => setTimeout(r, 2000));
  }
  throw new Error(
    `EXIT TEST FAILED: no setup-link mail was delivered to ${email} within ${timeoutMs / 1000}s. ` +
      "The Platform owner would never be able to sign in (ADR-0093 decision 8).",
  );
}

// ---------------------------------------------------------------------------
// --drill: setup link -> password -> TOTP -> console sign-in
// ---------------------------------------------------------------------------

async function drill() {
  const { chromium } = await import("playwright");
  const password = requireEnv("PLATFORM_OWNER_PASSWORD");
  const diagDir = process.env.DIAG_DIR || "";
  // LANDING_ORIGIN generalizes CONSOLE_ORIGIN (the Platform owner lands on
  // the Zitadel console; the first tenant's Owner lands on the dashboard) —
  // CONSOLE_ORIGIN keeps working unchanged for the Platform owner's own
  // exit test.
  const landingOrigin = process.env.LANDING_ORIGIN || requireEnv("CONSOLE_ORIGIN");

  let setupLink = process.env.SETUP_LINK || "";
  if (setupLink) {
    // Offline leg (ADR-0093 decision 8): the caller already read the link
    // out of a Secret (gibson-first-tenant-owner-setup or
    // gibson-platform-owner-setup) — nothing to poll Mailpit for.
    console.log("using the setup link supplied directly (offline mode, no mail transport)");
    // The same shape check the mail leg gets, so a link to a route Login v2
    // does not serve fails here by name instead of opening a 404 page.
    extractSetupLink(setupLink, new URL(setupLink).origin);
  } else {
    const mailpitURL = requireEnv("MAILPIT_URL");
    const email = requireEnv("PLATFORM_OWNER_EMAIL");
    const issuerOrigin = requireEnv("ISSUER_ORIGIN");
    console.log(`polling Mailpit for the setup link sent to ${email}`);
    ({ link: setupLink } = await pollMailpitForSetupLink(mailpitURL, email, issuerOrigin, 120_000));
  }
  if (process.env.SETUP_LINK_OUT) {
    writeFileSync(process.env.SETUP_LINK_OUT, setupLink);
  }

  const { browser, page } = await newPage(chromium, diagDir);
  try {
    console.log(`opening the setup link: ${safeURL(setupLink)}`);
    await page.goto(setupLink);

    // Zitadel's Login v2 invite flow: verify the code, then a method chooser
    // at /ui/v2/login/authenticator/set ("Password" / "Passkeys"). The login
    // policy allows password + authenticator app (ADR-0093 decision 9), so
    // the Password choice is always offered. Its link text is just
    // "Password" (runs 36335386753 and 36335289872 waited on it), so match
    // it by where it goes, which does not change with the copy.
    const setPasswordLink = page.locator('a[href*="/ui/v2/login/password/set"]')
      .or(page.getByRole("button", { name: /set.*password/i }))
      .or(page.getByRole("link", { name: /set.*password/i }));
    // Login v2's password page labels its fields "New Password *" and
    // "Confirm Password *", so a ^password$ label match finds nothing (run
    // 36337845936 waited on it). Its data-testids are the stable handles.
    const passwordField = page.locator('[data-testid="password-set-text-input"]')
      .or(page.getByLabel(/^password$/i));

    // Login v2 opens the /verify link on its "Verify user" page with the Code
    // field EMPTY and does not submit the code from the URL by itself
    // (demo-enrollment run 36333037725 waited 30s on that page). Type the
    // code the link carries and continue. The page's own data-testids are
    // the stable handles: its "Code" label is not tied to the input.
    const codeField = page.locator('[data-testid="code-text-input"]');
    // count() does not wait. Right after goto the page may not have rendered
    // any of these controls yet, so wait for one of them before choosing.
    await passwordField.or(setPasswordLink).or(codeField).first().waitFor({ timeout: 30_000 });
    if (await codeField.isVisible()) {
      const inviteCode = new URL(setupLink).searchParams.get("code");
      if (!inviteCode) {
        throw new Error(`the verify page asks for a code, but the setup link carries none: ${safeURL(setupLink)}`);
      }
      await fillUntilHeld(codeField, inviteCode, "invite code");
      await submitFilled(page, [[codeField, inviteCode]], "invite code");
      await passwordField.or(setPasswordLink).first().waitFor({ timeout: 30_000 });
    }
    if (await setPasswordLink.count()) {
      await setPasswordLink.first().click();
    }

    await fillUntilHeld(passwordField, password, "password");
    const setFields = [[passwordField, password]];
    const confirmField = page.locator('[data-testid="password-set-confirm-text-input"]')
      .or(page.getByLabel(/confirm password/i));
    if (await confirmField.count()) {
      await fillUntilHeld(confirmField, password, "confirm password");
      setFields.push([confirmField, password]);
    }
    await submitFilled(page, setFields, "set password");

    // Second-factor enrollment: authenticator app (TOTP). Zitadel's
    // enrollment screen shows a QR code and a manual-entry secret; the
    // manual secret is what this driver reads (no QR decode dependency).
    // The policy forces MFA, so Login v2 next offers a second-factor chooser.
    // Match the authenticator-app choice by its target, as with the password
    // link, and wait for either the chooser or the enrollment page rather
    // than swallowing a failed click.
    const totpChoice = page.locator('a[href*="/otp/time-based"]')
      .or(page.getByRole("button", { name: /authenticator app|totp/i }))
      .or(page.getByRole("link", { name: /authenticator app|totp/i }));
    // The enrollment page shows a QR code and the otpauth:// URI as a link.
    // It renders no bare secret, so read the secret from the link.
    const otpauthLink = page.locator('a[href^="otpauth://"]');
    await totpChoice.or(otpauthLink).first().waitFor({ timeout: 30_000 });
    if (!(await otpauthLink.count()) && (await totpChoice.count())) {
      await totpChoice.first().click();
    }
    await otpauthLink.first().waitFor({ timeout: 30_000 });
    const totpSecret = secretFromOtpauthURI(await otpauthLink.first().getAttribute("href"));
    writeFileSync(requireEnv("TOTP_SECRET_OUT"), totpSecret);
    console.log("enrolling TOTP with the secret of the otpauth link");

    const code = totpCodeFor(totpSecret);
    const enrollCode = page.locator('[data-testid="code-text-input"]');
    await fillUntilHeld(enrollCode, code, "TOTP code");
    await submitFilled(page, [[enrollCode, code]], "TOTP enrollment");

    // Setup done. Prove the person can use the app they land on (the Zitadel
    // console for the Platform owner, the dashboard for the first tenant's
    // Owner): sign in through it and reach a page that is not a login page.
    const url = await signInThroughLanding(page, landingOrigin, {
      password,
      totpSecret,
      lastCode: code,
    });
    console.log(`signed in: ${safeURL(url)}`);
  } catch (e) {
    await diagnose(page, diagDir, "drill-failure");
    throw e;
  } finally {
    await browser.close();
  }
}

// ---------------------------------------------------------------------------
// --resign-in: prove the account works on an ordinary second sign-in
// ---------------------------------------------------------------------------

async function resignIn() {
  const { chromium } = await import("playwright");
  const email = requireEnv("PLATFORM_OWNER_EMAIL");
  const password = requireEnv("PLATFORM_OWNER_PASSWORD");
  const totpSecret = requireEnv("PLATFORM_OWNER_TOTP_SECRET");
  const diagDir = process.env.DIAG_DIR || "";
  const loginOrigin = requireEnv("LOGIN_ORIGIN");
  const consoleOrigin = requireEnv("CONSOLE_ORIGIN");

  const { browser, page } = await newPage(chromium, diagDir);
  try {
    await page.goto(loginOrigin);
    // Login v2's data-testids, the same handles the setup drill uses.
    const userField = page.locator('[data-testid="username-text-input"]');
    await fillUntilHeld(userField, email, "username");
    await submitFilled(page, [[userField, email]], "username");
    const pwField = page.locator('[data-testid="password-text-input"]');
    await fillUntilHeld(pwField, password, "password");
    await submitFilled(page, [[pwField, password]], "password");
    const otpField = page.locator('[data-testid="code-text-input"]');
    const otp = totpCodeFor(totpSecret);
    await fillUntilHeld(otpField, otp, "TOTP code");
    await submitFilled(page, [[otpField, otp]], "TOTP code");

    await page.goto(consoleOrigin);
    await page.waitForLoadState("networkidle");
    const url = page.url();
    if (/\/login|\/ui\/v2\/login/.test(url)) {
      throw new Error(`re-sign-in did not land on the console, got ${safeURL(url)}`);
    }
    console.log(`re-sign-in landed on the console: ${safeURL(url)}`);
  } catch (e) {
    await diagnose(page, diagDir, "resignin-failure");
    throw e;
  } finally {
    await browser.close();
  }
}

// ---------------------------------------------------------------------------
// --first-sign-in: a signup owner's first sign-in lands in the workspace
// ---------------------------------------------------------------------------

/**
 * landingVerdict decides whether a first sign-in reached the workspace. It
 * is pure, so the selftest proves it can fail. Returns null on success, or
 * the reason the landing is not the workspace.
 */
export function landingVerdict({ path, body }, { expectPath, workspace, ownerEmail }) {
  // The sidebar always shows the signed-in email, and the test email holds
  // the workspace slug, so the email is removed before the workspace match.
  if (ownerEmail) body = body.split(ownerEmail).join("");
  if (/belong to any organization/i.test(body)) {
    return `the page at ${path} says the account belongs to no organization (gibson#1188)`;
  }
  if (!path.startsWith(expectPath)) {
    return `landed on ${path}, not under ${expectPath}: the owner cannot reach the workspace`;
  }
  if (!workspace || !body.includes(workspace)) {
    return `the page at ${path} does not show the workspace ${JSON.stringify(workspace)}`;
  }
  return null;
}

async function firstSignIn() {
  const { chromium } = await import("playwright");
  const email = requireEnv("OWNER_EMAIL");
  const password = requireEnv("OWNER_PASSWORD");
  const landingOrigin = requireEnv("LANDING_ORIGIN");
  const totpSecretOut = requireEnv("TOTP_SECRET_OUT");
  const workspace = requireEnv("EXPECT_WORKSPACE");
  const expectPath = process.env.EXPECT_PATH || "/dashboard";
  const diagDir = process.env.DIAG_DIR || "";
  const { browser, page } = await newPage(chromium, diagDir);
  try {
    const url = await signInThroughLanding(page, landingOrigin, { email, password, totpSecretOut });
    await page.waitForLoadState("networkidle").catch(() => {});
    const path = new URL(url).pathname;
    const body = await page.locator("body").innerText().catch(() => "");
    const reason = landingVerdict({ path, body }, { expectPath, workspace, ownerEmail: email });
    if (reason) throw new Error(`${email} signed in, but ${reason}`);
    console.log(`first sign-in landed in the workspace ${workspace}: ${path}`);
  } catch (e) {
    await diagnose(page, diagDir, "first-sign-in-failure");
    throw e;
  } finally {
    await browser.close();
  }
}

async function reset() {
  const mailpitURL = requireEnv("MAILPIT_URL");
  const email = requireEnv("PLATFORM_OWNER_EMAIL");
  const issuerOrigin = requireEnv("ISSUER_ORIGIN");
  const previousLinkFile = requireEnv("PREVIOUS_LINK_FILE");
  const previousLink = readFileSync(previousLinkFile, "utf8").trim();

  const deadline = Date.now() + 120_000;
  while (Date.now() < deadline) {
    const resp = await fetch(`${mailpitURL}/api/v1/messages?limit=200`).catch(() => null);
    if (resp && resp.ok) {
      const body = await resp.json();
      const messages = body.messages ?? [];
      const latest = latestMessageFor(messages, email);
      if (latest) {
        const full = await fetch(`${mailpitURL}/api/v1/message/${latest.ID}`).then((r) => r.json());
        const { link } = extractSetupLink(full.Text || full.HTML || "", issuerOrigin);
        if (link !== previousLink) {
          console.log(`new setup link received after the generation bump: ${safeURL(link)}`);
          return;
        }
      }
    }
    await new Promise((r) => setTimeout(r, 2000));
  }
  throw new Error(
    "EXIT TEST FAILED: raising platformOwner.setupGeneration sent no NEW setup link " +
      "(ADR-0093 decision 12).",
  );
}

const mode = process.argv.find((a) => a.startsWith("--"));
if (mode === "--drill") {
  drill().catch((e) => {
    console.error(e);
    process.exit(1);
  });
} else if (mode === "--resign-in") {
  resignIn().catch((e) => {
    console.error(e);
    process.exit(1);
  });
} else if (mode === "--reset") {
  reset().catch((e) => {
    console.error(e);
    process.exit(1);
  });
} else if (mode === "--first-sign-in") {
  firstSignIn().catch((e) => {
    console.error(e);
    process.exit(1);
  });
} else {
  console.error("usage: driver.mjs --drill | --resign-in | --reset | --first-sign-in | --selftest");
  process.exit(2);
}
