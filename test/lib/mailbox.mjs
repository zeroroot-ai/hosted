// ---------------------------------------------------------------------------
// mailbox.mjs — selecting one message out of a mailpit inbox.
//
// ONE SHARED COPY. test/platform-owner/driver.mjs and test/signup/driver.mjs
// each carried their own `findMessageFor` with the same body and a different
// error string, which is a duplicate that had already drifted (ADR-0027).
//
// THE INVARIANT THEY ASSERTED WAS IMPOSSIBLE. Both threw when an address held
// more than one message, calling it corruption. That holds for the Platform
// owner, who receives only a setup link. It cannot hold for the FIRST TENANT'S
// Owner, who receives a setup link AND a welcome email — so the identity drill
// failed three times on 2026-10-01 with
//
//     mailpit holds 3 messages for admin@localhost.zeroroot.ai;
//     the Platform owner's setup link must be sent exactly once per generation
//
// and the drill, not the product, was wrong. The welcome email had never
// arrived before charts#290 corrected the mailpit Service name, so an
// assertion that was always wrong had never been exercised.
//
// What a caller actually wants is "the one message carrying a setup link", not
// "the one message". messagesFor returns every candidate and lets the caller
// decide, which is what selecting on content requires: the list API returns
// summaries, so deciding needs a body fetch the caller is already doing.
// ---------------------------------------------------------------------------

/** Every message addressed to `email`, newest first. Never throws. */
export function messagesFor(messages, email) {
  const want = (email ?? "").toLowerCase();
  return (messages ?? [])
    .filter((m) =>
      (m.To ?? []).some((r) => (r.Address ?? "").toLowerCase() === want),
    )
    .sort((a, b) => String(b.Created ?? "").localeCompare(String(a.Created ?? "")));
}

/**
 * The one message addressed to `email`, or null. For an address that must
 * receive exactly one — a per-run unique signup address, say.
 *
 * THE ERROR NAMES THE SUBJECTS. It used to print only a count, so the one run
 * that needed diagnosing said "3 messages" while holding every subject it was
 * refusing. Two of the three were explicable; the third cost a cycle to
 * identify because the diagnostic artifact had not uploaded.
 */
export function findMessageFor(messages, email) {
  const hits = messagesFor(messages, email);
  if (hits.length > 1) {
    const subjects = hits
      .map((m) => `"${m.Subject ?? "(no subject)"}"`)
      .join(", ");
    throw new Error(
      `mailpit holds ${hits.length} messages for ${email}, and this address must receive exactly one. Subjects: ${subjects}. If one of these is a welcome email, the caller wants pickSetupLinkMessage, not findMessageFor.`,
    );
  }
  return hits[0] ?? null;
}

/** The most recent message addressed to `email`, or null. More than one is expected. */
export function latestMessageFor(messages, email) {
  return messagesFor(messages, email)[0] ?? null;
}

/**
 * The first message addressed to `email` whose body yields a setup link, newest
 * first. `fetchBody` takes a message id and returns its text; `extract` throws
 * when a body carries no link, which is how a welcome email is skipped rather
 * than mistaken for a setup mail.
 *
 * Returns the extractor's value, or null when no candidate carries a link.
 */
export async function pickSetupLinkMessage(messages, email, fetchBody, extract) {
  for (const m of messagesFor(messages, email)) {
    let body;
    try {
      body = await fetchBody(m.ID);
    } catch {
      continue;
    }
    try {
      return extract(body);
    } catch {
      // Not a setup mail. The welcome email lands in the same mailbox.
    }
  }
  return null;
}
