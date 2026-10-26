// driver.mjs — the browser half of the signup exit test (launch blocker 2,
// hosted#122).
//
// In plain words: a new customer types their address into the signup form,
// receives the verification mail, clicks the link, sets a password, and gets
// a workspace. This driver does exactly that, through the same dashboard
// pages a customer uses. Nothing here talks to the daemon's RPCs directly
// (they only accept the dashboard workload as caller), nothing seeds a
// verified flag, and nothing reads the token from the database. The token
// comes out of the delivered mail, the way a recipient's browser gets it.
//
// The form-driving selectors mirror the canonical helper the dashboard repo
// ships (e2e/auth/helpers/signup-via-form.ts). If the signup surface changes
// shape, this driver goes red and points at the drift. For an exit test on
// the customer surface, that is the correct failure, not a flake.
//
// THE EDGE BRIDGE. The cluster's customer hosts (app.<domain>, api.<domain>)
// have no DNS on the runner. EDGE_IP and EDGE_HOSTS map them to the Envoy
// LoadBalancer address with a Chromium resolver rule, so the mailed link
// (an https://app.<domain>/... URL) lands where the platform serves it, with
// no /etc/hosts edit and no sudo. The edge certificate is self-signed on the
// baseline profile, so the browser context ignores HTTPS errors.
//
// Modes:
//   --drill      the real drill: form -> delivered mail -> verify link ->
//                complete -> (SaaS: the card step) -> redirect to /login.
//                Requires APP_ORIGIN, SIGNUP_SLUG, SIGNUP_EMAIL,
//                SIGNUP_PASSWORD, SIGNUP_PROFILE and a mail source:
//                MAIL_SOURCE=mailpit with MAILPIT_URL (kind), or
//                MAIL_SOURCE=s3 with INBOX_BUCKET (an AWS env, hosted#647).
//                Writes the redeemed token to TOKEN_OUT (for the single-use
//                fixture).
//
// SIGNUP_PROFILE names the target, never a second driver:
//   baseline  card-free. A Stripe Payment Element is a failure.
//   saas      card-first. After the password the browser takes the signup
//             step to Stripe Checkout and pays with the Stripe TEST card.
//             The driver refuses a live Checkout session (cs_live_) before
//             it types a card, so it can never charge a real card. Prod
//             never runs this drill with a card.
//   --fixture    the failing fixture: proves the gate the drill rode through
//                can refuse. Completion without verification must bounce,
//                a forged token must bounce, and re-redeeming the drill's
//                consumed token (TOKEN_IN) must bounce. If any of those
//                reaches /signup/complete, this exits non-zero and the
//                workflow goes red. A drill whose gate cannot refuse proves
//                nothing.
//   --selftest   offline, zero-dependency: proves the mail-parsing and
//                refusal assertions can themselves fail. No network, no
//                playwright, no cluster.
//
// A skip is a failure: there is no code path in this file that exits 0
// without either the drill or the fixture having run.

import { readFileSync, writeFileSync } from "node:fs";
// findMessageFor lives in test/lib/mailbox.mjs since hosted#379: this file and
// test/platform-owner/driver.mjs each had their own copy with the same body and
// a different error string. The shared one lists the subjects it is refusing,
// which is what a run needs when an address holds more mail than expected.
import { findMessageFor } from "../lib/mailbox.mjs";
// The mail of the run lands in Mailpit (kind) or in the test inbox of an AWS
// environment (hosted#647). One reader, chosen by MAIL_SOURCE.
import { decodeBody, mailSourceFromEnv, summary, trustedPlatformMail } from "../lib/mailsource.mjs";
import { safeURL } from "../lib/redact.mjs";
import process from "node:process";

// ---------------------------------------------------------------------------
// Pure helpers (selftested, no I/O)
// ---------------------------------------------------------------------------


/**
 * extractVerifyLink pulls the signup verification URL out of a delivered
 * message body. The link must carry a ?token= and must point at the product
 * surface (appOrigin) — a link built from any other origin has no route to
 * land on, and accepting one would let the test pass on a mail no customer
 * could use.
 */
export function extractVerifyLink(body, appOrigin) {
  const urls = body.match(/https?:\/\/[^\s"'<>]+/g) ?? [];
  for (let raw of urls) {
    raw = raw.replace(/[.,)\]]+$/, "");
    let u;
    try {
      u = new URL(raw);
    } catch {
      continue;
    }
    if (!u.searchParams.get("token")) continue;
    // The ORIGIN, not a string prefix: https://app.<domain>.attacker.example
    // starts with the app origin and is another host (hosted#650 review).
    if (u.origin !== new URL(appOrigin).origin) {
      throw new Error(
        `the verification link points at ${u.origin}, not the product surface ${appOrigin} — a customer's browser has no route there`,
      );
    }
    return { link: raw, token: u.searchParams.get("token") };
  }
  throw new Error(
    `no verification link with a ?token= found in the delivered mail:\n${body.slice(0, 2000)}`,
  );
}

// ---------------------------------------------------------------------------
// fillUntilHeld — type into a field and prove the value stayed.
//
// The signup page is server-rendered. The input is visible, and Playwright can
// fill it, BEFORE React hydrates. Hydration then re-renders the controlled
// inputs from React state, which is still empty, and the typed text is gone.
// Run 36322836959 failed that way: the failure screenshot shows every text
// field empty with "First name is required", while both checkboxes, clicked a
// moment later, stayed checked. The same symptom appeared once on 2026-09-23.
//
// So read the value back, and fill again until it holds. A field that never
// holds the value is a real defect, and the error names it.
// ---------------------------------------------------------------------------

async function fillUntilHeld(locator, value, label, opts = {}) {
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
  // The message reads nothing of the typed value. The field can be a
  // password, so neither the text nor a property of it reaches a log.
  throw new Error(
    `the ${label} field never held its value: it holds ${last === "" ? "nothing" : "other text"}`,
  );
}

// ---------------------------------------------------------------------------
// Selftest — proves the assertions above can fail (guards lane, offline)
// ---------------------------------------------------------------------------

async function selftest() {
  const app = "https://app.localhost.zeroroot.ai";
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

  // Extraction succeeds on a real-shaped mail, and returns the token.
  const good = check(
    "extracts the token from a delivered mail",
    () =>
      extractVerifyLink(
        `Hi,\nconfirm your address:\n${app}/signup/verify?token=tok-123abc\nThanks`,
        app,
      ),
    false,
  );
  if (good && good.token !== "tok-123abc") {
    failures += 1;
    console.error(`SELFTEST FAIL: extracted wrong token: ${good?.token}`);
  }

  // A mail with no token link must FAIL, not pass vacuously.
  check(
    "a mail with no token link is refused",
    () => extractVerifyLink(`Welcome! Visit ${app}/docs for help.`, app),
    true,
  );

  // A look-alike host that starts with the app origin must FAIL.
  check(
    "a link on a host that only starts with the app origin is refused",
    () => extractVerifyLink(`${app}.attacker.example/signup/verify?token=t1`, app),
    true,
  );

  // A link on the wrong origin must FAIL: the customer cannot use it.
  check(
    "a link on a non-product origin is refused",
    () =>
      extractVerifyLink(
        "click https://api.localhost.zeroroot.ai/signup/verify?token=t1",
        app,
      ),
    true,
  );

  // Recipient matching is exact, and a duplicate is corruption.
  const msgs = [
    { ID: "1", To: [{ Address: "a@x.test" }] },
    { ID: "2", To: [{ Address: "b@x.test" }] },
  ];
  check("finds the message for the run's address", () => {
    const m = findMessageFor(msgs, "A@x.test");
    if (m?.ID !== "1") throw new Error(`matched ${m?.ID}, want 1`);
  }, false);
  check("an unknown address matches nothing", () => {
    if (findMessageFor(msgs, "c@x.test") !== null)
      throw new Error("matched a message that is not addressed to the run");
  }, false);
  check(
    "two mails to one address is an error, not a free pass",
    () =>
      findMessageFor(
        [...msgs, { ID: "3", To: [{ Address: "a@x.test" }] }],
        "a@x.test",
      ),
    true,
  );

  // The card step never pays on a live Stripe key (hosted#647).
  check(
    "a live Stripe Checkout session is refused before the card",
    () => refuseLiveCheckout("https://checkout.stripe.com/c/pay/cs_live_a1B2c3#fid"),
    true,
  );
  check(
    "a test Stripe Checkout session is allowed",
    () => refuseLiveCheckout("https://checkout.stripe.com/c/pay/cs_test_a1B2c3#fid"),
    false,
  );

  // The S3 mail source reads a raw SES message the way Mailpit reports it
  // (hosted#647): recipient, subject, and the decoded verification link.
  const raw =
    "To: Exit Test <sg-1@inbox.staging.example.test>\r\nSubject: =?UTF-8?Q?Verify_your_email?=\r\n" +
    'Content-Type: multipart/alternative; boundary="b1"\r\n\r\n--b1\r\n' +
    "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n" +
    `confirm: ${app}/signup/verify?token=3Dtok-=\r\n9z\r\n--b1--\r\n`;
  check("an S3 raw message yields its recipient and its link", () => {
    const m = findMessageFor([summary("mail/k1", raw, "2026")], "sg-1@inbox.staging.example.test");
    if (m?.ID !== "mail/k1") throw new Error(`matched ${m?.ID}`);
    const { token } = extractVerifyLink(decodeBody(raw), app);
    if (token !== "tok-9z") throw new Error(`token ${token}`);
  }, false);
  check("an S3 raw message with no link is refused", () => {
    extractVerifyLink(decodeBody("To: a@b.test\r\nContent-Type: text/plain\r\n\r\nWelcome."), app);
  }, true);
  // The inbox takes mail from anyone, so only SES-verified, aligned platform
  // mail counts (hosted#650, hosted#660).
  const mail = (ar, from) =>
    `From: ${from}\r\nAuthentication-Results: ${ar}\r\n\r\nbody`;
  const goodAR = "amazonses.com;\r\n spf=pass (spfCheck: ok) smtp.mailfrom=x@amazonses.com;\r\n dkim=pass header.i=@zeroroot.ai;\r\n dkim=pass header.i=@amazonses.com;\r\n dmarc=none header.from=staging.zeroroot.ai;";
  check("SES-verified mail signed by the platform domain is trusted", () => {
    if (!trustedPlatformMail(mail(goodAR, "Gibson <no-reply@staging.zeroroot.ai>"), "staging.zeroroot.ai"))
      throw new Error("refused");
  }, false);
  for (const [name, m] of [
    ["mail with spf=fail is ignored", mail(goodAR.replace("spf=pass", "spf=fail"), "no-reply@staging.zeroroot.ai")],
    ["mail whose only dkim=pass is the sender's own domain is ignored",
      mail("amazonses.com; spf=pass; dkim=pass header.i=@attacker.example;", "no-reply@staging.zeroroot.ai")],
    ["mail signed only by amazonses.com is ignored",
      mail("amazonses.com; spf=pass; dkim=pass header.i=@amazonses.com;", "no-reply@staging.zeroroot.ai")],
    ["mail with no SES Authentication-Results is ignored",
      "From: no-reply@staging.zeroroot.ai\r\nX-SES-SPF-VERDICT: PASS\r\nX-SES-DKIM-VERDICT: PASS\r\n\r\nbody"],
    ["aligned mail from another domain is ignored", mail(goodAR, "x@evil-staging.example.test")],
    ["a forged Authentication-Results below the SES one is not read",
      "From: no-reply@staging.zeroroot.ai\r\nAuthentication-Results: amazonses.com; spf=pass; dkim=pass header.i=@attacker.example;\r\n" +
      "Authentication-Results: amazonses.com; spf=pass; dkim=pass header.d=zeroroot.ai;\r\n\r\nbody"],
    ["an authserv-id that only starts with amazonses.com is ignored",
      mail("amazonses.com.attacker.example; spf=pass; dkim=pass header.d=zeroroot.ai;", "no-reply@staging.zeroroot.ai")],
    ["a message with two From headers is ignored",
      `From: x@attacker.example\r\n${"From: no-reply@staging.zeroroot.ai"}\r\nAuthentication-Results: ${goodAR}\r\n\r\nbody`],
  ]) {
    check(name, () => {
      if (trustedPlatformMail(m, "staging.zeroroot.ai")) throw new Error("trusted");
    }, false);
  }
  check("MAIL_SOURCE=s3 with no sender domain is refused",
    () => mailSourceFromEnv({ MAIL_SOURCE: "s3", INBOX_BUCKET: "b" }), true);
  check("an unknown MAIL_SOURCE is refused", () => mailSourceFromEnv({ MAIL_SOURCE: "imap" }), true);
  check("MAIL_SOURCE=s3 with no bucket is refused", () => mailSourceFromEnv({ MAIL_SOURCE: "s3" }), true);

  // fillUntilHeld: a field that hydration resets once must end up filled,
  // and a field that never keeps its value must FAIL, not pass.
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
    const ok = wantThrow ? threw !== null : threw === null;
    if (!ok) {
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
    () => fillUntilHeld(fakeField(1), "Exit", "first name", { sleep: noSleep }),
    false,
  );
  await asyncCheck(
    "a field that never keeps its value fails",
    () =>
      fillUntilHeld(fakeField(Infinity), "Exit", "first name", {
        sleep: noSleep,
        timeoutMs: 0,
      }),
    true,
  );
  {
    let msg = "";
    try {
      await fillUntilHeld(fakeField(Infinity), "s3cr3t-pass", "password", { sleep: noSleep, timeoutMs: 0 });
    } catch (e) {
      msg = String(e?.message ?? e);
    }
    if (!msg || msg.includes("s3cr3t-pass")) {
      failures += 1;
      console.error(`SELFTEST FAIL: the error of a field that never holds its value shows the typed text: ${msg ? "it does" : "no error"}`);
    } else {
      console.log("selftest ok: the error of a field that never holds its value shows no typed text");
    }
  }

  if (failures > 0) {
    console.error(`selftest: ${failures} assertion(s) cannot fail correctly`);
    process.exit(1);
  }
  console.log("selftest: all assertions can fail — guard is honest");
}

// ---------------------------------------------------------------------------
// Shared browser plumbing
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
  // What the page showed goes to the log too, so a run with no artifact
  // still names the state it stopped in.
  await describePage(page, label);
  if (!diagDir) return;
  try {
    await page.screenshot({ path: `${diagDir}/${label}.png`, fullPage: true });
    writeFileSync(`${diagDir}/${label}.html`, await page.content());
    console.error(`diagnostics written: ${diagDir}/${label}.{png,html} (url=${safeURL(page.url())})`);
  } catch (e) {
    console.error(`diagnostics failed for ${label}: ${e}`);
  }
}

/**
 * describePage prints the URL, the headings, the toasts and the start of the
 * visible text of the page to stderr. The pages of the signup flow hold no
 * credential in their text: the session and step tokens live in httpOnly
 * cookies.
 */

async function describePage(page, label) {
  try {
    const headings = await page.locator("h1, h2, [data-slot=card-title]").allInnerTexts().catch(() => []);
    const toasts = await page.locator("[data-sonner-toast]").allTextContents().catch(() => []);
    const text = ((await page.locator("body").innerText().catch(() => "")) || "").replace(/\s+/g, " ").slice(0, 600);
    console.error(`page at ${label}: url=${safeURL(page.url())}`);
    console.error(`  headings: ${JSON.stringify(headings.slice(0, 6))}`);
    console.error(`  toasts: ${JSON.stringify(toasts.slice(0, 4))}`);
    console.error(`  text: ${text}`);
  } catch (e) {
    console.error(`could not describe the page at ${label}: ${e}`);
  }
}

// ---------------------------------------------------------------------------
// The drill
// ---------------------------------------------------------------------------

async function pollMail(source, email, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let lastCount = -1;
  while (Date.now() < deadline) {
    const messages = await source.list();
    if (messages.length !== lastCount) {
      lastCount = messages.length;
      console.log(`${source.kind} holds ${messages.length} message(s)`);
    }
    const msg = findMessageFor(messages, email);
    if (msg) return msg;
    await new Promise((r) => setTimeout(r, 2000));
  }
  throw new Error(
    `EXIT TEST FAILED: no verification mail was delivered to ${email} within ${timeoutMs / 1000}s. ` +
      `This is launch blocker 2 in one line: the platform accepted the signup and the customer received nothing.`,
  );
}

/**
 * refuseLiveCheckout throws on a Stripe Checkout URL of a LIVE session. The
 * smoke pays with the Stripe test card, and a live session would charge it
 * for real (hosted#647). A URL that is not a Checkout session passes.
 */
function refuseLiveCheckout(url) {
  if (/\bcs_live_/.test(url)) {
    throw new Error(
      `the signup step opened a LIVE Stripe Checkout session (${url.split("#")[0].slice(0, 80)}…). ` +
        `This smoke never pays on a live key. Run it only on an environment with a test-mode Stripe account`,
    );
  }
}

/** The SaaS card step: from /signup/complete through Stripe Checkout and back. */
async function cardStep(page, email) {
  // The step card renders after the password; its button is the one link
  // to /signup/step/start, whatever text the profile gives it.
  //
  // Three other outcomes end the wait at once, each with its own message: an
  // error toast (the completion was refused), a move to /login or /dashboard
  // (the daemon held no step, so the card step never came), and a 60 s
  // timeout on the same page.
  const start = page.locator('a[href="/signup/step/start"]').first();
  const deadline = Date.now() + 60_000;
  for (;;) {
    if (await start.isVisible().catch(() => false)) break;
    // Any error toast (sonner marks it data-type="error"), whatever its text:
    // the completion action shows the server's own message there.
    const errs = await page.locator('[data-sonner-toast][data-type="error"]').allTextContents().catch(() => []);
    const fieldErr = await page.locator('[data-slot="form-message"], [id$="-form-item-message"]').allInnerTexts().catch(() => []);
    if (errs.length > 0 || fieldErr.some((s) => s.trim())) {
      throw new Error(
        `the account creation was refused before the card step: toast=${JSON.stringify(errs.map((s) => s.slice(0, 200)))} ` +
          `field=${JSON.stringify(fieldErr.filter((s) => s.trim()).map((s) => s.slice(0, 200)))}`,
      );
    }
    const path = new URL(page.url()).pathname;
    if (path.startsWith("/login") || path.startsWith("/dashboard")) {
      throw new Error(
        `the SaaS signup reached ${path} with no card step: the daemon held no external signup step for this tenant ` +
          `(GIBSON_SIGNUP_STEP_URL, the billing component), or the dashboard has no step texts`,
      );
    }
    if (Date.now() > deadline) {
      throw new Error(`the card step link to /signup/step/start did not show within 60s (url=${safeURL(page.url())})`);
    }
    await page.waitForTimeout(1000);
  }
  await start.click();
  // The host, compared whole. A pattern match would also accept a URL that
  // only names checkout.stripe.com in its path or in another host.
  await page.waitForURL((u) => u.protocol === "https:" && u.hostname === "checkout.stripe.com", { timeout: 60_000 });
  refuseLiveCheckout(page.url());
  if (!/\bcs_test_/.test(page.url())) {
    throw new Error(`the signup step did not open a Stripe test Checkout session (url=${page.url().slice(0, 120)})`);
  }
  console.log("step 4b: on Stripe Checkout (test mode), paying with the Stripe test card");
  const email_ = page.locator("#email");
  if (await email_.isVisible().catch(() => false) && !(await email_.inputValue().catch(() => ""))) {
    await email_.fill(email);
  }
  // The Checkout page of the sandbox account, as a headless probe of a real
  // test session read it on 2026-10-13 (the same parameters as the billing
  // component: subscription, a customer, a 14 day trial):
  //   - the payment methods are an accordion (Card, Cash App Pay, Klarna,
  //     Bank), and the card fields exist only after Card is chosen. A cover
  //     element over the item takes the pointer events, so the click on the
  //     label is forced (drill run 38452048127 waited for #cardNumber);
  //   - the card fields are #cardNumber, #cardExpiry, #cardCvc, #billingName,
  //     #billingCountry (a select) and #billingPostalCode;
  //   - "Save my information with Link" (#enableStripePass) is checked by
  //     default and then requires a phone number, so the payment never
  //     submits. The driver unchecks it;
  //   - the pay button is [data-testid="hosted-payment-submit-button"]
  //     ("Start trial"), and Checkout then redirects to the success URL.
  // A Checkout with the card method alone shows the fields at once, and the
  // accordion item is then absent.
  //
  // The Checkout page draws its form after the URL loads. The pay button is
  // the sign that the form is drawn (staging run 38459072925 looked for the
  // card label too early, found none, and never chose Card). A click before
  // the page attaches its handlers does nothing, so the driver clicks again
  // until the card fields show.
  const payButton = page.locator('[data-testid="hosted-payment-submit-button"]');
  await payButton.waitFor({ state: "visible", timeout: 60_000 });
  const cardNumber = page.locator("#cardNumber");
  const cardLabel = page.locator("#payment-method-label-card");
  const cardDeadline = Date.now() + 60_000;
  while (!(await cardNumber.isVisible().catch(() => false))) {
    if (Date.now() > cardDeadline) {
      throw new Error("the Checkout card fields did not show within 60s of the pay button");
    }
    if (await cardLabel.isVisible().catch(() => false)) {
      await cardLabel.click({ force: true });
    }
    await cardNumber.waitFor({ state: "visible", timeout: 5_000 }).catch(() => {});
  }
  await cardNumber.fill("4242 4242 4242 4242");
  await page.locator("#cardExpiry").fill("12 / 34");
  await page.locator("#cardCvc").fill("123");
  const name = page.locator("#billingName");
  if (await name.isVisible().catch(() => false)) await name.fill("Exit Test");
  const country = page.locator("#billingCountry");
  if (await country.isVisible().catch(() => false)) await country.selectOption("US");
  const zip = page.locator("#billingPostalCode");
  if (await zip.isVisible().catch(() => false)) await zip.fill("10001");
  const saveWithLink = page.locator("#enableStripePass");
  if (await saveWithLink.isChecked().catch(() => false)) await saveWithLink.uncheck({ force: true });
  await payButton.click();
  console.log("step 4b: payment submitted, waiting for the return to the signup step");
}

async function drill() {
  const appOrigin = requireEnv("APP_ORIGIN").replace(/\/+$/, "");
  const source = mailSourceFromEnv();
  const profile = requireEnv("SIGNUP_PROFILE");
  if (profile !== "baseline" && profile !== "saas") {
    throw new Error(`SIGNUP_PROFILE must be baseline or saas, got ${JSON.stringify(profile)}`);
  }
  const slug = requireEnv("SIGNUP_SLUG");
  const email = requireEnv("SIGNUP_EMAIL");
  const password = requireEnv("SIGNUP_PASSWORD");
  const tokenOut = process.env.TOKEN_OUT ?? "";
  const diagDir = process.env.DIAG_DIR ?? "";
  // The baseline profile is card-free and has no plans: /signup takes no
  // ?plan=. SIGNUP_PLAN stays as an override for a profile that has them.
  const plan = process.env.SIGNUP_PLAN ?? "";
  if (profile === "saas" && !plan) {
    throw new Error("SIGNUP_PROFILE=saas needs SIGNUP_PLAN: the SaaS signup page sends a request with no ?plan= to the pricing page");
  }
  const signupURL = plan ? `${appOrigin}/signup?plan=${plan}` : `${appOrigin}/signup`;

  const { chromium } = await import("playwright");
  const { browser, page } = await newPage(chromium, diagDir);

  try {
    // ---------------------------------------------------------------------
    // Step 1 — /signup: request the verification mail. Creates nothing.
    // ---------------------------------------------------------------------
    console.log(`step 1: ${signupURL} as ${email}`);
    await page.goto(signupURL, {
      waitUntil: "domcontentloaded",
      timeout: 30_000,
    });

    const firstName = page.getByLabel(/first name/i).first();
    const deadline = Date.now() + 20_000;
    let formReady = false;
    while (Date.now() < deadline) {
      const here = new URL(page.url());
      if (here.pathname.startsWith("/login")) {
        throw new Error(
          "/signup redirected to /login — this profile has self-serve signup disabled; there is no signup path to test",
        );
      }
      if (here.origin !== appOrigin) {
        throw new Error(
          `/signup bounced off-host to ${safeURL(page.url())}. The profile rejected the request${plan ? ` for plan "${plan}"` : ""}`,
        );
      }
      if (await firstName.isVisible().catch(() => false)) {
        formReady = true;
        break;
      }
      await page.waitForTimeout(250);
    }
    if (!formReady) {
      throw new Error(`the signup form never rendered (url=${safeURL(page.url())})`);
    }

    await fillUntilHeld(firstName, "Exit", "first name");
    await fillUntilHeld(page.getByLabel(/last name/i), "Test", "last name");
    await fillUntilHeld(page.getByLabel(/work email/i), email, "work email");
    await fillUntilHeld(
      page.getByLabel(/workspace name|company name/i),
      slug,
      "company name",
    );
    await page.locator("#acceptToS").check();
    await page.locator("#acceptPrivacy").check();
    await page.getByRole("button", { name: /continue/i }).first().click();

    // The terminal state of step 1 is the "Check your email" card. On a
    // platform whose mailer cannot deliver, the daemon refuses the request
    // instead (FailedPrecondition surfaces as an error toast) and this wait
    // times out — which is the red this exit test exists to show.
    // The card title is a <div data-slot="card-title">, not a heading
    // element, so a role selector never matches it (run 35369010283 timed
    // out on the card it had already rendered). Match the text.
    await page
      .getByText(/check your email/i)
      .first()
      .waitFor({ state: "visible", timeout: 30_000 });
    console.log("step 1 done: the platform accepted the request");

    // ---------------------------------------------------------------------
    // Step 2 — the mail. Polled from the mail source; the token is taken
    // from the delivered body, never from the database.
    // ---------------------------------------------------------------------
    const msg = await pollMail(source, email, 180_000);
    console.log(`step 2: mail delivered (id=${msg.ID}, subject=${JSON.stringify(msg.Subject ?? "")})`);
    const body = await source.body(msg.ID);
    const { link, token } = extractVerifyLink(body, appOrigin);
    console.log(`step 2 done: verification link extracted (token=${token.slice(0, 4)}…)`);

    // ---------------------------------------------------------------------
    // Step 3 — follow the link. Success is a redirect to /signup/complete
    // with the verified-session cookie set; anything else is a refusal.
    // ---------------------------------------------------------------------
    await page.goto(link, { waitUntil: "domcontentloaded", timeout: 30_000 });
    if (new URL(page.url()).pathname !== "/signup/complete") {
      throw new Error(
        `redeeming the mailed token did not reach /signup/complete (landed on ${safeURL(page.url())})`,
      );
    }
    console.log("step 3 done: token redeemed, on /signup/complete");

    // ---------------------------------------------------------------------
    // Step 4 — complete: password only. The baseline profile is card-free;
    // a Payment Element here would mean the install grew a billing surface
    // this profile must not have.
    // ---------------------------------------------------------------------
    // By field name, not by label. Until dashboard#95 the "Password" label's
    // `for` pointed at an id the input did not carry, so getByLabel found
    // nothing: run 35371763439 timed out on a form it had already rendered.
    // The name is the stable handle whichever dashboard version is pinned.
    const pw = page.locator('input[name="password"]').first();
    await pw.waitFor({ state: "visible", timeout: 15_000 });
    await fillUntilHeld(pw, password, "password");
    await fillUntilHeld(
      page.locator('input[name="passwordConfirm"]').first(),
      password,
      "confirm password",
    );

    if (profile === "baseline") {
      const stripeFrames = await page
        .locator('iframe[title="Secure payment input frame"]')
        .count();
      if (stripeFrames > 0) {
        throw new Error(
          "a Stripe Payment Element rendered on the card-free baseline profile. The profile grew a billing surface it must not have",
        );
      }
    }

    await page.getByRole("button", { name: /create account/i }).first().click();
    if (profile === "saas") {
      await cardStep(page, email);
    }
    console.log("step 4: account creation submitted, waiting for provisioning");

    const provisioningDeadline = Date.now() + (profile === "saas" ? 420_000 : 240_000);
    let redirected = false;
    while (Date.now() < provisioningDeadline) {
      const p = new URL(page.url()).pathname;
      if (p.startsWith("/login") || p.startsWith("/dashboard")) {
        redirected = true;
        break;
      }
      const toasts = await page
        .locator("[data-sonner-toast]")
        .allTextContents()
        .catch(() => []);
      const bad = toasts.find((t) =>
        /too many signup attempts|went wrong|denied|failed/i.test(t),
      );
      if (bad) throw new Error(`completion refused by the server: ${bad.slice(0, 300)}`);
      await page.waitForTimeout(1000);
    }
    if (!redirected) {
      throw new Error(
        `provisioning did not redirect to /login within 240s (url=${safeURL(page.url())})`,
      );
    }
    console.log(`step 4 done: provisioning redirected to ${safeURL(page.url())}`);

    if (tokenOut) {
      writeFileSync(tokenOut, token, { mode: 0o600 });
      console.log(`consumed token written to ${tokenOut} for the single-use fixture`);
    }
    console.log(`DRILL PASSED: ${email} received the mail and completed signup for workspace ${slug}`);
  } catch (e) {
    await diagnose(page, diagDir, "drill-failure");
    throw e;
  } finally {
    await browser.close();
  }
}

// ---------------------------------------------------------------------------
// The failing fixture
// ---------------------------------------------------------------------------

async function fixture() {
  const appOrigin = requireEnv("APP_ORIGIN").replace(/\/+$/, "");
  const diagDir = process.env.DIAG_DIR ?? "";
  const tokenIn = process.env.TOKEN_IN ?? "";

  const { chromium } = await import("playwright");
  const { browser, page } = await newPage(chromium, diagDir);

  // Each probe attempts to reach /signup/complete without holding a live
  // verified session, and each MUST bounce. Reaching /signup/complete is the
  // fixture "passing", and the exit test goes red on it.
  const mustBounce = async (label, url) => {
    await page.goto(url, { waitUntil: "domcontentloaded", timeout: 30_000 });
    const path = new URL(page.url()).pathname;
    if (path === "/signup/complete") {
      throw new Error(
        `FIXTURE PASSED, WHICH IS THE FAILURE: ${label} reached /signup/complete. ` +
          `The verification gate the drill's green depends on does not hold.`,
      );
    }
    console.log(`fixture ok: ${label} bounced to ${path}`);
  };

  try {
    await mustBounce(
      "completion with the verification step skipped",
      `${appOrigin}/signup/complete`,
    );
    await mustBounce(
      "a forged token",
      `${appOrigin}/signup/verify?token=forged-${Date.now()}-not-a-real-token`,
    );
    if (tokenIn) {
      const consumed = readFileSync(tokenIn, "utf8").trim();
      await mustBounce(
        "re-redeeming the drill's consumed token",
        `${appOrigin}/signup/verify?token=${encodeURIComponent(consumed)}`,
      );
    } else {
      console.log("fixture note: TOKEN_IN not set — single-use re-redemption probe skipped is NOT allowed");
      throw new Error("TOKEN_IN is required: the single-use probe must run against the drill's consumed token");
    }
    console.log("FIXTURE FAILED AS REQUIRED: every unverified path was refused");
  } catch (e) {
    await diagnose(page, diagDir, "fixture-failure");
    throw e;
  } finally {
    await browser.close();
  }
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------

const mode = process.argv[2] ?? "";
if (mode === "--selftest") {
  selftest().catch((e) => {
    console.error(String(e?.stack ?? e));
    process.exit(1);
  });
} else if (mode === "--fixture") {
  fixture().catch((e) => {
    console.error(String(e?.stack ?? e));
    process.exit(1);
  });
} else if (mode === "" || mode === "--drill") {
  drill().catch((e) => {
    console.error(String(e?.stack ?? e));
    process.exit(1);
  });
} else {
  console.error(`unknown mode: ${mode} (use --drill, --fixture or --selftest)`);
  process.exit(2);
}
